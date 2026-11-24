import Foundation

/// The person's setting for agents acting in other apps.
public enum HandsAccessMode: String, CaseIterable, Sendable {
    /// Every action is refused.
    case off
    /// Every action asks.
    case ask
    /// Every action asks, unless the person allowed that app for that session.
    case perApp

    public static let `default` = HandsAccessMode.off

    public var title: String {
        switch self {
        case .off: return "OFF"
        case .ask: return "ASK"
        case .perApp: return "PER APP"
        }
    }

    public var hint: String {
        switch self {
        case .off: return "Off: agents cannot click, type or open anything."
        case .ask: return "Ask: every action asks you first."
        case .perApp: return "Per app: the first action in an app asks; you can allow the rest in that app for that session."
        }
    }
}

/// Apps agents never act in.
public enum ActExclusions {
    /// The login window and the system's password prompt, on top of the apps hidden from looks by default
    /// (password managers, System Settings). The person cannot take these off the list.
    public static let system = ["com.apple.loginwindow", "com.apple.SecurityAgent"]

    /// The part of the list that is always there. `ownBundleId`: this app - an agent never clicks its own consent card.
    public static func always(ownBundleId: String) -> [String] {
        LookExclusions.normalized([ownBundleId] + system + LookExclusions.defaults)
    }

    /// Everything hands stay out of: the always-excluded apps and the apps the person hid from looks.
    public static func list(screenExcluded: [String], ownBundleId: String) -> [String] {
        LookExclusions.normalized(always(ownBundleId: ownBundleId) + screenExcluded)
    }

    public static func isExcluded(_ bundleId: String?, screenExcluded: [String], ownBundleId: String) -> Bool {
        LookExclusions.isExcluded(bundleId, excluded: list(screenExcluded: screenExcluded, ownBundleId: ownBundleId))
    }
}

/// Key combinations that can close or delete things: they always ask, and never get a lasting answer.
public enum ActRisk {
    /// Apps where a combination with Command runs a command of its own kind: a shell, or the file manager.
    public static let commandSensitiveApps = ["com.apple.Terminal", "com.googlecode.iterm2", "com.apple.finder"]

    public static func isRisky(_ combo: KeyCombo, targetBundleId: String?) -> Bool {
        let m = combo.modifiers
        guard m.contains(.cmd) else { return false }
        // Quit, also with Shift (log out), Control (lock the screen) or Option.
        if combo.key == "q" { return true }
        // Close all windows, close other tabs.
        if combo.key == "w", m.contains(.shift) || m.contains(.option) { return true }
        // Move to the Trash, empty the Trash, delete to the start of the line.
        if combo.key == "delete" { return true }
        // Force Quit.
        if combo.key == "escape", m.contains(.option) { return true }
        return LookExclusions.isExcluded(targetBundleId, excluded: commandSensitiveApps)
    }
}

/// The consent gate for actions, as a table: what is known about an action -> ask, allow or refuse.
public enum ActGate {
    public enum TargetState: Equatable, Sendable {
        case available
        case unknownWindow
        /// The app to open is not installed, or the target's app cannot be identified.
        case unknownApp
        /// The element reference is not from the latest read of that window.
        case staleElement
    }

    public enum Refusal: Equatable, Sendable, CaseIterable {
        case off, unknownSession, sessionHeld, noAccessibility, unknownWindow, unknownApp, staleElement, excludedApp, secureField
        /// Not from the table: the person's answer, the clock, the stop switch, and what the executor found.
        case denied, expired, stopped, changed, screenLocked, failed

