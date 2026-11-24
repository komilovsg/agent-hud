import AgentHudCore
import AppKit
import ApplicationServices
import ScreenCaptureKit

/// An encoded screenshot.
struct LookPicture {
    let data: Data
    let mimeType: String
    let width: Int
    let height: Int
}

enum LookFailure: Error {
    case windowGone, excludedApp, noDisplay, cannotMatchWindow, encoding
    case system(String)

    /// The sentence the agent receives.
    var message: String {
        switch self {
        case .windowGone: return "That window is no longer on screen. Call list_windows for the current window ids."
        case .excludedApp: return LookGate.Refusal.excludedApp.message
        case .noDisplay: return "Agent HUD found no display to capture"
        case .cannotMatchWindow: return "Agent HUD could not find that window in the app's accessibility tree"
        case .encoding: return "Agent HUD could not encode the picture"
        case .system(let s): return "Agent HUD could not do this: \(s)"
        }
    }
}

/// The elements behind the handles of one read of a window (`LookNode.handle` is an index into the list).
/// Opaque outside the files that talk to the Accessibility API.
final class AXHandles: @unchecked Sendable {
    let elements: [AXUIElement]
    init(_ elements: [AXUIElement] = []) { self.elements = elements }
}

/// A window's text as a tree, with the pressable elements it found.
struct LookTree: Sendable {
    let root: LookNode
    let handles: AXHandles
}

/// Everything that looks at the screen goes through this protocol. `windows` returns names and sizes only;
/// the other two return pixels or text and are called by `AppModel.perform` alone, after the consent gate allowed the look.
protocol ScreenLooking: Sendable {
    /// On-screen windows front to back: owner, title, size. No pixels, no content. Never shows a system prompt.
    func windows() -> [WindowInfo]
    func screenshot(of target: LookTarget, maxSide: Int, excluded: [String]) async throws -> LookPicture
    func windowText(number: UInt32, excluded: [String]) async throws -> LookTree
}

/// The real thing: the window list from the window server, pictures from ScreenCaptureKit, text from the
/// Accessibility tree. Read-only throughout: nothing here clicks, types, moves or sets anything.
struct SystemScreenLook: ScreenLooking {
    private struct Listed {
        var info: WindowInfo
        var bounds: CGRect
    }

    func windows() -> [WindowInfo] { listed().map(\.info) }

    /// An on-screen window with its current frame (top-left based screen points); nil when it is gone.
    func placed(number: UInt32) -> (info: WindowInfo, bounds: CGRect)? {
        listed().first { $0.info.number == number }.map { ($0.info, $0.bounds) }
    }

