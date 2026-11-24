import Darwin
import Foundation

/// The "act" tools an agent can call through `agenthud-mcp`: things done in other apps on the person's behalf.
/// Names are part of the tool interface.
public enum ActKind: String, CaseIterable, Sendable {
    case pressElement = "press_element"
    case clickAt = "click_at"
    case typeText = "type_text"
    case pressKeys = "press_keys"
    case scroll
    case focusWindow = "focus_window"
    case openApp = "open_app"

    /// Tools that go through the keyboard: they are refused while a password field has the focus.
    public var usesKeyboard: Bool { self == .typeText || self == .pressKeys }
}

public enum ActButton: String, Sendable { case left, right }

/// How `open_app` names an app.
public enum ActAppRef: Equatable, Sendable {
    case bundleId(String)
    case name(String)

    public var text: String {
        switch self {
        case .bundleId(let s), .name(let s): return s
        }
    }

    /// An app name as it appears in the Applications folder: no path parts, nothing a file name cannot hold.
    public static func isAppName(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 100, !s.hasPrefix("."), s == s.trimmingCharacters(in: .whitespaces) else { return false }
        return !s.unicodeScalars.contains { $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control }
    }
}

/// What is wrong with a call's arguments, as a sentence for the agent.
public struct ActProblem: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - Key combinations

/// One key with modifiers, e.g. "cmd+s".
public struct KeyCombo: Equatable, Sendable {
    public struct Modifiers: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let cmd = Modifiers(rawValue: 8)
    }

    public var modifiers: Modifiers
    /// A name from `KeyCombo.keyCodes`.
    public var key: String

    public init(modifiers: Modifiers = [], key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Modifier names in the order they are written and shown.
    static let modifierOrder: [(Modifiers, name: String, symbol: String)] = [
        (.control, "control", "⌃"), (.option, "option", "⌥"), (.shift, "shift", "⇧"), (.cmd, "cmd", "⌘"),
    ]

    /// Other spellings agents use for the four modifiers.
    static let modifierAliases: [String: Modifiers] = [
        "cmd": .cmd, "command": .cmd, "shift": .shift, "option": .option, "opt": .option, "alt": .option,
        "control": .control, "ctrl": .control,
    ]

    /// Every key that can be pressed, with its virtual key code on an ANSI keyboard. Nothing outside this table is accepted.
    public static let keyCodes: [String: UInt16] = {
        var t: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "=": 24, "-": 27, "]": 30, "[": 33, "'": 39, ";": 41, "\\": 42, ",": 43, "/": 44, ".": 47, "`": 50,
            "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "forwarddelete": 117,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        let function: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in function.enumerated() { t["f\(i + 1)"] = code }
        return t
    }()

    /// The key names as the tool description lists them.
    public static let keyNamesHelp = "a-z, 0-9, return, tab, space, escape, delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1-f12 and - = [ ] ; ' , . / \\ `"

    static let symbols: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "Space", "delete": "⌫", "escape": "⎋", "forwarddelete": "⌦",
        "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟", "left": "←", "right": "→", "down": "↓", "up": "↑",
    ]

    public var keyCode: UInt16 { Self.keyCodes[key] ?? 0 }

    /// "control+shift+cmd+s": the one spelling that travels to the app and into the log.
    public var canonical: String {
        (Self.modifierOrder.filter { modifiers.contains($0.0) }.map(\.name) + [key]).joined(separator: "+")
    }

    /// "⌃⇧⌘S", as the Mac's menus write it.
    public var symbols: String {
        Self.modifierOrder.filter { modifiers.contains($0.0) }.map(\.symbol).joined() + (Self.symbols[key] ?? key.uppercased())
    }

    /// "cmd+s", "Shift + Tab", "escape". Exactly one key from the table, each modifier at most once.
    public static func parse(_ text: String) -> Result<KeyCombo, ActProblem> {
        let example = "for example \"cmd+s\" or \"escape\""
        guard !text.isEmpty, text.count <= 60 else { return .failure(ActProblem("keys must be a key combination, \(example)")) }
        var modifiers: Modifiers = []
        var key: String?
        for part in text.split(separator: "+", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces).lowercased()
            if let m = modifierAliases[token] {
                guard !modifiers.contains(m) else { return .failure(ActProblem("keys names the same modifier twice: \(token)")) }
                modifiers.insert(m)
            } else if keyCodes[token] != nil {
                guard key == nil else { return .failure(ActProblem("keys must have exactly one key besides the modifiers, \(example)")) }
                key = token
            } else {
                let shown = RequestLog.clip(String(token.prefix(20)))
                return .failure(ActProblem("Unknown key: \"\(shown)\". Keys: \(keyNamesHelp). Modifiers: cmd, shift, option, control."))
            }
        }
        guard let key else { return .failure(ActProblem("keys must have exactly one key besides the modifiers, \(example)")) }
        return .success(KeyCombo(modifiers: modifiers, key: key))
    }
}

