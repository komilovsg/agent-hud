import Foundation

/// Internal event shared by all agents. An adapter translates its agent's events into it.
public struct AgentEvent: Equatable, Sendable {
    public enum Body: Equatable, Sendable {
        case sessionStarted(source: String?, model: String?)
        case promptSubmitted(String)
        case toolStarted(toolName: String, input: JSONValue, toolUseId: String?)
        /// `backgroundId` - id of the background task from the tool response (the whole response is not stored).
        case toolFinished(toolName: String, input: JSONValue, toolUseId: String?, durationMs: Int?, failed: Bool, backgroundId: String? = nil)
        /// `suggestions` - "always allow" rules offered by the agent itself (`permission_suggestions`).
        case permissionRequested(requestId: String, toolName: String, input: JSONValue, deadline: Date, suggestions: [JSONValue])
        /// The agent asks the user (`AskUserQuestion`); `rawInput` is the tool input as is, it is echoed back with the answers.
        case questionAsked(requestId: String, questions: [Question], rawInput: JSONValue, deadline: Date)
        case subagentStarted(agentId: String, agentType: String?)
        case subagentStopped(agentId: String)
        case stopped(lastMessage: String?, failed: Bool)
        case interrupted
        /// The app's own service session (not a user conversation) - remove it and stop showing it.
        case internalSession
        case sessionEnded(reason: String?)
        case notification(type: String?, message: String?)
    }

    public var kind: AgentKind
    public var sessionId: String
    public var cwd: String?
    public var transcriptPath: String?
    public var agentId: String?      // the event came from inside a subagent
    public var host: HostInfo?
    public var time: Date
    public var body: Body
    /// Links to merge/pull requests from the command and the tool output (the output itself is not stored).
    public var refs: [String] = []

    public init(kind: AgentKind, sessionId: String, cwd: String? = nil, transcriptPath: String? = nil,
                agentId: String? = nil, host: HostInfo? = nil, time: Date, body: Body) {
        self.kind = kind
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.agentId = agentId
        self.host = host
        self.time = time
        self.body = body
    }

    public var sessionKey: String { "\(kind.rawValue):\(sessionId)" }
}

/// Adapter for a specific agent. The core and the UI only know this interface.
public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }

    /// Whether this event needs to be sent to the app at all (otherwise the hook exits silently).
    func shouldForward(mode: HookMode, payload: JSONValue) -> Bool

    /// Hook event -> internal events.
    func events(from message: HookMessage, now: Date) -> [AgentEvent]

    /// User decision -> hook stdout. `nil` - empty output (the agent will ask by itself).
    func hookOutput(for decision: Decision, mode: HookMode, payload: JSONValue) -> String?

    /// Short gist of a tool call for the steps feed.
    func summarize(toolName: String, input: JSONValue, cwd: String?) -> String
}

public enum Adapters {
    public static func adapter(for kind: AgentKind) -> AgentAdapter {
        switch kind {
        case .claude: return ClaudeCodeAdapter()
        }
    }
}

/// Fingerprint of a tool input: matches a permission request with the following PostToolUse.
public func fingerprint(toolName: String, input: JSONValue) -> String {
    "\(toolName)|\(input.compact())"
}
