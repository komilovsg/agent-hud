import Foundation

/// Which agent sent the event. A new agent = a new case + an adapter.
public enum AgentKind: String, Sendable, CaseIterable {
    case claude

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        }
    }

    /// File where this agent's hooks are installed.
    public var hooksFile: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appendingPathComponent(".claude/settings.json")
        }
    }
}

public enum AgentState: String, Sendable {
    case starting, working, waitingPermission, expired, idle, done, error, ended
    /// Held by the user (see `Hold`): derived in `AgentSession.state`, never stored in `baseState`.
    case paused, stopped

    public var needsUser: Bool { self == .waitingPermission }
}

/// Where the session runs - the labels and the "Open" button depend on it.
public enum HostPlace: String, Sendable {
    case terminal     // terminal (including the VS Code integrated terminal)
    case desktopApp   // Claude app
    case editor       // Claude Code extension in VS Code
    case hud          // a process started by Agent HUD itself
}

/// Where the agent is running: needed for the "Open" button.
public struct HostInfo: Equatable, Sendable {
    public var termProgram: String?
    public var tty: String?            // "/dev/ttys003"
    public var agentPid: Int32?
    public var herdrPaneId: String?
    public var herdrSocket: String?
    public var processChain: [String]  // process names from the agent upwards
    public var appBundleId: String?    // GUI app the session runs inside
    public var appName: String?
    public var hostSessionId: String?  // session id in the app (Claude: local_...)
    public var entrypoint: String?     // CLAUDE_CODE_ENTRYPOINT: cli, claude-desktop, claude-vscode…

    public static let claudeDesktop = "com.anthropic.claudefordesktop"
    public static let desktopApps: Set<String> = [claudeDesktop]
    public static let vscode = "com.microsoft.VSCode"
    public static let vscodeInsiders = "com.microsoft.VSCodeInsiders"
    /// Cursor is a VS Code build: the extension is the same, the bundle and the link scheme differ.
    public static let cursor = "com.todesktop.230313mzl4w4u92"
    public static let editorApps: Set<String> = [vscode, vscodeInsiders, cursor]
    public static let vscodeEntrypoint = "claude-vscode"
    /// This app: the host of sessions it starts itself.
    public static let agentHud = "io.github.komilovsg.agenthud"
    public static let agentHudName = "Agent HUD"

    /// Host of a session started by this app.
    public static var ownedByHud: HostInfo { HostInfo(appBundleId: agentHud, appName: agentHudName) }

    public init(termProgram: String? = nil, tty: String? = nil, agentPid: Int32? = nil,
                herdrPaneId: String? = nil, herdrSocket: String? = nil, processChain: [String] = [],
                appBundleId: String? = nil, appName: String? = nil, hostSessionId: String? = nil,
                entrypoint: String? = nil) {
        self.termProgram = termProgram
        self.tty = tty
        self.agentPid = agentPid
        self.herdrPaneId = herdrPaneId
        self.herdrSocket = herdrSocket
        self.processChain = processChain
        self.appBundleId = appBundleId
        self.appName = appName
        self.hostSessionId = hostSessionId
        self.entrypoint = entrypoint
    }

    public var isEmpty: Bool { tty == nil && agentPid == nil && herdrPaneId == nil && termProgram == nil && appBundleId == nil && entrypoint == nil }

    /// The session runs in the Claude desktop app, not in a terminal.
    public var isDesktopApp: Bool { tty == nil && appBundleId.map(Self.desktopApps.contains) == true }

    /// The session runs in the Claude Code extension for VS Code (chat panel, not a terminal).
    public var isEditor: Bool {
        entrypoint == Self.vscodeEntrypoint || (tty == nil && appBundleId.map(Self.editorApps.contains) == true)
    }

    /// Terminal inside VS Code: `claude` runs in the editor's integrated terminal.
    public var isEditorTerminal: Bool { !isEditor && termProgram == "vscode" }

    /// The session's process was started by Agent HUD (no editor or terminal behind it).
    public var isHud: Bool { appBundleId == Self.agentHud }

    public var place: HostPlace {
        if isHud { return .hud }
        if isEditor { return .editor }
        if isDesktopApp { return .desktopApp }
        return .terminal
    }

