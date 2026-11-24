import AgentHudCore
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// An installed app that `open_app` may open.
struct ActApp: Equatable, Sendable {
    let name: String
    let bundleId: String
    let url: URL
}

/// One action with everything needed to carry it out. Built by `AppModel` after the consent gate allowed it.
enum ActOrder: Sendable {
    /// `index` points into the elements of the latest read of the window.
    case press(handles: AXHandles, index: Int)
    case click(window: UInt32, pid: Int32, x: Double, y: Double, button: ActButton, count: Int)
    case type(window: UInt32, pid: Int32, text: String)
    case keys(window: UInt32, pid: Int32, combo: KeyCombo)
    case scroll(window: UInt32, pid: Int32, dx: Int, dy: Int)
    case focus(window: UInt32, pid: Int32)
    case open(ActApp)
}

/// Why an action was not (or not fully) carried out, as the sentence the agent receives.
struct ActFailure: Error, Equatable {
    let message: String

    static let windowGone = ActFailure(message: "That window is no longer on screen. Call list_windows for the current window ids.")
    static let notFrontmost = ActFailure(message: "The app did not come to the front, so nothing was done")
    static let lostFront = ActFailure(message: "Another app came to the front, so Agent HUD stopped")
    static let focusElsewhere = ActFailure(message: "The keyboard focus is not in that window, so nothing was typed")
    static let pointOutside = ActFailure(message: "That point is outside the window. Use points from the window's top-left corner, within its size from list_windows.")
    static let ownWindow = ActFailure(message: "Agent HUD's own window covers that point")
    static let nothingThere = ActFailure(message: "The window is not visible at that point")
    static let elementGone = ActFailure(message: ActGate.Refusal.staleElement.message)
    static let pressFailed = ActFailure(message: "The app refused the press. The element may be disabled or have no press action.")
    static let pressUnconfirmed = ActFailure(message: "The app did not confirm the press in time. It may still have happened: read the window again before retrying.")
    static let secureField = ActFailure(message: ActGate.Refusal.secureField.message)
    static let screenLocked = ActFailure(message: ActGate.Refusal.screenLocked.message)
    static let events = ActFailure(message: "Agent HUD could not create the input event")

    static func covered(by app: String) -> ActFailure { ActFailure(message: "A window of \(app) covers that point") }
    static func launch(_ why: String) -> ActFailure { ActFailure(message: "The app could not be opened: \(why)") }
    /// Stopped part of the way through typing.
    func afterTyping(_ characters: Int) -> ActFailure {
        characters > 0 ? ActFailure(message: "\(message) (after \(characters) characters had been typed)") : self
    }
}

/// Everything that acts in other apps goes through this protocol. The first three functions only read;
/// `perform` is called by `AppModel.runNextAct` alone, after the consent gate allowed the action.
@MainActor
protocol ScreenActing {
    func isScreenLocked() -> Bool
    /// Whether the element with the keyboard focus in that app is a password field.
    func focusedElementIsSecure(pid: Int32) -> Bool
    func installedApp(_ ref: ActAppRef) -> ActApp?
    /// `stillAllowed` is asked before every event and returns the reason to stop (hands switched off, the
    /// session held), or nil. Returns nil when the action was carried out.
    func perform(_ order: ActOrder, stillAllowed: @MainActor () -> String?) async -> ActFailure?
}

/// The real thing. This file is the only place that posts keyboard, mouse or scroll events or performs
/// Accessibility actions on behalf of an agent.
@MainActor
struct SystemScreenAct: ScreenActing {
    private let look = SystemScreenLook()

    /// How long the target app gets to come to the front.
    static let frontmostLimit: TimeInterval = 2
    private static let messagingTimeout: Float = 1.5

    // MARK: - Read-only checks

    func isScreenLocked() -> Bool {
        // No session dictionary means no console session to act in.
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
        return (session["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    func focusedElementIsSecure(pid: Int32) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value)
        // An app that does not answer cannot be checked, so it is treated as if a password field had the focus.
        if result == .cannotComplete { return true }
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return false }
        let element = value as! AXUIElement
        return Self.text(element, kAXSubroleAttribute) == ActElements.secureSubrole
            || Self.text(element, kAXRoleAttribute) == ActElements.secureSubrole
    }

    func installedApp(_ ref: ActAppRef) -> ActApp? {
        let url: URL?
        switch ref {
        case .bundleId(let id):
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        case .name(let name):
            url = Self.appFolders.lazy.compactMap { folder -> URL? in
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
                let wanted = name.lowercased() + ".app"
                return names.first { $0.lowercased() == wanted }.map { URL(fileURLWithPath: folder).appendingPathComponent($0) }
            }.first
        }
        guard let url, let bundleId = Bundle(url: url)?.bundleIdentifier, !bundleId.isEmpty else { return nil }
        let shown = FileManager.default.displayName(atPath: url.path)
        return ActApp(name: shown.hasSuffix(".app") ? String(shown.dropLast(4)) : shown, bundleId: bundleId, url: url)
    }

    private static let appFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                                     "/Applications/Utilities", NSHomeDirectory() + "/Applications"]