// MARK: - Typed text

public enum ActText {
    public static let limit = 2000
    /// One keyboard event carries at most this many UTF-16 units.
    public static let chunkUnits = 20

    public static let rule = "text may hold only printable characters, tabs and newlines, at most \(limit) characters"

    /// Line endings become "\n"; anything that is not printable, a tab or a newline is refused, and so are the
    /// invisible direction marks that would make the card show the text in another order than it is typed.
    public static func validate(_ raw: String) -> Result<String, ActProblem> {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard !text.isEmpty else { return .failure(ActProblem("text must not be empty")) }
        guard text.count <= limit else {
            return .failure(ActProblem("text is \(text.count) characters long; at most \(limit) can be typed in one call"))
        }
        for scalar in text.unicodeScalars where !isTypable(scalar) {
            return .failure(ActProblem("\(rule) (found U+\(String(scalar.value, radix: 16, uppercase: true)))"))
        }
        return .success(text)
    }

    static func isTypable(_ s: Unicode.Scalar) -> Bool {
        if s == "\n" || s == "\t" { return true }
        switch s.properties.generalCategory {
        case .control, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: return false
        // Joiners belong to emoji and to some scripts; every other format character is invisible.
        case .format: return s.value == 0x200C || s.value == 0x200D
        default: return true
        }
    }

    public enum Chunk: Equatable, Sendable {
        case text(String)
        /// A newline is typed as the Return key.
        case returnKey
        case tab
    }

    /// The text as the keyboard events it becomes. Tab and Return are chunks of their own: they can move the
    /// focus, so the checks that run between chunks see where the next characters would go.
    public static func chunks(_ text: String) -> [Chunk] {
        var out: [Chunk] = []
        var run = ""
        var units = 0
        func flush() {
            if !run.isEmpty { out.append(.text(run)) }
            run = ""
            units = 0
        }
        for ch in text {
            if ch == "\n" || ch == "\t" {
                flush()
                out.append(ch == "\n" ? .returnKey : .tab)
                continue
            }
            let n = ch.utf16.count
            if units + n > chunkUnits { flush() }
            run.append(ch)
            units += n
        }
        flush()
        return out
    }
}

// MARK: - One call

