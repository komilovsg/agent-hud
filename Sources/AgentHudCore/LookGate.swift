import Foundation

/// The person's setting for agents looking at the screen.
public enum ScreenAccessMode: String, CaseIterable, Sendable {
    /// Every look is refused.
    case off
    /// Every look asks, unless the person allowed that session.
    case ask
    /// The same gate; the request card puts "Allow for this session" first.
    case session

    public static let `default` = ScreenAccessMode.ask

    public var title: String {
        switch self {
        case .off: return "OFF"
        case .ask: return "ASK"
        case .session: return "PER SESSION"
        }
    }

    public var hint: String {
        switch self {
        case .off: return "Agents cannot look at the screen."
        case .ask: return "Every look asks you first."
        case .session: return "The first look of a session asks; you can allow the rest of that session."
        }
    }
}

/// One on-screen window as the app lists it. No pixels and no content.
public struct WindowInfo: Equatable, Sendable {
    public var number: UInt32
    public var app: String
    public var bundleId: String?
    public var pid: Int32
    public var title: String
    public var width: Int
    public var height: Int
    public var frontmost: Bool

    public init(number: UInt32, app: String, bundleId: String?, pid: Int32, title: String, width: Int, height: Int,
                frontmost: Bool = false) {
        self.number = number
        self.app = app
        self.bundleId = bundleId
        self.pid = pid
        self.title = title
        self.width = width
        self.height = height
        self.frontmost = frontmost
    }

    public var id: String { LookTarget.windowId(number) }

    /// "Safari — Start Page", or only the app when the window has no title.
    public var label: String { title.isEmpty ? app : "\(app) — \(title)" }
}

/// Apps whose windows agents never see: not in the list, not as a target, not inside a picture of the screen.
public enum LookExclusions {
    public static let defaults = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.systempreferences",
    ]

    /// Bundle ids are compared without regard to case. An excluded id also covers the ids under it
    /// ("com.apple.Passwords" covers "com.apple.Passwords.MenuBarExtra"): an app's helpers show its content too.
    public static func isExcluded(_ bundleId: String?, excluded: [String]) -> Bool {
        guard let b = bundleId?.lowercased(), !b.isEmpty else { return false }
        return excluded.contains { e in
            let e = e.lowercased()
            return !e.isEmpty && (b == e || b.hasPrefix(e + "."))
        }
    }

    public static func filter(_ windows: [WindowInfo], excluded: [String]) -> [WindowInfo] {
        windows.filter { !isExcluded($0.bundleId, excluded: excluded) }
    }

    /// A list for the settings: trimmed, no blanks, no duplicates (first spelling wins), order kept.
    public static func normalized(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in ids {
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBundleId(id), seen.insert(id.lowercased()).inserted else { continue }
            out.append(id)
        }
        return out
    }

    /// Letters, digits, dots, hyphens and underscores, with at least one dot.
    public static func isBundleId(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 155, s.contains("."), !s.hasPrefix("."), !s.hasSuffix(".") else { return false }
        return s.unicodeScalars.allSatisfy { ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "." || $0 == "-" || $0 == "_" }
    }
}

/// The consent gate, as a table: what is known about a look -> ask, allow or refuse.
public enum LookGate {
    public enum TargetState: Equatable, Sendable {
        /// The whole screen, the window list, or a window that exists and is not excluded.
        case available
        case unknownWindow
        case excludedApp
    }

    public enum Refusal: Equatable, Sendable {
        case off, unknownWindow, excludedApp, noScreenRecording, noAccessibility, denied, expired, failed

        /// The sentence the agent receives.
        public var message: String {
            switch self {
            case .off: return "Screen access is turned off in Agent HUD"
            case .unknownWindow: return "There is no such window. Call list_windows for the current window ids."
            case .excludedApp: return "That window belongs to an app the person excluded from screen access"
            case .noScreenRecording: return "Agent HUD does not have the Screen Recording permission, so it cannot take screenshots. The person can grant it in Agent HUD's setup window."
            case .noAccessibility: return "Agent HUD does not have the Accessibility permission, so it cannot read window text. The person can grant it in Agent HUD's setup window."
            case .denied: return "The person did not allow this"
            case .expired: return "The person did not answer in time"
            case .failed: return "Agent HUD could not do this"
            }
        }

        /// Short word for the activity log.
        public var logLabel: String {
            switch self {
            case .off: return "refused: off"
            case .unknownWindow: return "refused: no such window"
            case .excludedApp: return "refused: excluded app"
            case .noScreenRecording: return "refused: no Screen Recording"
            case .noAccessibility: return "refused: no Accessibility"
            case .denied: return "denied"
            case .expired: return "expired"
            case .failed: return "failed"
            }
        }