        /// The sentence the agent receives.
        public var message: String {
            switch self {
            case .off: return "Acting in apps is turned off in Agent HUD"
            case .unknownSession: return "Agent HUD could not tell which session is calling, so it cannot act for it"
            case .sessionHeld: return "The person paused or stopped this session in Agent HUD"
            case .noAccessibility: return "Agent HUD does not have the Accessibility permission, so it cannot act in apps. The person can grant it in Agent HUD's setup window."
            case .unknownWindow: return "There is no such window. Call list_windows for the current window ids."
            case .unknownApp: return "Agent HUD could not find that app"
            case .staleElement: return "That element reference is not valid any more. Call read_window_text for this window again and use the new references."
            case .excludedApp: return "Agent HUD never acts in that app"
            case .secureField: return "A password field has the focus. Agent HUD does not type into password fields."
            case .denied: return "The person did not allow this"
            case .expired: return "The person did not answer in time"
            case .stopped: return "The person stopped agent actions in Agent HUD"
            case .changed: return "Things changed before this could be done. Look again and call the tool once more if it is still needed."
            case .screenLocked: return "The screen is locked"
            case .failed: return "Agent HUD could not do this"
            }
        }

        /// Short word for the activity log.
        public var logLabel: String {
            switch self {
            case .off: return "refused: off"
            case .unknownSession: return "refused: unknown session"
            case .sessionHeld: return "refused: session held"
            case .noAccessibility: return "refused: no Accessibility"
            case .unknownWindow: return "refused: no such window"
            case .unknownApp: return "refused: no such app"
            case .staleElement: return "refused: stale element"
            case .excludedApp: return "refused: excluded app"
            case .secureField: return "refused: password field"
            case .denied: return "denied"
            case .expired: return "expired"
            case .stopped: return "refused: stopped"
            case .changed: return "refused: changed"
            case .screenLocked: return "refused: screen locked"
            case .failed: return "failed"
            }
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Show the request card. `offersApp`: the card may offer "Allow in <App> for this session".
        case ask(offersApp: Bool)
        case allow
        case refuse(Refusal)
    }

    /// The first rule that matches wins.
    /// `consented`: the person has just clicked "Allow" on this very request. Everything above that rule is
    /// checked again with fresh facts, because it may have changed while the card waited.
    public static func decide(mode: HandsAccessMode, kind: ActKind, sessionKnown: Bool, sessionHeld: Bool,
                              accessibilityGranted: Bool, target: TargetState, targetExcluded: Bool, secureField: Bool,
                              riskyKeys: Bool, rateExceeded: Bool, appAllowedForSession: Bool,
                              consented: Bool = false) -> Decision {
        // 1
        if mode == .off { return .refuse(.off) }
        // 2: never for a caller the app cannot match to a session, not even once
        if !sessionKnown { return .refuse(.unknownSession) }
        // 3
        if sessionHeld { return .refuse(.sessionHeld) }
        // 4
        if !accessibilityGranted { return .refuse(.noAccessibility) }
        // 5
        switch target {
        case .unknownWindow: return .refuse(.unknownWindow)
        case .unknownApp: return .refuse(.unknownApp)
        case .staleElement: return .refuse(.staleElement)
        case .available: break
        }
        // 6
        if targetExcluded { return .refuse(.excludedApp) }
        // 7
        if secureField, kind.usesKeyboard { return .refuse(.secureField) }
        // 8
        if consented { return .allow }
        // 9, 10: these ask every time and never offer a lasting answer
        if riskyKeys { return .ask(offersApp: false) }
        if rateExceeded { return .ask(offersApp: false) }
        // 11
        if mode == .perApp, appAllowedForSession { return .allow }
        // 12
        return .ask(offersApp: mode == .perApp)
    }
}

/// How many actions a session was allowed lately. Past the limit every action asks again until the window slides.
public struct ActRate: Equatable, Sendable {
    public static let limit = 30
    public static let window: TimeInterval = 60

    private var times: [String: [Date]] = [:]

    public init() {}

    /// An action of `sessionKey` was allowed at `now`.
    public mutating func record(_ sessionKey: String, at now: Date) {
        times[sessionKey] = recent(sessionKey, at: now) + [now]
    }

    public func count(_ sessionKey: String, at now: Date) -> Int { recent(sessionKey, at: now).count }

    /// True when one more allowed action would make it more than `limit` within `window`.
    public func exceeded(_ sessionKey: String, at now: Date) -> Bool { count(sessionKey, at: now) >= Self.limit }

    public mutating func removeAll() { times.removeAll() }