    /// Editor name for labels and buttons.
    public var editorName: String {
        switch appBundleId {
        case Self.vscode, nil: return "VS Code"
        case Self.vscodeInsiders: return "VS Code Insiders"
        case Self.cursor: return "Cursor"
        default: return appName ?? "VS Code"
        }
    }

    /// Human-readable host name: "Terminal", "herdr", "Claude app", "VS Code".
    public var label: String {
        if isHud { return Self.agentHudName }
        if isEditor { return editorName }
        if isEditorTerminal { return "terminal \(editorName)" }
        if isDesktopApp {
            switch appBundleId {
            case Self.claudeDesktop: return "Claude app"
            default: return appName ?? "app"
            }
        }
        if herdrPaneId != nil { return "herdr" }
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app": return "iTerm"
        case let p?: return p
        case nil: return "Terminal"
        }
    }

    public func toJSON() -> JSONValue {
        var o = JSONObject()
        if let v = termProgram { o["term_program"] = .string(v) }
        if let v = tty { o["tty"] = .string(v) }
        if let v = agentPid { o["agent_pid"] = .int(Int(v)) }
        if let v = herdrPaneId { o["herdr_pane_id"] = .string(v) }
        if let v = herdrSocket { o["herdr_socket"] = .string(v) }
        o["process_chain"] = .array(processChain.map { .string($0) })
        if let v = appBundleId { o["app_bundle_id"] = .string(v) }
        if let v = appName { o["app_name"] = .string(v) }
        if let v = hostSessionId { o["host_session_id"] = .string(v) }
        if let v = entrypoint { o["entrypoint"] = .string(v) }
        return .object(o)
    }

    public init(json: JSONValue?) {
        self.init(
            termProgram: json?["term_program"]?.stringValue,
            tty: json?["tty"]?.stringValue,
            agentPid: json?["agent_pid"]?.intValue.map { Int32($0) },
            herdrPaneId: json?["herdr_pane_id"]?.stringValue,
            herdrSocket: json?["herdr_socket"]?.stringValue,
            processChain: json?["process_chain"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            appBundleId: json?["app_bundle_id"]?.stringValue,
            appName: json?["app_name"]?.stringValue,
            hostSessionId: json?["host_session_id"]?.stringValue,
            entrypoint: json?["entrypoint"]?.stringValue
        )
    }
}

public enum StepStatus: String, Sendable { case running, ok, failed }

public struct Step: Identifiable, Equatable, Sendable {
    public let id: String
    public var toolName: String
    public var summary: String
    public var startedAt: Date
    public var durationMs: Int?
    public var status: StepStatus
    public var agentId: String?      // a step inside a subagent
    public var isSubagent: Bool      // the step itself is a subagent launch
    var inputFingerprint: String     // to match PostToolUse without tool_use_id

    public init(id: String, toolName: String, summary: String, startedAt: Date, durationMs: Int? = nil,
                status: StepStatus = .running, agentId: String? = nil, isSubagent: Bool = false,
                inputFingerprint: String = "") {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.status = status
        self.agentId = agentId
        self.isSubagent = isSubagent
        self.inputFingerprint = inputFingerprint
    }
}

/// A background command or background subagent that is still running.
public struct BackgroundTask: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case shell, agent }

    public let id: String
    public var kind: Kind
    public var title: String
    public var startedAt: Date
    public var agentId: String?

    /// A background task older than this is considered stuck.
    public static let hungAfter: TimeInterval = 3600
    public static let maxPerSession = 50

    public init(id: String, kind: Kind, title: String, startedAt: Date, agentId: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.startedAt = startedAt
        self.agentId = agentId
    }

    public func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(startedAt)) }
    public func isHung(at now: Date) -> Bool { age(at: now) >= Self.hungAfter }
}

public enum PendingKind: Equatable, Sendable {
    case permission(toolName: String, toolInput: JSONValue)
    /// A multiple-choice question from the agent; `rawInput` is the tool input as is.
    case question([Question], rawInput: JSONValue)
    /// A plan waiting for approval; `text` is Markdown.
    case plan(text: String, rawInput: JSONValue)

    public var isQuestion: Bool { if case .question = self { return true } else { return false } }
    public var isPlan: Bool { if case .plan = self { return true } else { return false } }
}

public enum PendingStatus: String, Sendable {
    case open                 // waiting for the user
    case answered             // answered in the HUD
    case answeredElsewhere    // answered in the terminal
    case expired              // the hook timed out
}