        /// The macOS permission whose absence caused the refusal.
        public var missingPermission: PermissionKind? {
            switch self {
            case .noScreenRecording: return .screenRecording
            case .noAccessibility: return .accessibility
            default: return nil
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Show the request card. `offersSession`: the card may offer "Allow for this session".
        case ask(offersSession: Bool)
        case allow
        case refuse(Refusal)
    }

    /// The order matters: a look that can never happen is refused without bothering the person.
    /// An allowance counts only for a session the app could identify. `consented`: the person has just clicked
    /// "Allow" on this very request - everything else is checked again, because it may have changed while the card waited.
    public static func decide(mode: ScreenAccessMode, tool: LookTool, sessionKnown: Bool, sessionAllowed: Bool,
                              consented: Bool = false,
                              target: TargetState, screenRecording: Bool, accessibility: Bool) -> Decision {
        if mode == .off { return .refuse(.off) }
        switch target {
        case .unknownWindow: return .refuse(.unknownWindow)
        case .excludedApp: return .refuse(.excludedApp)
        case .available: break
        }
        switch tool {
        case .screenshot where !screenRecording: return .refuse(.noScreenRecording)
        case .readWindowText where !accessibility: return .refuse(.noAccessibility)
        default: break
        }
        // "Ask every time" means every time: an earlier allowance is ignored and no lasting answer is offered.
        let lasting = mode == .session && sessionKnown
        if consented || (lasting && sessionAllowed) { return .allow }
        return .ask(offersSession: lasting)
    }

    /// Where a window target stands, given the current (unfiltered) window list.
    public static func targetState(_ target: LookTarget, windows: [WindowInfo], excluded: [String]) -> TargetState {
        guard case .window(let n) = target else { return .available }
        guard let w = windows.first(where: { $0.number == n }) else { return .unknownWindow }
        return LookExclusions.isExcluded(w.bundleId, excluded: excluded) ? .excludedApp : .available
    }
}

/// Sessions the person allowed to look without asking again. Kept in memory only; gone when the app quits.
public struct LookAllowances: Equatable, Sendable {
    public private(set) var sessions: Set<String> = []

    public init() {}

    public func contains(_ sessionKey: String) -> Bool { sessions.contains(sessionKey) }

    public mutating func allow(_ sessionKey: String) { sessions.insert(sessionKey) }

    public mutating func removeAll() { sessions.removeAll() }

    /// An allowance ends with its session: when the session ended or is no longer listed.
    public mutating func prune(_ store: SessionStore) {
        sessions = sessions.filter { key in
            guard let s = store.session(key) else { return false }
            return s.baseState != .ended
        }
    }
}

/// Which listed session a helper process belongs to.
public enum LookCallerResolver {
    public struct Candidate: Equatable, Sendable {
        public var key: String
        public var sessionId: String
        /// The session's agent process; nil when unknown.
        public var pid: Int32?
        public var ended: Bool
        public var lastEventAt: Date

        public init(key: String, sessionId: String, pid: Int32?, ended: Bool, lastEventAt: Date) {
            self.key = key
            self.sessionId = sessionId
            self.pid = pid
            self.ended = ended
            self.lastEventAt = lastEventAt
        }
    }

    /// `chain`: the helper's ancestors, nearest first, as the app read them from the socket's peer.
    /// The nearest ancestor that is a live session's agent process decides. The id the helper claims only picks
    /// between sessions of that same process (a process that started a new conversation); alone it proves nothing.
    public static func resolve(chain: [Int32], claimedSessionId: String?, candidates: [Candidate]) -> String? {
        let live = candidates.filter { !$0.ended && $0.pid != nil }
        for pid in chain {
            let matches = live.filter { $0.pid == pid }
            guard !matches.isEmpty else { continue }
            if let claimed = claimedSessionId, let m = matches.first(where: { $0.sessionId == claimed }) { return m.key }
            return matches.max { $0.lastEventAt < $1.lastEventAt }?.key
        }
        return nil
    }
}

/// Size and format rules for a screenshot.
public enum LookImage {
    public static let defaultMaxSide = 1568
    public static let hardCap = 2000
    public static let minSide = 64
    public static let jpegQuality = 0.8
    public static let mimeTypes: Set<String> = ["image/png", "image/jpeg"]
    /// PNG is tried only for small pictures and kept only when the file is small too.
    public static let pngPixelLimit = 500_000
    public static let pngByteLimit = 400_000

    /// The requested longer side, clamped; nil -> the default.
    public static func maxSide(_ requested: Int?) -> Int {
        guard let r = requested else { return defaultMaxSide }
        return min(max(r, minSide), hardCap)
    }

    /// Scales down so that the longer side is at most `maxSide`, keeping the proportions. Never scales up;
    /// no side goes below one pixel.
    public static func scaledSize(width: Int, height: Int, maxSide: Int) -> (width: Int, height: Int) {
        let w = max(1, width), h = max(1, height), limit = max(1, maxSide)
        let longer = max(w, h)
        guard longer > limit else { return (w, h) }
        let scale = Double(limit) / Double(longer)
        return (max(1, Int((Double(w) * scale).rounded())), max(1, Int((Double(h) * scale).rounded())))
    }