    private func recent(_ sessionKey: String, at now: Date) -> [Date] {
        (times[sessionKey] ?? []).filter { now.timeIntervalSince($0) < Self.window }
    }
}

/// "Allow in <App> for this session": pairs of a session and an app. Kept in memory only.
public struct ActAllowances: Equatable, Sendable {
    private struct Pair: Hashable, Sendable {
        var session: String
        var app: String
    }

    private var pairs: Set<Pair> = []
    private var mode: HandsAccessMode?

    public init() {}

    public var isEmpty: Bool { pairs.isEmpty }

    public func contains(session: String, bundleId: String?) -> Bool {
        guard let app = bundleId?.lowercased(), !app.isEmpty else { return false }
        return pairs.contains(Pair(session: session, app: app))
    }

    public mutating func allow(session: String, bundleId: String?) {
        guard let app = bundleId?.lowercased(), !app.isEmpty else { return }
        pairs.insert(Pair(session: session, app: app))
    }

    /// The stop switch.
    public mutating func removeAll() { pairs.removeAll() }

    /// Allowances belong to the mode they were given in: any change of the mode clears them.
    public mutating func sync(mode next: HandsAccessMode) {
        if mode != next { pairs.removeAll() }
        mode = next
    }

    /// An allowance ends with its session: when the session ended or is no longer listed.
    public mutating func prune(_ store: SessionStore) {
        pairs = pairs.filter { p in
            guard let s = store.session(p.session) else { return false }
            return s.baseState != .ended
        }
    }
}

/// The references `read_window_text` printed (`[e12] Button "Send"`), per window. A reference is good until
/// that window is read again; numbers are never reused, so an old reference cannot point at another element.
public struct ElementRefs: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var ref: Int
        /// The walker's index of the element (see `LookNode.handle`).
        public var handle: Int
        public var role: String
        public var label: String

        public init(ref: Int, handle: Int, role: String, label: String) {
            self.ref = ref
            self.handle = handle
            self.role = role
            self.label = label
        }
    }

    public private(set) var next = 1
    private var windows: [UInt32: [Int: Entry]] = [:]

    public init() {}

    /// Renders the window's text with fresh references and remembers them in place of the window's earlier ones.
    public mutating func read(window: UInt32, _ root: LookNode) -> String {
        let (text, entries) = LookText.render(root, firstRef: next)
        next += entries.count
        windows[window] = Dictionary(entries.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return text
    }

    /// nil for a reference of an earlier read, of another window, or one that was never printed.
    public func resolve(window: UInt32, ref: Int) -> Entry? { windows[window]?[ref] }

    public var windowNumbers: Set<UInt32> { Set(windows.keys) }

    public mutating func forget(window: UInt32) { windows[window] = nil }

    /// Windows that are gone take their references with them.
    public mutating func prune(keeping live: Set<UInt32>) {
        windows = windows.filter { live.contains($0.key) }
    }

    public mutating func removeAll() { windows.removeAll() }
}

public enum ActElements {
    /// Accessibility roles that get a reference: controls whose press action does what a click on them does.
    public static let pressableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenuBarItem",
        "AXLink", "AXDisclosureTriangle", "AXTab",
    ]

    public static func isPressable(role: String, enabled: Bool) -> Bool { enabled && pressableRoles.contains(role) }

    public static let secureSubrole = "AXSecureTextField"

    /// "AXPopUpButton" -> "pop-up button"; an unknown role is spelled out from its name.
    public static func roleName(_ role: String) -> String {
        switch role {
        case "AXCheckBox": return "checkbox"
        case "AXPopUpButton": return "pop-up button"
        case "": return "element"
        default: break
        }
        let bare = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        var out = ""
        for ch in bare {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(contentsOf: ch.lowercased())
        }
        return out
    }
}

public enum ActGeometry {
    /// A point given in window points (origin at the window's top-left corner) as a point on screen, in the
    /// same top-left based coordinates the window's frame is in. nil for a point outside the window.
    public static func screenPoint(x: Double, y: Double, in frame: CGRect) -> CGPoint? {
        guard x.isFinite, y.isFinite, frame.width > 0, frame.height > 0,
              x >= 0, y >= 0, x < Double(frame.width), y < Double(frame.height) else { return nil }
        return CGPoint(x: Double(frame.minX) + x, y: Double(frame.minY) + y)
    }
}