    private func listed() -> [Listed] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var bundleIds: [pid_t: String?] = [:]
        var frontMarked = false
        var out: [Listed] = []
        for w in raw {
            // Layer 0 holds ordinary app windows; the menu bar, the Dock and overlays live on other layers.
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? UInt32,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if bundleIds[pid] == nil { bundleIds[pid] = .some(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier) }
            let front = !frontMarked && pid == frontPid
            if front { frontMarked = true }
            let info = WindowInfo(number: number, app: w[kCGWindowOwnerName as String] as? String ?? "Unknown app",
                                  bundleId: bundleIds[pid] ?? nil, pid: pid,
                                  title: w[kCGWindowName as String] as? String ?? "",
                                  width: Int(bounds.width), height: Int(bounds.height), frontmost: front)
            out.append(Listed(info: info, bounds: bounds))
        }
        return out
    }

    // MARK: - Pictures

    func screenshot(of target: LookTarget, maxSide: Int, excluded: [String]) async throws -> LookPicture {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw LookFailure.system(error.localizedDescription)
        }
        let filter: SCContentFilter
        if case .window(let number) = target {
            guard let window = content.windows.first(where: { $0.windowID == number }) else { throw LookFailure.windowGone }
            // Checked again here: the list the gate saw is a moment old.
            if LookExclusions.isExcluded(window.owningApplication?.bundleIdentifier, excluded: excluded) { throw LookFailure.excludedApp }
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard let display = frontDisplay(in: content) else { throw LookFailure.noDisplay }
            // Excluded apps are taken out of the composition itself, so their windows are not in the picture at all
            // (what is behind them shows instead). Agent HUD's own icons and cards are left out as well.
            let me = getpid()
            let hidden = content.applications.filter {
                $0.processID == me || LookExclusions.isExcluded($0.bundleIdentifier, excluded: excluded)
            }
            filter = SCContentFilter(display: display, excludingApplications: hidden, exceptingWindows: [])
        }
        let scale = CGFloat(filter.pointPixelScale)
        let size = LookImage.scaledSize(width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale),
                                        maxSide: maxSide)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.showsCursor = false
        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw LookFailure.system(error.localizedDescription)
        }
        return try Self.encode(image)
    }

    /// The display under the frontmost app's first window; the main display when that cannot be told.
    private func frontDisplay(in content: SCShareableContent) -> SCDisplay? {
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           let frame = listed().first(where: { $0.info.pid == pid })?.bounds {
            let center = CGPoint(x: frame.midX, y: frame.midY)
            if let d = content.displays.first(where: { $0.frame.contains(center) }) { return d }
        }
        return content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
    }

    /// PNG for a small picture that also makes a small file, JPEG otherwise.
    static func encode(_ image: CGImage) throws -> LookPicture {
        let rep = NSBitmapImageRep(cgImage: image)
        if LookImage.triesPNG(width: image.width, height: image.height),
           let png = rep.representation(using: .png, properties: [:]), LookImage.keepsPNG(bytes: png.count) {
            return LookPicture(data: png, mimeType: "image/png", width: image.width, height: image.height)
        }
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: LookImage.jpegQuality]) else {
            throw LookFailure.encoding
        }
        return LookPicture(data: jpeg, mimeType: "image/jpeg", width: image.width, height: image.height)
    }

    // MARK: - Text

    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
                                     kAXDescriptionAttribute, kAXVisibleChildrenAttribute, kAXChildrenAttribute,
                                     kAXEnabledAttribute]

    /// Limits of one walk: a window can hold a table with a hundred thousand cells or an app that answers slowly.
    private struct Budget {
        var nodes = 4000
        let deadline = Date().addingTimeInterval(5)
        static let maxDepth = 60
        static let maxChildren = 400
    }

    func windowText(number: UInt32, excluded: [String]) async throws -> LookTree {
        guard let target = listed().first(where: { $0.info.number == number }) else { throw LookFailure.windowGone }
        if LookExclusions.isExcluded(target.info.bundleId, excluded: excluded) { throw LookFailure.excludedApp }
        // Off the main thread: every attribute read is a round trip to the other app.
        return try await Task.detached(priority: .userInitiated) {
            let app = AXUIElementCreateApplication(target.info.pid)
            AXUIElementSetMessagingTimeout(app, 1.5)
            guard let window = Self.axWindow(of: app, bounds: target.bounds, title: target.info.title) else {
                throw LookFailure.cannotMatchWindow
            }
            var budget = Budget()
            var pressable: [AXUIElement] = []
            let root = Self.node(window, depth: 0, budget: &budget, pressable: &pressable)
            return LookTree(root: root ?? LookNode(role: "AXWindow", title: target.info.title), handles: AXHandles(pressable))
        }.value
    }

    /// The Accessibility tree has no window numbers: the window is matched by its frame, then by its title.
    static func axWindow(of app: AXUIElement, bounds: CGRect, title: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement], !windows.isEmpty else { return nil }
        func frame(_ w: AXUIElement) -> CGRect? {
            var p: CFTypeRef?, s: CFTypeRef?
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &p) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &s) == .success,
                  let p, let s, CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            var origin = CGPoint.zero, size = CGSize.zero
            guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGRect(origin: origin, size: size)
        }
        func close(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 3 && abs(a.minY - b.minY) <= 3 && abs(a.width - b.width) <= 3 && abs(a.height - b.height) <= 3
        }
        if let byFrame = windows.first(where: { frame($0).map { close($0, bounds) } ?? false }) { return byFrame }
        guard !title.isEmpty else { return nil }
        let byTitle = windows.filter { w in
            var t: CFTypeRef?
            return AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t) == .success && (t as? String) == title
        }
        return byTitle.count == 1 ? byTitle[0] : nil
    }

    private static func node(_ element: AXUIElement, depth: Int, budget: inout Budget, pressable: inout [AXUIElement]) -> LookNode? {
        guard budget.nodes > 0, depth <= Budget.maxDepth, Date() < budget.deadline else { return nil }
        budget.nodes -= 1
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &raw) == .success,
              let values = raw as? [Any], values.count == attributes.count else { return nil }
        func text(_ v: Any) -> String {
            if let s = v as? String { return s }
            if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
            return ""
        }
        let role = text(values[0]), subrole = text(values[1])
        var title = text(values[2])
        if title.isEmpty { title = text(values[4]) }
        // What is typed into a password field is never read.
        let value = subrole == (kAXSecureTextFieldSubrole as String) ? "(hidden)" : text(values[3])
        // Lists and tables report the rows that are on screen separately; the rest of the rows are not visible text.
        let kids = (values[5] as? [AXUIElement]) ?? (values[6] as? [AXUIElement]) ?? []
        // A control that can be pressed is remembered, so that a later press finds the very same element.
        var handle: Int?
        if ActElements.isPressable(role: role, enabled: (values[7] as? Bool) ?? true) {
            handle = pressable.count
            pressable.append(element)
        }
        var children: [LookNode] = []
        for kid in kids.prefix(Budget.maxChildren) {
            guard let child = node(kid, depth: depth + 1, budget: &budget, pressable: &pressable) else { continue }
            children.append(child)
        }
        return LookNode(role: role, title: title, value: value, children: children, handle: handle)
    }
}