    public static func triesPNG(width: Int, height: Int) -> Bool { width * height <= pngPixelLimit }

    public static func keepsPNG(bytes: Int) -> Bool { bytes <= pngByteLimit }

    /// The text line that goes with the picture.
    public static func caption(what: String, width: Int, height: Int, mimeType: String) -> String {
        "Screenshot of \(what), \(width)×\(height) px, \(mimeType == "image/png" ? "PNG" : "JPEG")"
    }
}

/// A node of a window's accessibility tree, reduced to what is printed.
public struct LookNode: Equatable, Sendable {
    public var role: String
    public var title: String
    public var value: String
    public var children: [LookNode]
    /// Set for an element that can be pressed: the walker's own index of it. nil for everything else.
    public var handle: Int?

    public init(role: String, title: String = "", value: String = "", children: [LookNode] = [], handle: Int? = nil) {
        self.role = role
        self.title = title
        self.value = value
        self.children = children
        self.handle = handle
    }
}

public enum LookText {
    public static let limit = 20_000
    static let valueLimit = 2_000

    /// At most `limit` characters; a longer text ends with a note saying how much was cut.
    public static func cap(_ text: String, limit: Int = LookText.limit) -> String {
        let total = text.count
        guard total > limit else { return text }
        return String(text.prefix(limit)) + "\n[Truncated: the first \(limit) of \(total) characters are shown]"
    }

    /// Roles and values, two spaces per level. A node without any text is printed only when something under it has text.
    public static func render(_ root: LookNode) -> String {
        var lines: [String] = []
        var refs: [ElementRefs.Entry]?
        _ = append(root, depth: 0, into: &lines, refs: &refs, firstRef: 0)
        return lines.joined(separator: "\n")
    }

    /// The same text with a reference in front of every element that can be pressed: `[e12] Button "Send"`.
    /// References are numbered from `firstRef` in the order they are printed. A pressable element is printed
    /// even when it has no text of its own.
    public static func render(_ root: LookNode, firstRef: Int) -> (text: String, entries: [ElementRefs.Entry]) {
        var lines: [String] = []
        var refs: [ElementRefs.Entry]? = []
        _ = append(root, depth: 0, into: &lines, refs: &refs, firstRef: firstRef)
        return (lines.joined(separator: "\n"), refs ?? [])
    }

    private static func append(_ node: LookNode, depth: Int, into lines: inout [String], refs: inout [ElementRefs.Entry]?,
                               firstRef: Int) -> Bool {
        let title = oneLine(node.title), value = oneLine(node.value)
        let role = node.role.hasPrefix("AX") ? String(node.role.dropFirst(2)) : node.role
        var line = String(repeating: "  ", count: depth)
        var pressable = false
        if let handle = node.handle, refs != nil {
            let ref = firstRef + (refs?.count ?? 0)
            let label = title.isEmpty ? value : title
            refs?.append(ElementRefs.Entry(ref: ref, handle: handle, role: node.role,
                                           label: label.count > 80 ? String(label.prefix(80)) + "…" : label))
            line += "[\(ActCall.elementId(ref))] "
            pressable = true
        }
        line += role.isEmpty ? "Element" : role
        if !title.isEmpty { line += " \"\(title)\"" }
        if !value.isEmpty, value != title { line += ": \(value)" }
        let index = lines.count
        lines.append(line)
        var hasText = pressable || !title.isEmpty || !value.isEmpty
        for child in node.children where append(child, depth: depth + 1, into: &lines, refs: &refs, firstRef: firstRef) { hasText = true }
        if !hasText { lines.removeSubrange(index...) }
        return hasText
    }

    static func oneLine(_ s: String) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > valueLimit ? String(flat.prefix(valueLimit)) + "…" : flat
    }

    /// The `list_windows` answer: one line per window, front to back.
    public static func windowList(_ windows: [WindowInfo], titlesAvailable: Bool = true) -> String {
        guard !windows.isEmpty else { return "No windows are on screen." }
        var lines = ["\(windows.count) \(windows.count == 1 ? "window" : "windows"), front to back:"]
        for w in windows {
            var line = "\(w.id)  \(w.app)"
            if !w.title.isEmpty { line += " — \"\(oneLine(w.title))\"" }
            line += "  \(w.width)×\(w.height)"
            if w.frontmost { line += "  frontmost" }
            lines.append(line)
        }
        if !titlesAvailable { lines.append("Window titles are missing: Agent HUD does not have the Screen Recording permission.") }
        return lines.joined(separator: "\n")
    }
}

/// A look waiting for the person's click.
public struct LookPending: Identifiable, Equatable, Sendable {
    public let id: String            // request_id of the helper's connection
    public var sessionKey: String
    public var call: LookCall
    /// App and window title of a window target; nil for the screen and the window list.
    public var window: WindowInfo?
    /// For a picture of the screen: the app in front, when it is not excluded.
    public var frontApp: String?
    public var createdAt: Date
    public var deadline: Date
    public var offersSession: Bool