/// What an action is aimed at, as the card, the answer and the log name it.
public struct ActSubject: Equatable, Sendable {
    public var app: String
    public var bundleId: String?
    public var windowTitle: String
    /// For `press_element`: the element's Accessibility role and its label.
    public var elementRole: String?
    public var elementLabel: String?

    public init(app: String, bundleId: String? = nil, windowTitle: String = "", elementRole: String? = nil, elementLabel: String? = nil) {
        self.app = app
        self.bundleId = bundleId
        self.windowTitle = windowTitle
        self.elementRole = elementRole
        self.elementLabel = elementLabel
    }

    /// "Mail — Inbox", or only the app when the window has no title.
    public var label: String { windowTitle.isEmpty ? app : "\(app) — \(windowTitle)" }

    /// `button "Send"`, or only the role for an element without a label.
    public var element: String {
        let role = ActElements.roleName(elementRole ?? "")
        guard let l = elementLabel, !l.isEmpty else { return role }
        return "\(role) \"\(l)\""
    }
}

/// An action waiting for the person's click.
public struct ActPending: Identifiable, Equatable, Sendable {
    public let id: String            // request_id of the helper's connection
    public var sessionKey: String
    public var call: ActCall
    public var subject: ActSubject
    public var createdAt: Date
    public var deadline: Date
    public var offersApp: Bool
    /// The key combination can close or delete things.
    public var risky: Bool

    public init(id: String, sessionKey: String, call: ActCall, subject: ActSubject, createdAt: Date, deadline: Date,
                offersApp: Bool, risky: Bool = false) {
        self.id = id
        self.sessionKey = sessionKey
        self.call = call
        self.subject = subject
        self.createdAt = createdAt
        self.deadline = deadline
        self.offersApp = offersApp
        self.risky = risky
    }

    public var title: String { ActLabels.title(call.kind) }
    public var targetLine: String { ActLabels.target(call, subject) }
    public var detail: String? { ActLabels.detail(call, subject) }
    /// The whole text of a `type_text` call, as the card shows it.
    public var typedText: String? {
        if case .typeText(let t) = call.body { return ActLabels.typedDisplay(t) }
        return nil
    }
    public var typeNote: String? {
        if case .typeText(let t) = call.body { return ActLabels.typeNote(t) }
        return nil
    }
}

public enum ActLabels {
    public static let riskyNote = "This key combination can close or delete things"
    public static let stopHotKey = "⌃⌥⌘."
    public static let stopTitle = "Stop agent actions"
    public static let previewLength = 40

    public static func title(_ kind: ActKind) -> String {
        switch kind {
        case .pressElement: return "Wants to press a button"
        case .clickAt: return "Wants to click"
        case .typeText: return "Wants to type"
        case .pressKeys: return "Wants to press keys"
        case .scroll: return "Wants to scroll"
        case .focusWindow: return "Wants to bring a window forward"
        case .openApp: return "Wants to open an app"
        }
    }

    public static func symbol(_ kind: ActKind) -> String {
        switch kind {
        case .pressElement: return "hand.tap"
        case .clickAt: return "cursorarrow.click"
        case .typeText: return "keyboard"
        case .pressKeys: return "command"
        case .scroll: return "arrow.up.and.down"
        case .focusWindow: return "macwindow"
        case .openApp: return "app.badge"
        }
    }

    /// Where: the app and the window's title. For `open_app` the app and its bundle id.
    public static func target(_ call: ActCall, _ subject: ActSubject) -> String {
        if call.kind == .openApp, let id = subject.bundleId { return "\(subject.app) (\(id))" }
        return subject.label
    }

