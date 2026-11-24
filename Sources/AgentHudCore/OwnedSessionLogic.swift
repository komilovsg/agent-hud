import Foundation

/// Life cycle of a session whose CLI process this app started. Pure: the process layer reports what happened,
/// this struct answers what is allowed next.
public struct OwnedSessionLogic: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case starting          // spawned, the CLI has not reported the session yet
        case idle              // waiting for the next message
        case running           // a turn is in progress
        case interrupting      // an interrupt was sent, the turn has not ended yet
        case handingOver       // stdin is closed, waiting for the process to leave
        case exited(Int32)     // the process is gone (exit code)
    }

    public enum Event: Equatable, Sendable {
        case spawned, initReceived, userSent, turnFinished, interruptRequested, stdinClosed
        case processExited(Int32)
    }

    public private(set) var state: State = .starting
    /// The CLI printed its `init` line at least once: the session exists and can be resumed.
    public private(set) var initialized = false

    public init() {}

    /// Applies an event. Returns false when the event is not allowed in the current state (nothing changes).
    @discardableResult
    public mutating func handle(_ event: Event) -> Bool {
        if case .exited = state { return false }
        switch event {
        case .spawned:
            return state == .starting
        case .initReceived:
            initialized = true
            if state == .starting { state = .idle }
            return true
        case .userSent:
            // The first message may be written before the CLI reports the session: stdin is a pipe.
            guard state == .starting || state == .idle else { return false }
            state = .running
            return true
        case .turnFinished:
            guard state == .running || state == .interrupting else { return false }
            state = .idle
            return true
        case .interruptRequested:
            guard state == .running else { return false }
            state = .interrupting
            return true
        case .stdinClosed:
            guard state != .handingOver else { return false }
            state = .handingOver
            return true
        case .processExited(let code):
            state = .exited(code)
            return true
        }
    }

    public var isLive: Bool {
        if case .exited = state { return false }
        return true
    }

    public var canSend: Bool { state == .starting || state == .idle }
    public var canInterrupt: Bool { state == .running }
    /// Only between turns: closing stdin in the middle of a turn would cut the agent off.
    public var canHandOver: Bool { state == .idle }

    public func canResumeHere(sessionEnded: Bool) -> Bool {
        Self.canResumeHere(owned: state, sessionEnded: sessionEnded)
    }

    /// One owner per session. A session this app runs is never started a second time; one whose process
    /// this app saw exit may be continued; any other session only when the store shows it as ended.
    public static func canResumeHere(owned: State?, sessionEnded: Bool) -> Bool {
        switch owned {
        case nil: return sessionEnded
        case .exited: return true
        default: return false
        }
    }

    // MARK: - Command line

    /// The id goes to the CLI as an argument, so only a real UUID is accepted.
    public static func isValidSessionId(_ id: String) -> Bool { UUID(uuidString: id) != nil }

    /// A model is one of the short aliases or a full `claude-…` name made of letters, digits and `. _ - : [ ]`.
    /// Anything else is not passed on, so no other word can ride along as the value of the model flag.
    public static func isValidModel(_ model: String) -> Bool {
        guard ["sonnet", "opus", "haiku"].contains(model) || model.hasPrefix("claude-"), model.count <= 80 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:[]")
        return model.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// Arguments of the long-lived CLI process. Approval of tools stays with the person: the permission mode is
    /// always the default one and nothing here pre-approves a tool. Empty when `sessionId` is not a UUID.
    /// `screenTools`: path of the `agenthud-mcp` helper; when given, the session gets the screen tools server
    /// through `--mcp-config` (the tools still go through the usual approval and the consent card).
    public static func arguments(sessionId: String, resume: Bool, model: String?, screenTools: String? = nil) -> [String] {
        guard isValidSessionId(sessionId) else { return [] }
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-mode", "default"]
        args += [resume ? "--resume" : "--session-id", sessionId.lowercased()]
        if let model, isValidModel(model) { args += ["--model", model] }
        // Last: the flag takes a list of values, so nothing may follow it.
        if let helper = screenTools, let config = ScreenTools.configJSON(helperPath: helper) { args += ["--mcp-config", config] }
        return args
    }

    // MARK: - Finding the CLI

    /// Usual install locations, in the order they are tried.
    public static func executableCandidates(home: String) -> [String] {
        ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.local/bin/claude", "\(home)/.claude/local/claude"]
    }

    /// `override` (the `AGENTHUD_CLAUDE_BIN` variable) wins and is never replaced by a default:
    /// a wrong override means "not found".
    public static func findExecutable(override: String?, home: String, isExecutable: (String) -> Bool) -> String? {
        if let o = override, !o.isEmpty { return isExecutable(o) ? o : nil }
        return executableCandidates(home: home).first(where: isExecutable)
    }

    // MARK: - Recent projects

    /// Folders for the "New session" list: most recently active first, no duplicates, at most `limit`.
    public static func recentFolders(_ seen: [(cwd: String, at: Date)], limit: Int = 8) -> [String] {
        var out: [String] = []
        for s in seen.sorted(by: { $0.at > $1.at }) where !s.cwd.isEmpty && !out.contains(s.cwd) {
            out.append(s.cwd)
            if out.count == limit { break }
        }
        return out
    }
}