    private static func text(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private var frontmostPid: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    // MARK: - Acting

    func perform(_ order: ActOrder, stillAllowed: @MainActor () -> String?) async -> ActFailure? {
        if let why = stillAllowed() { return ActFailure(message: why) }
        if isScreenLocked() { return .screenLocked }
        switch order {
        case .press(let handles, let index):
            return press(handles, index)
        case .open(let app):
            return await open(app)
        case .focus(let window, let pid):
            if case .failure(let f) = await bringForward(window: window, pid: pid) { return f }
            return nil
        case .click(let window, let pid, let x, let y, let button, let count):
            return await click(window: window, pid: pid, x: x, y: y, button: button, count: count, stillAllowed: stillAllowed)
        case .scroll(let window, let pid, let dx, let dy):
            return await scroll(window: window, pid: pid, dx: dx, dy: dy, stillAllowed: stillAllowed)
        case .keys(let window, let pid, let combo):
            return await keys(window: window, pid: pid, combo: combo, stillAllowed: stillAllowed)
        case .type(let window, let pid, let text):
            return await type(window: window, pid: pid, text: text, stillAllowed: stillAllowed)
        }
    }

    private func press(_ handles: AXHandles, _ index: Int) -> ActFailure? {
        guard handles.elements.indices.contains(index) else { return .elementGone }
        let element = handles.elements[index]
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        // An element that left the window no longer answers.
        guard Self.text(element, kAXRoleAttribute) != nil else { return .elementGone }
        switch AXUIElementPerformAction(element, kAXPressAction as CFString) {
        case .success: return nil
        // A press that opens a dialog can keep the app busy past the timeout although it went through.
        case .cannotComplete: return .pressUnconfirmed
        case .invalidUIElement: return .elementGone
        default: return .pressFailed
        }
    }

    private func open(_ app: ActApp) async -> ActFailure? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app.url, configuration: configuration)
            return nil
        } catch {
            return .launch(error.localizedDescription)
        }
    }

    private struct Front {
        var bounds: CGRect
        var app: AXUIElement
        /// nil when the window could not be matched in the app's accessibility tree.
        var window: AXUIElement?
    }

    /// Raises the window and waits until its app is the frontmost one.
    private func bringForward(window number: UInt32, pid: Int32) async -> Result<Front, ActFailure> {
        guard let placed = look.placed(number: number), placed.info.pid == pid,
              let running = NSRunningApplication(processIdentifier: pid) else { return .failure(.windowGone) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        let window = SystemScreenLook.axWindow(of: app, bounds: placed.bounds, title: placed.info.title)
        if let window {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if frontmostPid != pid {
            // This app is the active one right after a click on its card: it hands the activation over.
            NSApp.yieldActivation(to: running)
            running.activate(from: .current, options: [])
            AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        let limit = Date().addingTimeInterval(Self.frontmostLimit)
        while frontmostPid != pid, Date() < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard frontmostPid == pid else { return .failure(.notFrontmost) }
        // The raise takes a moment to reach the window server.
        try? await Task.sleep(for: .milliseconds(120))
        guard let now = look.placed(number: number) else { return .failure(.windowGone) }
        return .success(Front(bounds: now.bounds, app: app, window: window))
    }

    /// Checked right before every posted event.
    private func mayPost(pid: Int32, keyboard: Bool, stillAllowed: @MainActor () -> String?) -> ActFailure? {
        if let why = stillAllowed() { return ActFailure(message: why) }
        if isScreenLocked() { return .screenLocked }
        guard frontmostPid == pid else { return .lostFront }
        // The system switches secure input on while a password field has the keyboard, in any app.
        if keyboard, IsSecureEventInputEnabled() || focusedElementIsSecure(pid: pid) { return .secureField }
        return nil
    }

    /// Keys go to the app's focused window: it must be the window the person was shown.
    private func keyboardIsIn(_ front: Front, window number: UInt32, pid: Int32) -> Bool {
        if let window = front.window {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(front.app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
                return CFEqual(value, window)
            }
        }
        // No accessibility window to compare: the window must at least be the app's front one.
        return look.windows().first { $0.pid == pid }?.number == number
    }

    /// The window that would receive a click at `point` must be the target itself.
    private func obstacle(at point: CGPoint, window number: UInt32) -> ActFailure? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return .nothingThere }
        let me = getpid()
        for w in list {
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point), (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            if (w[kCGWindowNumber as String] as? UInt32) == number { return nil }
            if (w[kCGWindowOwnerPID as String] as? pid_t) == me { return .ownWindow }
            return .covered(by: w[kCGWindowOwnerName as String] as? String ?? "another app")
        }
        return .nothingThere
    }

    private func click(window: UInt32, pid: Int32, x: Double, y: Double, button: ActButton, count: Int,
                       stillAllowed: @MainActor () -> String?) async -> ActFailure? {
        let front: Front
        switch await bringForward(window: window, pid: pid) {
        case .failure(let f): return f
        case .success(let f): front = f
        }
        guard let point = ActGeometry.screenPoint(x: x, y: y, in: front.bounds) else { return .pointOutside }
        if let f = obstacle(at: point, window: window) { return f }
        let source = CGEventSource(stateID: .hidSystemState)
        let right = button == .right
        let mouseButton: CGMouseButton = right ? .right : .left
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseDown : .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: mouseButton),
              let up = CGEvent(mouseEventSource: source, mouseType: right ? .rightMouseUp : .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: mouseButton) else { return .events }
        for e in [move, down, up] { e.flags = [] }
        if let f = mayPost(pid: pid, keyboard: false, stillAllowed: stillAllowed) { return f }
        move.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(40))
        for n in 1...max(1, count) {
            if let f = mayPost(pid: pid, keyboard: false, stillAllowed: stillAllowed) { return f }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if n < count { try? await Task.sleep(for: .milliseconds(60)) }
        }
        return nil
    }

    private func scroll(window: UInt32, pid: Int32, dx: Int, dy: Int, stillAllowed: @MainActor () -> String?) async -> ActFailure? {
        let front: Front
        switch await bringForward(window: window, pid: pid) {
        case .failure(let f): return f
        case .success(let f): front = f
        }
        // The wheel scrolls what is under the pointer, so the pointer goes to the middle of the window first.
        let point = CGPoint(x: front.bounds.midX, y: front.bounds.midY)
        if let f = obstacle(at: point, window: window) { return f }
        let source = CGEventSource(stateID: .hidSystemState)
        // Wheel values are positive for up and for left; the tool counts down and right as positive.
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left),
              let wheel = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                                  wheel1: Int32(-dy), wheel2: Int32(-dx), wheel3: 0) else { return .events }
        move.flags = []
        wheel.flags = []
        wheel.location = point
        if let f = mayPost(pid: pid, keyboard: false, stillAllowed: stillAllowed) { return f }
        move.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(40))
        if let f = mayPost(pid: pid, keyboard: false, stillAllowed: stillAllowed) { return f }
        wheel.post(tap: .cghidEventTap)
        return nil
    }

    private func keys(window: UInt32, pid: Int32, combo: KeyCombo, stillAllowed: @MainActor () -> String?) async -> ActFailure? {
        let front: Front
        switch await bringForward(window: window, pid: pid) {
        case .failure(let f): return f
        case .success(let f): front = f
        }
        guard keyboardIsIn(front, window: window, pid: pid) else { return .focusElsewhere }
        var flags: CGEventFlags = []
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }
        if combo.modifiers.contains(.cmd) { flags.insert(.maskCommand) }
        if let f = mayPost(pid: pid, keyboard: true, stillAllowed: stillAllowed) { return f }
        return postKey(combo.keyCode, flags: flags) ? nil : .events
    }

    private func type(window: UInt32, pid: Int32, text: String, stillAllowed: @MainActor () -> String?) async -> ActFailure? {
        let front: Front
        switch await bringForward(window: window, pid: pid) {
        case .failure(let f): return f
        case .success(let f): front = f
        }
        guard keyboardIsIn(front, window: window, pid: pid) else { return .focusElsewhere }
        var typed = 0
        // Tab and Return are chunks of their own, so the checks below run again after anything that can move the focus.
        for chunk in ActText.chunks(text) {
            if let f = mayPost(pid: pid, keyboard: true, stillAllowed: stillAllowed) { return f.afterTyping(typed) }
            let posted: Bool
            switch chunk {
            case .text(let s):
                posted = postText(s)
                typed += s.count
            case .returnKey:
                posted = postKey(CGKeyCode(kVK_Return), flags: [])
                typed += 1
            case .tab:
                posted = postKey(CGKeyCode(kVK_Tab), flags: [])
                typed += 1
            }
            guard posted else { return ActFailure.events.afterTyping(typed) }
            // Lets the app take the characters in before the next check looks at the focus.
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    // MARK: - Events

    private func postKey(_ code: CGKeyCode, flags: CGEventFlags) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return false }
        // Set outright, so a modifier the person happens to hold is not mixed in.
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Characters are sent as text, not as key codes, so they do not depend on the keyboard layout.
    private func postText(_ text: String) -> Bool {
        let units = Array(text.utf16)
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
        down.flags = []
        up.flags = []
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