public struct PendingRequest: Identifiable, Equatable, Sendable {
    public let id: String          // request_id
    public var kind: PendingKind
    public var createdAt: Date
    public var deadline: Date
    public var status: PendingStatus
    var inputFingerprint: String
    /// The agent's "always allow" suggestions (`permission_suggestions` in Claude Code) - as is.
    public var suggestions: [JSONValue] = []
    /// The request came from inside a subagent (`agent_id`); nil - the main agent.
    public var agentId: String? = nil
}

/// The user holds the session: its next tool calls wait in the PreToolUse hook until released.
/// A hold cannot interrupt text generation or a command that is already running.
public struct Hold: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case pause   // ends by itself at `until`
        case stop    // until the user resumes (bounded only by the hook's own timeout)
    }

    public var kind: Kind
    public var since: Date
    public var until: Date?   // pause only

    public init(kind: Kind, since: Date) {
        self.kind = kind
        self.since = since
        self.until = kind == .pause ? since.addingTimeInterval(HookTiming.pauseLimit) : nil
    }

    /// Seconds until a pause ends (rounded up, never negative); nil for a stop.
    public func remaining(at now: Date) -> Int? {
        until.map { max(0, Int($0.timeIntervalSince(now).rounded(.up))) }
    }

    public static let pendingNote = "Takes effect before the agent's next action"
    public static let limits = ["Cannot interrupt a command that is already running", "Quitting Agent HUD releases all holds"]
    public static let unsupportedHint = "Restart the session to enable (hooks were updated after it started)"

    /// "12:41" for the countdown over the icon.
    public static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "Paused · 12:41 left" / "Stopped · for 8 min".
    public func statusLine(at now: Date) -> String {
        if let left = remaining(at: now) { return "Paused · \(Self.countdown(left)) left" }
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "Stopped · just now" }
        if s < 3600 { return "Stopped · for \(s / 60) min" }
        return "Stopped · for \(s / 3600) h \(s % 3600 / 60) min"
    }
}

/// A tool call waiting in a `gate` hook while its session is held.
public struct HeldCall: Identifiable, Equatable, Sendable {
    public let id: String          // request_id of the hook connection
    public var summary: String
    public var since: Date
    public var agentId: String?    // the call comes from a subagent
    /// When the hook gives up by itself; the call is forgotten after it.
    public var deadline: Date

    public init(id: String, summary: String, since: Date, agentId: String? = nil, deadline: Date) {
        self.id = id
        self.summary = summary
        self.since = since
        self.agentId = agentId
        self.deadline = deadline
    }
}

/// The user's answer, shared by all agents. An adapter translates it into its agent's format.
public enum Decision: Equatable, Sendable {
    case allow
    /// Allow and apply rules/mode (`updatedPermissions` in Claude Code):
    /// "allow always".
    case allowWith([JSONValue])
    case deny(reason: String?)
    /// Answers to a question: question text -> the chosen labels joined with ", " and/or the user's own text.
    case answer([String: String])
    case passthrough               // "answer in the terminal" / no answer

    public var logLabel: String {
        switch self {
        case .allow: return "allowed"
        case .allowWith(let updates):
            return updates.contains { $0["type"]?.stringValue == "addRules" } ? "allowed always" : "allowed + mode"
        case .deny: return "denied"
        case .answer: return "answered"
        case .passthrough: return "to agent"
        }
    }

