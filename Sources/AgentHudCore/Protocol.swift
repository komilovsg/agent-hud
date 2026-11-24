import Foundation

/// Hook invocation mode.
public enum HookMode: String, Sendable {
    case event        // asynchronous event, no reply needed
    case permission   // permission request, waiting for a decision
    case gate         // a tool call is about to start: the app may hold it (Pause / Stop), then lets it proceed
    case question     // the agent asks a multiple-choice question, waiting for the answers

    public var isSync: Bool { self != .event }
}

/// Message from `agenthud-hook` to the app. One JSON line on the socket.
public struct HookMessage: Equatable, Sendable {
    public static let version = 1

    public var agent: AgentKind
    public var mode: HookMode
    public var requestId: String
    public var deadline: Date?
    public var host: HostInfo
    public var payload: JSONValue   // the agent's hook input as is

    public init(agent: AgentKind, mode: HookMode, requestId: String, deadline: Date?, host: HostInfo, payload: JSONValue) {
        self.agent = agent
        self.mode = mode
        self.requestId = requestId
        self.deadline = deadline
        self.host = host
        self.payload = payload
    }

    public func encode() -> String {
        var o = JSONObject()
        o["v"] = .int(Self.version)
        o["agent"] = .string(agent.rawValue)
        o["mode"] = .string(mode.rawValue)
        o["request_id"] = .string(requestId)
        if let d = deadline { o["deadline"] = .double(d.timeIntervalSince1970.rounded()) }
        o["host"] = host.toJSON()
        o["payload"] = payload
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> HookMessage? {
        guard let v = try? JSONValue.parse(line),
              let agent = v["agent"]?.stringValue.flatMap(AgentKind.init(rawValue:)),
              let mode = v["mode"]?.stringValue.flatMap(HookMode.init(rawValue:)),
              let rid = v["request_id"]?.stringValue,
              let payload = v["payload"], payload.objectValue != nil
        else { return nil }
        return HookMessage(
            agent: agent, mode: mode, requestId: rid,
            deadline: v["deadline"]?.doubleValue.map { Date(timeIntervalSince1970: $0) },
            host: HostInfo(json: v["host"]), payload: payload
        )
    }
}

/// The app's reply to the hook.
public struct HookReply: Equatable, Sendable {
    public var requestId: String
    public var decision: Decision

    public init(requestId: String, decision: Decision) {
        self.requestId = requestId
        self.decision = decision
    }

    public func encode() -> String {
        var o = JSONObject()
        o["request_id"] = .string(requestId)
        switch decision {
        case .allow: o["decision"] = "allow"
        case .allowWith(let updates):
            o["decision"] = "allow"
            o["permissions"] = .array(updates)
        case .deny(let reason):
            o["decision"] = "deny"
            if let r = reason { o["reason"] = .string(r) }
        case .answer(let answers):
            o["decision"] = "answer"
            var a = JSONObject()
            for k in answers.keys.sorted() { a[k] = .string(answers[k]!) }
            o["answers"] = .object(a)
        case .passthrough: o["decision"] = "passthrough"
        }
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> HookReply? {
        guard let v = try? JSONValue.parse(line),
              let rid = v["request_id"]?.stringValue,
              let d = v["decision"]?.stringValue else { return nil }
        switch d {
        case "allow":
            if let updates = v["permissions"]?.arrayValue, !updates.isEmpty {
                return HookReply(requestId: rid, decision: .allowWith(updates))
            }
            return HookReply(requestId: rid, decision: .allow)
        case "deny": return HookReply(requestId: rid, decision: .deny(reason: v["reason"]?.stringValue))
        case "answer":
            // An answer line without answers is not an answer: the hook steps aside.
            guard let entries = v["answers"]?.objectValue?.entries, !entries.isEmpty else { return nil }
            var answers: [String: String] = [:]
            for e in entries {
                guard let s = e.value.stringValue else { return nil }
                answers[e.key] = s
            }
            return HookReply(requestId: rid, decision: .answer(answers))
        case "passthrough": return HookReply(requestId: rid, decision: .passthrough)
        default: return nil
        }
    }
}

/// Interim line from the app to a `gate` hook: "this call is being held". It is not a reply - the hook keeps
/// waiting for a `HookReply`. `until` is when a pause ends by itself, so that the hook can leave on time
/// even if the app stops responding; a stop has no `until`. A new notice replaces the previous one.
public struct HoldNotice: Equatable, Sendable {
    public var requestId: String
    public var until: Date?

    public init(requestId: String, until: Date?) {
        self.requestId = requestId
        self.until = until
    }

    public func encode() -> String {
        var o = JSONObject()
        o["request_id"] = .string(requestId)
        o["held"] = true
        if let u = until { o["until"] = .double(u.timeIntervalSince1970.rounded()) }
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> HoldNotice? {
        guard let v = try? JSONValue.parse(line),
              let rid = v["request_id"]?.stringValue,
              v["held"]?.boolValue == true, v["decision"] == nil else { return nil }
        return HoldNotice(requestId: rid, until: v["until"]?.doubleValue.map { Date(timeIntervalSince1970: $0) })
    }
}

/// Where the app's socket lives.
public enum AgentHUDPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["AGENTHUD_SUPPORT_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentHUD", isDirectory: true)
    }

    public static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"], !override.isEmpty {
            return override
        }
        return supportDirectory.appendingPathComponent("hud.sock").path
    }

    public static var decisionsLog: URL { supportDirectory.appendingPathComponent("decisions.log") }

    public static var redFlagsFile: URL { supportDirectory.appendingPathComponent("red-flags.json") }

    public static var hookSymlink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agenthud-hook")
    }

    /// Stable path of the screen tools server for agents' configs; points into the installed app.
    public static var mcpSymlink: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/agenthud-mcp")
    }

    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
}

/// Time margin: the hook releases the wait earlier than its own `timeout`,
/// so that the agent does not kill it and asks the user in the terminal.
public enum HookTiming {
    public static let safetyMargin: TimeInterval = 5
    /// Time to answer a permission request, a plan or a question (the user can change it in the settings).
    public static let defaultTimeout = 600
    public static let connectTimeoutMs: Int32 = 200

    /// Timeout of the PreToolUse (`gate`) hook entry: the longest a Stop can hold a tool call.
    public static let gateTimeout = 86400
    /// A pause ends by itself after this long.
    public static let pauseLimit: TimeInterval = 900
    /// The app must say "held" or "proceed" within this time, otherwise the gate hook lets the call through.
    public static let gateAnswerTimeout: TimeInterval = 2

    public static func deadline(now: Date, hookTimeout: Int) -> Date {
        now.addingTimeInterval(max(1, TimeInterval(hookTimeout) - safetyMargin))
    }

    /// How long a gate hook keeps waiting after a line from the app (or after sending its message, `notice == nil`):
    /// never past its own deadline; without a notice only the short answer window; during a pause until the pause ends
    /// plus the margin (the app normally replies first).
    public static func gateWaitLimit(started: Date, deadline: Date, notice: HoldNotice?) -> Date {
        guard let notice else { return min(deadline, started.addingTimeInterval(gateAnswerTimeout)) }
        guard let until = notice.until else { return deadline }
        return min(deadline, until.addingTimeInterval(safetyMargin))
    }
}