/// One validated act call.
public struct ActCall: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        /// The number of an element reference ("e12" -> 12).
        case pressElement(element: Int)
        /// Window points from the window's top-left corner.
        case clickAt(x: Double, y: Double, button: ActButton, count: Int)
        case typeText(String)
        case pressKeys(KeyCombo)
        /// Lines; positive is down / right.
        case scroll(dx: Int, dy: Int)
        case focusWindow
        case openApp(ActAppRef)
    }

    /// The window number; nil only for `open_app`.
    public var window: UInt32?
    public var body: Body

    public init(window: UInt32?, body: Body) {
        self.window = window
        self.body = body
    }

    public var kind: ActKind {
        switch body {
        case .pressElement: return .pressElement
        case .clickAt: return .clickAt
        case .typeText: return .typeText
        case .pressKeys: return .pressKeys
        case .scroll: return .scroll
        case .focusWindow: return .focusWindow
        case .openApp: return .openApp
        }
    }

    public static let scrollCap = 50
    static let maxCoordinate = 100_000.0

    public static func elementId(_ n: Int) -> String { "e\(n)" }

    /// "e12" -> 12. Anything else is not an element reference.
    public static func parseElementId(_ text: String) -> Int? {
        guard text.hasPrefix("e"), text.count <= 10 else { return nil }
        let digits = text.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n > 0 else { return nil }
        return n
    }

    static let argumentNames: [ActKind: Set<String>] = [
        .pressElement: ["window", "element"], .clickAt: ["window", "x", "y", "button", "count"],
        .typeText: ["window", "text"], .pressKeys: ["window", "keys"], .scroll: ["window", "dx", "dy"],
        .focusWindow: ["window"], .openApp: ["bundle_id", "name"],
    ]

    /// The tool's arguments -> a call. Used by the helper for what the agent sent and again by the app for
    /// what the helper sent: the app trusts neither.
    public static func parse(kind: ActKind, arguments args: JSONValue) -> Result<ActCall, ActProblem> {
        let tool = kind.rawValue
        guard let object = args.objectValue else { return .failure(ActProblem("arguments must be an object")) }
        let known = argumentNames[kind] ?? []
        if let extra = object.entries.first(where: { !known.contains($0.key) }) {
            return .failure(ActProblem("\(tool) has no argument \"\(RequestLog.clip(String(extra.key.prefix(40))))\""))
        }
        func present(_ name: String) -> JSONValue? {
            guard let v = args[name], !v.isNull else { return nil }
            return v
        }
        func whole(_ name: String) -> Result<Int?, ActProblem> {
            guard let raw = present(name) else { return .success(nil) }
            guard let d = raw.doubleValue, d.isFinite, d.rounded() == d, abs(d) < 1e9 else {
                return .failure(ActProblem("\(name) must be a whole number"))
            }
            return .success(Int(d))
        }

        if kind == .openApp {
            switch (present("bundle_id"), present("name")) {
            case (let id?, nil):
                guard let s = id.stringValue, LookExclusions.isBundleId(s) else {
                    return .failure(ActProblem("bundle_id must be an app's bundle id, for example \"com.apple.Notes\""))
                }
                return .success(ActCall(window: nil, body: .openApp(.bundleId(s))))
            case (nil, let name?):
                guard let s = name.stringValue, ActAppRef.isAppName(s) else {
                    return .failure(ActProblem("name must be an app's name as it is shown in the Applications folder, for example \"Notes\""))
                }
                return .success(ActCall(window: nil, body: .openApp(.name(s))))
            default:
                return .failure(ActProblem("open_app needs exactly one of bundle_id and name"))
            }
        }

        guard let windowText = present("window")?.stringValue, let window = LookTarget.parseWindowId(windowText) else {
            return .failure(ActProblem("\(tool) needs window: a window id from list_windows"))
        }
        switch kind {
        case .pressElement:
            guard let text = present("element")?.stringValue, let n = parseElementId(text) else {
                return .failure(ActProblem("press_element needs element: a reference from read_window_text, for example \"e12\""))
            }
            return .success(ActCall(window: window, body: .pressElement(element: n)))
        case .clickAt:
            guard let x = present("x")?.doubleValue, let y = present("y")?.doubleValue, x.isFinite, y.isFinite,
                  (0...maxCoordinate).contains(x), (0...maxCoordinate).contains(y) else {
                return .failure(ActProblem("click_at needs x and y: a point inside the window, in points from its top-left corner"))
            }
            var button = ActButton.left
            if let raw = present("button") {
                guard let b = raw.stringValue.flatMap(ActButton.init(rawValue:)) else {
                    return .failure(ActProblem("button must be \"left\" or \"right\""))
                }
                button = b
            }
            var count = 1
            switch whole("count") {
            case .failure(let p): return .failure(p)
            case .success(let n?):
                guard n == 1 || n == 2 else { return .failure(ActProblem("count must be 1 or 2")) }
                count = n
            case .success(nil): break
            }
            return .success(ActCall(window: window, body: .clickAt(x: x, y: y, button: button, count: count)))
        case .typeText:
            guard let raw = present("text")?.stringValue else { return .failure(ActProblem("type_text needs text: the characters to type")) }
            switch ActText.validate(raw) {
            case .failure(let p): return .failure(p)
            case .success(let text): return .success(ActCall(window: window, body: .typeText(text)))
            }
        case .pressKeys:
            guard let raw = present("keys")?.stringValue else {
                return .failure(ActProblem("press_keys needs keys: a key combination, for example \"cmd+s\""))
            }
            switch KeyCombo.parse(raw) {
            case .failure(let p): return .failure(p)
            case .success(let combo): return .success(ActCall(window: window, body: .pressKeys(combo)))
            }
        case .scroll:
            var amounts = [0, 0]
            for (i, name) in ["dx", "dy"].enumerated() {
                switch whole(name) {
                case .failure(let p): return .failure(p)
                case .success(let n): amounts[i] = min(max(n ?? 0, -scrollCap), scrollCap)
                }
            }
            guard amounts != [0, 0] else { return .failure(ActProblem("scroll needs dx or dy: a number of lines that is not zero")) }
            return .success(ActCall(window: window, body: .scroll(dx: amounts[0], dy: amounts[1])))
        case .focusWindow:
            return .success(ActCall(window: window, body: .focusWindow))
        case .openApp:
            return .failure(ActProblem("open_app needs exactly one of bundle_id and name"))
        }
    }

    /// The arguments in their one canonical spelling; `parse` reads them back to the same call.
    public var arguments: JSONValue {
        var o = JSONObject()
        if let window { o["window"] = .string(LookTarget.windowId(window)) }
        switch body {
        case .pressElement(let n):
            o["element"] = .string(Self.elementId(n))
        case .clickAt(let x, let y, let button, let count):
            o["x"] = .double(x)
            o["y"] = .double(y)
            o["button"] = .string(button.rawValue)
            o["count"] = .int(count)
        case .typeText(let text):
            o["text"] = .string(text)
        case .pressKeys(let combo):
            o["keys"] = .string(combo.canonical)
        case .scroll(let dx, let dy):
            o["dx"] = .int(dx)
            o["dy"] = .int(dy)
        case .focusWindow:
            break
        case .openApp(.bundleId(let id)):
            o["bundle_id"] = .string(id)
        case .openApp(.name(let name)):
            o["name"] = .string(name)
        }
        return .object(o)
    }
}