    public var isAllow: Bool {
        switch self {
        case .allow, .allowWith: return true
        default: return false
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String              // "<kind>:<session_id>"
    public let kind: AgentKind
    public let sessionId: String
    public var cwd: String
    public var title: String
    public var host: HostInfo
    public var baseState: AgentState
    public var steps: [Step]
    public var pending: [PendingRequest]
    public var startedAt: Date
    public var lastEventAt: Date
    public var finishedAt: Date?
    public var lastMessage: String?
    public var model: String?
    public var transcriptPath: String?
    public var hidden: Bool
    /// Whether to show the session. A VS Code session without a task appears only after the first prompt.
    public var revealed = true
    /// When the current (or last) turn started - for the summary and the agent map.
    public var turnStartedAt: Date?
    /// Background commands and subagents that have not finished yet.
    public var backgroundTasks: [BackgroundTask] = []
    /// Pause / Stop set by the user; nil - the session runs freely.
    public var hold: Hold?
    /// Tool calls waiting in their hooks right now (the main agent's and subagents').
    public var heldCalls: [HeldCall] = []
    /// The session has sent a `gate` message, so its tool calls can be held. A session started before
    /// the hooks were updated still sends plain events and cannot be held.
    public var supportsHold = false

    public static let maxSteps = 200

    public init(kind: AgentKind, sessionId: String, cwd: String, now: Date) {
        self.id = "\(kind.rawValue):\(sessionId)"
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.title = ""
        self.host = HostInfo()
        self.baseState = .starting
        self.steps = []
        self.pending = []
        self.startedAt = now
        self.lastEventAt = now
        self.lastMessage = nil
        self.hidden = false
    }

    /// Project name: the session folder, and for faceless names ("front", "app") - together with the parent.
    public var projectName: String { ProjectNames.displayName(cwd: cwd) }

    /// The first open request - that is the one we show.
    public var activePending: PendingRequest? {
        pending.first(where: { $0.status == .open })
    }
    public var expiredPending: PendingRequest? { pending.first(where: { $0.status == .expired }) }

    public var state: AgentState {
        if activePending != nil { return .waitingPermission }
        if expiredPending != nil { return .expired }
        if let h = hold, baseState != .ended { return h.kind == .pause ? .paused : .stopped }
        return baseState
    }

    /// What a held session is waiting at: one line per held call (at most `max`, then "and N more"),
    /// or a note that the hold has not caught anything yet.
    public func holdWaitingLines(max: Int = 3) -> [String] {
        guard !heldCalls.isEmpty else { return [Hold.pendingNote] }
        var lines = heldCalls.prefix(max).map { "Holding: \($0.summary)" }
        if heldCalls.count > max { lines.append("and \(heldCalls.count - max) more") }
        return lines
    }

    public var currentStep: Step? { steps.last(where: { $0.status == .running }) }

    /// Steps of the current turn (after the last prompt).
    public var turnSteps: [Step] {
        guard let t = turnStartedAt else { return steps }
        return steps.filter { $0.startedAt >= t }
    }

    /// Turn result for the summary: how many times which tool, which files were edited, how long it took.
    public func turnStats(until end: Date? = nil) -> TurnStats {
        var tools: [String: Int] = [:]
        var files: [String] = []
        for st in turnSteps where !st.isSubagent {
            tools[st.toolName, default: 0] += 1
            if ["Edit", "MultiEdit", "Write", "NotebookEdit"].contains(st.toolName),
               let space = st.summary.firstIndex(of: " ") {
                let f = String(st.summary[st.summary.index(after: space)...])
                if !f.isEmpty, !files.contains(f) { files.append(f) }
            }
        }
        let subagents = turnSteps.filter(\.isSubagent).count
        let duration = turnStartedAt.map { Int(max(0, (end ?? finishedAt ?? lastEventAt).timeIntervalSince($0))) }
        return TurnStats(tools: tools, files: files, subagents: subagents, durationSec: duration)
    }

    public func hungCount(at now: Date) -> Int { backgroundTasks.filter { $0.isHung(at: now) }.count }

    /// The oldest background task.
    public func oldestBackground(at now: Date) -> BackgroundTask? {
        backgroundTasks.max { $0.age(at: now) < $1.age(at: now) }
    }

    /// Stable "seed" of the character's appearance.
    public var avatarSeed: UInt64 { stableHash(id) }
}

public struct TurnStats: Equatable, Sendable {
    public var tools: [String: Int]
    public var files: [String]
    public var subagents: Int
    public var durationSec: Int?

    public init(tools: [String: Int] = [:], files: [String] = [], subagents: Int = 0, durationSec: Int? = nil) {
        self.tools = tools
        self.files = files
        self.subagents = subagents
        self.durationSec = durationSec
    }

    public var edits: Int { ["Edit", "MultiEdit", "Write", "NotebookEdit"].reduce(0) { $0 + (tools[$1] ?? 0) } }
    public var commands: Int { ["Bash"].reduce(0) { $0 + (tools[$1] ?? 0) } }
}

/// FNV-1a: a hash stable between launches (`Hasher` has a random salt).
public func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}