    /// What exactly, besides the target. nil where the title and the target say it all (and for typing,
    /// whose text has a box of its own).
    public static func detail(_ call: ActCall, _ subject: ActSubject) -> String? {
        switch call.body {
        case .pressElement: return "Press \(subject.element)"
        case .clickAt(let x, let y, let button, let count): return "\(clickWord(button, count)) at \(point(x, y))"
        case .pressKeys(let combo): return combo.symbols
        case .scroll(let dx, let dy): return "Scroll \(scrollWords(dx: dx, dy: dy))"
        case .typeText, .focusWindow, .openApp: return nil
        }
    }

    /// "types 12 characters".
    public static func typeNote(_ text: String) -> String {
        "types \(text.count) \(text.count == 1 ? "character" : "characters")"
    }

    /// The text as it is shown before typing: every newline is marked with ⏎ and still breaks the line, a tab is ⇥.
    public static func typedDisplay(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "⏎\n").replacingOccurrences(of: "\t", with: "⇥")
    }

    public static func allowInApp(_ app: String) -> String { "Allow in \(app) for this session" }

    public static func stoppedNotice(at time: String) -> String { "Agent actions are off — stopped at \(time)" }

    /// The tool's answer after the action was carried out: `Pressed button "Send" in Mail`.
    public static func done(_ call: ActCall, _ subject: ActSubject) -> String {
        words(call, subject, past: true, preview: false)
    }

    /// The action for the activity log, whatever became of it: `Press button "Send" in Mail`.
    /// Typed text is kept as its first characters and its length.
    public static func summary(_ call: ActCall, _ subject: ActSubject) -> String {
        words(call, subject, past: false, preview: true)
    }

    /// The row a session's card keeps after the action: `Did: pressed button "Send" in Mail`.
    public static func didRow(_ call: ActCall, _ subject: ActSubject) -> String {
        let text = words(call, subject, past: true, preview: true)
        return "Did: " + text.prefix(1).lowercased() + text.dropFirst()
    }

    private static func words(_ call: ActCall, _ subject: ActSubject, past: Bool, preview: Bool) -> String {
        switch call.body {
        case .pressElement:
            return "\(past ? "Pressed" : "Press") \(subject.element) in \(subject.app)"
        case .clickAt(let x, let y, let button, let count):
            return "\(clickWord(button, count))\(past ? "ed" : "") at \(point(x, y)) in \(subject.label)"
        case .typeText(let text):
            let length = "\(text.count) \(text.count == 1 ? "character" : "characters")"
            guard preview else { return "\(past ? "Typed" : "Type") \(length) into \(subject.label)" }
            let flat = text.split(whereSeparator: { $0.isNewline || $0 == "\t" }).joined(separator: " ")
            let head = flat.count > previewLength ? String(flat.prefix(previewLength)) + "…" : flat
            return "\(past ? "Typed" : "Type") \"\(head)\" (\(length)) into \(subject.label)"
        case .pressKeys(let combo):
            return "\(past ? "Pressed" : "Press") \(combo.symbols) in \(subject.label)"
        case .scroll(let dx, let dy):
            return "\(past ? "Scrolled" : "Scroll") \(scrollWords(dx: dx, dy: dy)) in \(subject.label)"
        case .focusWindow:
            return "\(past ? "Brought" : "Bring") \(subject.label) to the front"
        case .openApp:
            return "\(past ? "Opened" : "Open") \(subject.app)"
        }
    }

    static func point(_ x: Double, _ y: Double) -> String { "(\(Int(x.rounded())), \(Int(y.rounded())))" }

    static func clickWord(_ button: ActButton, _ count: Int) -> String {
        switch (button, count) {
        case (.left, 2): return "Double-click"
        case (.right, 2): return "Right double-click"
        case (.right, _): return "Right-click"
        default: return "Click"
        }
    }

    static func scrollWords(dx: Int, dy: Int) -> String {
        func lines(_ n: Int) -> String { "\(abs(n)) \(abs(n) == 1 ? "line" : "lines")" }
        var parts: [String] = []
        if dy != 0 { parts.append("\(dy > 0 ? "down" : "up") \(lines(dy))") }
        if dx != 0 { parts.append("\(dx > 0 ? "right" : "left") \(lines(dx))") }
        return parts.joined(separator: " and ")
    }
}