    public init(id: String, sessionKey: String, call: LookCall, window: WindowInfo? = nil, frontApp: String? = nil,
                createdAt: Date, deadline: Date, offersSession: Bool) {
        self.id = id
        self.sessionKey = sessionKey
        self.call = call
        self.window = window
        self.frontApp = frontApp
        self.createdAt = createdAt
        self.deadline = deadline
        self.offersSession = offersSession
    }

    public var title: String { LookLabels.title(call) }
    public var targetLine: String { LookLabels.target(call, window: window, frontApp: frontApp) }
    /// Only a screenshot leaves the Mac as pixels.
    public var sendsPicture: Bool { call.tool == .screenshot }
}

public enum LookLabels {
    public static let unknownAgent = "Unknown agent"
    /// The placeholder entry that carries requests of a caller the app could not match to a session.
    public static let unknownSessionId = "unknown-agent"
    public static let pictureNote = "The picture is sent to the model"
    public static let unknownNote = "Agent HUD could not tell which session is asking, so this can only be allowed once."

    public static func title(_ call: LookCall) -> String {
        switch (call.tool, call.target) {
        case (.listWindows, _): return "Wants the list of open windows"
        case (.readWindowText, _): return "Wants to read a window's text"
        case (.screenshot, .window): return "Wants to see a window"
        case (.screenshot, _): return "Wants to see the screen"
        }
    }

    /// The exact target, for the card.
    public static func target(_ call: LookCall, window: WindowInfo?, frontApp: String?) -> String {
        switch (call.tool, call.target) {
        case (.listWindows, _): return "App names, window titles and sizes. No picture."
        case (_, .window): return window?.label ?? "A window"
        default: return frontApp.map { "The display with \($0) in front" } ?? "The display under the frontmost window"
        }
    }

    /// What was looked at, for the log and the "Looked at" row.
    public static func subject(_ call: LookCall, window: WindowInfo?) -> String {
        switch (call.tool, call.target) {
        case (.listWindows, _): return "the list of open windows"
        case (.readWindowText, _): return "text of \(window?.label ?? "a window")"
        case (.screenshot, .window): return window?.label ?? "a window"
        case (.screenshot, _): return "the screen"
        }
    }

    public static func symbol(_ tool: LookTool) -> String {
        switch tool {
        case .listWindows: return "macwindow.on.rectangle"
        case .screenshot: return "eye.fill"
        case .readWindowText: return "text.viewfinder"
        }
    }
}

/// Registering `agenthud-mcp` with Claude Code. Only argument lists are built here; nothing is run.
public enum ScreenTools {
    public static let serverName = MCPServer.serverName

    public enum Status: Equatable, Sendable { case registered, notRegistered, unknown }

    /// The helper's path goes into a config and onto a command line: absolute, and nothing a terminal would not print.
    public static func isUsablePath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.count <= 1024 && !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// The value of `--mcp-config`: an inline JSON string with this one stdio server. nil for an unusable path.
    public static func configJSON(helperPath: String) -> String? {
        guard isUsablePath(helperPath) else { return nil }
        let server: JSONValue = ["command": .string(helperPath), "args": []]
        let servers = JSONValue.object(JSONObject([JSONObject.Entry(serverName, server)]))
        return (["mcpServers": servers] as JSONValue).compact()
    }

    /// `claude mcp add --scope user agenthud -- <helper>`, without the program itself.
    public static func addArguments(helperPath: String) -> [String]? {
        guard isUsablePath(helperPath) else { return nil }
        return ["mcp", "add", "--scope", "user", serverName, "--", helperPath]
    }

    public static let removeArguments = ["mcp", "remove", "--scope", "user", serverName]
    public static let statusArguments = ["mcp", "get", serverName]

    /// How the command is shown to the person before it runs. Display only: the command is started from the list.
    public static func display(program: String, arguments: [String]) -> String {
        ([program] + arguments).map { a in
            let plain = !a.isEmpty && a.unicodeScalars.allSatisfy {
                ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || "/._-~=:@%+".unicodeScalars.contains($0)
            }
            return plain ? a : "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    /// Reads the answer of `claude mcp get agenthud`: it exits with 0 for a configured server and names a missing one.
    public static func status(exitCode: Int32, output: String) -> Status {
        if exitCode == 0 { return .registered }
        if output.contains("No MCP server named") { return .notRegistered }
        return .unknown
    }
}