// MARK: - Wire

/// Message from `agenthud-mcp` to the app: one JSON line on the app's socket, answered by one `LookReply` line
/// (text for what was done, or a refusal). `sessionId` is only a claim; the app identifies the caller itself.
public struct ActRequest: Equatable, Sendable {
    public static let version = 1

    public var requestId: String
    public var call: ActCall
    public var sessionId: String?
    public var deadline: Date

    public init(requestId: String, call: ActCall, sessionId: String?, deadline: Date) {
        self.requestId = requestId
        self.call = call
        self.sessionId = sessionId
        self.deadline = deadline
    }

    public func encode() -> String {
        var o = JSONObject()
        o["v"] = .int(Self.version)
        o["act"] = .string(call.kind.rawValue)
        o["request_id"] = .string(requestId)
        o["args"] = call.arguments
        if let s = sessionId { o["session_id"] = .string(s) }
        o["deadline"] = .double(deadline.timeIntervalSince1970.rounded())
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> ActRequest? {
        guard let v = try? JSONValue.parse(line),
              let kind = v["act"]?.stringValue.flatMap(ActKind.init(rawValue:)),
              let rid = v["request_id"]?.stringValue, !rid.isEmpty, rid.count <= 200,
              let deadline = v["deadline"]?.doubleValue,
              let args = v["args"],
              case .success(let call) = ActCall.parse(kind: kind, arguments: args) else { return nil }
        let session = v["session_id"]?.stringValue.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        return ActRequest(requestId: rid, call: call, sessionId: session, deadline: Date(timeIntervalSince1970: deadline))
    }
}

/// The helper's side of one act call. Like a look: never throws, never waits past the deadline, and every
/// failure is a `refused` outcome with a plain sentence.
public enum ActClient {
    public static func perform(_ request: ActRequest, socketPath: String,
                               connectTimeoutMs: Int32 = LookTiming.connectTimeoutMs,
                               onConnected: (Int32) -> Void = { _ in }) -> LookReply.Outcome {
        let outcome = LookClient.exchange(line: request.encode(), requestId: request.requestId, deadline: request.deadline,
                                          socketPath: socketPath, connectTimeoutMs: connectTimeoutMs,
                                          maxReplyBytes: 1 << 20, onConnected: onConnected)
        // An act is answered with a sentence; a picture is not an answer to it.
        if case .image = outcome { return .refused(LookClient.unreadable) }
        return outcome
    }
}
