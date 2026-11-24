import Foundation

/// State of all sessions. A pure struct without side effects - easy to test.
public struct SessionStore: Sendable, Equatable {
    public private(set) var sessions: [String: AgentSession] = [:]
    public private(set) var order: [String] = []
    /// Service sessions of apps: their events are ignored.
    public private(set) var ignored: [String] = []
    /// Sessions that stay listed after they end (their process was started by this app, so the card
    /// still has something to show and to offer).
    public private(set) var kept: Set<String> = []

    /// How long to keep a finished (`SessionEnd`) session before removal - for the animation.
    public static let endedLinger: TimeInterval = 2

    public init() {}

    public var visibleSessions: [AgentSession] {
        order.compactMap { sessions[$0] }.filter { !$0.hidden && $0.revealed }
    }

    /// Requests waiting for the user.
    public var openRequestCount: Int {
        sessions.values.reduce(0) { $0 + $1.pending.filter { $0.status == .open }.count }
    }

    public func session(_ key: String) -> AgentSession? { sessions[key] }

    public func session(forRequest requestId: String) -> AgentSession? {
        sessions.values.first { $0.pending.contains { $0.id == requestId } }
    }

    // MARK: - Events

    /// Apply an event. Returns the ids of requests that are no longer relevant
    /// (answered in the terminal) - the app will release their hooks.
    @discardableResult
    public mutating func apply(_ e: AgentEvent, adapter: AgentAdapter? = nil) -> [String] {
        let key = e.sessionKey
        if ignored.contains(key) {
            // Service session: synchronous requests are released at once.
            switch e.body {
            case .permissionRequested(let rid, _, _, _, _), .questionAsked(let rid, _, _, _): return [rid]
            default: return []
            }
        }
        if case .internalSession = e.body {
            let released = (sessions[key]?.pending.filter { $0.status == .open }.map(\.id) ?? [])
                + (sessions[key]?.heldCalls.map(\.id) ?? [])
            remove(key)
            ignored.append(key)
            if ignored.count > 500 { ignored.removeFirst(ignored.count - 500) }
            return released
        }
        var s = sessions[key] ?? AgentSession(kind: e.kind, sessionId: e.sessionId, cwd: e.cwd ?? "", now: e.time)
        if sessions[key] == nil {
            order.append(key)
            // A session without a task appears in the HUD only with the first activity (prompt, step, request):
            // VS Code opens a session for every open Claude panel.
            if case .sessionStarted = e.body, e.host?.isEditor == true { s.revealed = false }
        }
        let summarizer = adapter ?? Adapters.adapter(for: e.kind)

        if let cwd = e.cwd, !cwd.isEmpty, s.cwd.isEmpty || e.agentId == nil { s.cwd = cwd }
        if let t = e.transcriptPath { s.transcriptPath = t }
        if let h = e.host { s.host = Self.merge(s.host, h) }
        s.lastEventAt = e.time
        if s.baseState == .ended, !Self.isEnd(e.body) { s.baseState = .idle }
        // A hidden session comes back with a new task or when it needs you - not on every step:
        // otherwise in VS Code, where events flow constantly, "Hide" did not hold for longer than a second.
        if Self.unhides(e.body) { s.hidden = false }

        var released: [String] = []

        switch e.body {
        case .sessionStarted(_, let model):
            if let model { s.model = model }
            if s.baseState == .starting { s.baseState = .idle }

        case .promptSubmitted(let text):
            // The title is the first real task. Service insertions (<task-notification>, <command-name>...) are not a task.
            // The last prompt is not taken as the title: it is often a short answer to an agent question ("red").
            if s.title.isEmpty, !Self.isInjectedPrompt(text) { s.title = Self.makeTitle(text) }
            s.revealed = true
            s.baseState = .working
            s.lastMessage = nil
            s.finishedAt = nil
            s.turnStartedAt = e.time
            released += Self.resolveAll(&s)

        case .toolStarted(let tool, let input, let toolUseId):
            s.baseState = .working
            s.revealed = true
            let step = Step(
                id: toolUseId ?? UUID().uuidString, toolName: tool,
                summary: summarizer.summarize(toolName: tool, input: input, cwd: s.cwd),
                startedAt: e.time, agentId: e.agentId,
                inputFingerprint: fingerprint(toolName: tool, input: input))
            if !s.steps.contains(where: { $0.id == step.id }) { s.steps.append(step) }

        case .toolFinished(let tool, let input, let toolUseId, let durationMs, let failed, let backgroundId):
            if s.baseState != .ended { s.baseState = .working }
            let fp = fingerprint(toolName: tool, input: input)
            let idx = s.steps.lastIndex { st in
                if let id = toolUseId, st.id == id { return true }
                return st.status == .running && st.inputFingerprint == fp
            }
            if let i = idx {
                s.steps[i].status = failed ? .failed : .ok
                s.steps[i].durationMs = durationMs ?? Int(e.time.timeIntervalSince(s.steps[i].startedAt) * 1000)
            } else {
                s.steps.append(Step(
                    id: toolUseId ?? UUID().uuidString, toolName: tool,
                    summary: summarizer.summarize(toolName: tool, input: input, cwd: s.cwd),
                    startedAt: e.time, durationMs: durationMs, status: failed ? .failed : .ok,
                    agentId: e.agentId, inputFingerprint: fp))
            }
            released += Self.resolve(&s, toolName: tool, fingerprint: fp, command: Self.commandText(input))
            if !failed {
                if let kind = Self.backgroundKind(tool, input) {
                    // A task is registered from the tool response: PostToolUse comes right after the launch.
                    let id = backgroundId ?? toolUseId ?? UUID().uuidString
                    if !s.backgroundTasks.contains(where: { $0.id == id }) {
                        s.backgroundTasks.append(BackgroundTask(
                            id: id, kind: kind, title: summarizer.summarize(toolName: tool, input: input, cwd: s.cwd),
                            startedAt: e.time, agentId: kind == .agent ? backgroundId : nil))
                    }
                    if s.backgroundTasks.count > BackgroundTask.maxPerSession {
                        s.backgroundTasks.removeFirst(s.backgroundTasks.count - BackgroundTask.maxPerSession)
                    }
                } else if let target = Self.stopTarget(tool, input) {
                    s.backgroundTasks.removeAll { $0.id == target || $0.agentId == target }
                }
            }

        case .permissionRequested(let rid, let tool, let input, let deadline, let suggestions):
            s.baseState = .working
            s.revealed = true
            if !s.pending.contains(where: { $0.id == rid }) {
                // The agent asks the next thing - so its previous request has already been answered
                // (for example, "No" in VS Code: PostToolUse will not come then, and the request would hang until the end of the turn).
                released += Self.resolveSuperseded(&s, agentId: e.agentId)
                let kind: PendingKind = tool == ClaudeCodeAdapter.planTool
                    ? .plan(text: input["plan"]?.stringValue ?? "", rawInput: input)
                    : .permission(toolName: tool, toolInput: input)
                s.pending.append(PendingRequest(
                    id: rid, kind: kind, createdAt: e.time,
                    deadline: deadline, status: .open, inputFingerprint: fingerprint(toolName: tool, input: input),
                    suggestions: suggestions, agentId: e.agentId))
            }

        case .questionAsked(let rid, let qs, let raw, let deadline):
            // A hold is neither set nor ended here: a question asked by a held session is shown as usual, and its
            // tool call still waits in the `gate` hook until the hold is released.
            s.baseState = .working
            s.revealed = true
            if !s.pending.contains(where: { $0.id == rid }) {
                released += Self.resolveSuperseded(&s, agentId: e.agentId)
                s.pending.append(PendingRequest(
                    id: rid, kind: .question(qs, rawInput: raw), createdAt: e.time,
                    deadline: deadline, status: .open,
                    inputFingerprint: fingerprint(toolName: ClaudeCodeAdapter.questionTool, input: raw),
                    agentId: e.agentId))
            }

        case .subagentStarted(let aid, let type):
            let id = "subagent:\(aid)"
            if !s.steps.contains(where: { $0.id == id }) {
                s.steps.append(Step(id: id, toolName: "Subagent", summary: "Subagent: \(type ?? "general")",
                                    startedAt: e.time, isSubagent: true))
            }
            s.baseState = .working

        case .subagentStopped(let aid):
            if let i = s.steps.firstIndex(where: { $0.id == "subagent:\(aid)" }) {
                s.steps[i].status = .ok
                s.steps[i].durationMs = Int(e.time.timeIntervalSince(s.steps[i].startedAt) * 1000)
            }
            s.backgroundTasks.removeAll { $0.agentId == aid || $0.id == aid }
            // The subagent finished - nobody waits for its requests any more.
            let stale = s.pending.filter { $0.agentId == aid }
            s.pending.removeAll { $0.agentId == aid }
            released += stale.filter { $0.status == .open }.map(\.id)
            if s.activePending == nil, s.baseState == .waitingPermission { s.baseState = .working }

        case .stopped(let msg, let failed):
            s.baseState = failed ? .error : .done
            s.lastMessage = msg
            s.finishedAt = e.time
            for i in s.steps.indices where s.steps[i].status == .running && !s.steps[i].isSubagent {
                s.steps[i].status = .ok
            }
            released += Self.resolveAll(&s)

        case .interrupted:
            // The user interrupted the turn (Esc): the agent waits for a new task.
            s.baseState = .idle
            s.finishedAt = e.time
            for i in s.steps.indices where s.steps[i].status == .running { s.steps[i].status = .failed }
            released += Self.resolveAll(&s)

        case .sessionEnded:
            released += Self.resolveAll(&s)
            released += Self.releaseHold(&s)
            s.backgroundTasks.removeAll()
            s.baseState = .ended
            s.finishedAt = e.time

        case .internalSession:
            break

        case .notification(let type, _):
            // The agent waits in the terminal itself (for example, after "answer in the terminal", a question or ExitPlanMode).
            // Only in the middle of a turn: the notification arrives with a delay and after the end of a turn it would turn on a false "waiting".
            if (type == "permission_prompt" || type == "elicitation_dialog"), s.activePending == nil,
               s.baseState == .working || s.baseState == .starting {
                s.baseState = .waitingPermission
            }
        }

        if s.steps.count > AgentSession.maxSteps { s.steps.removeFirst(s.steps.count - AgentSession.maxSteps) }
        sessions[key] = s
        return released
    }

    // MARK: - Requests

    /// The user answered in the HUD.
    public mutating func markAnswered(_ requestId: String) {
        mutateSession(forRequest: requestId) { s in
            s.pending.removeAll { $0.id == requestId }
        }
    }

    // MARK: - Pause and Stop

    /// Hold the session: its next tool calls wait in their hooks. Calls that are already waiting stay held
    /// when the kind changes (pause <-> stop). Returns false for an unknown or ended session.
    @discardableResult
    public mutating func hold(sessionKey: String, kind: Hold.Kind, now: Date) -> Bool {
        guard var s = sessions[sessionKey], s.baseState != .ended else { return false }
        s.hold = Hold(kind: kind, since: now)
        sessions[sessionKey] = s
        return true
    }

    /// End the hold. Returns the ids of the waiting hooks to answer (each exactly once).
    public mutating func release(sessionKey: String) -> [String] {
        guard var s = sessions[sessionKey] else { return [] }
        let ids = Self.releaseHold(&s)
        sessions[sessionKey] = s
        return ids
    }

    /// End every hold (the app quits). Returns the ids of the waiting hooks to answer.
    public mutating func releaseAll() -> [String] {
        var ids: [String] = []
        for key in order { ids += release(sessionKey: key) }
        return ids
    }

    /// A `gate` hook reports a tool call that is about to start. Returns true when the hook must be answered
    /// right away (the session is not held, unknown or ignored); false - the call is now waiting for a release.
    public mutating func gateArrived(sessionKey: String, requestId: String, summary: String, agentId: String?,
                                     deadline: Date, now: Date) -> Bool {
        guard var s = sessions[sessionKey] else { return true }
        s.supportsHold = true
        defer { sessions[sessionKey] = s }
        guard s.hold != nil, s.baseState != .ended else { return true }
        if !s.heldCalls.contains(where: { $0.id == requestId }) {
            s.heldCalls.append(HeldCall(id: requestId, summary: summary, since: now, agentId: agentId, deadline: deadline))
        }
        return false
    }

    private static func releaseHold(_ s: inout AgentSession) -> [String] {
        let ids = s.heldCalls.map(\.id)
        s.hold = nil
        s.heldCalls.removeAll()
        return ids
    }

    /// The hook disconnected. Before the deadline - answered in the terminal, after - expired.
    public mutating func connectionClosed(_ requestId: String, now: Date) {
        // A held call whose hook has gone (the turn was interrupted, the hook timed out) is no longer waiting.
        for key in order where sessions[key]?.heldCalls.contains(where: { $0.id == requestId }) == true {
            sessions[key]?.heldCalls.removeAll { $0.id == requestId }
        }
        mutateSession(forRequest: requestId) { s in
            guard let i = s.pending.firstIndex(where: { $0.id == requestId }), s.pending[i].status == .open else { return }
            if now >= s.pending[i].deadline.addingTimeInterval(-2) {
                s.pending[i].status = .expired
            } else {
                s.pending.remove(at: i)
            }
        }
    }

    /// Once a second: expiring requests, ending pauses whose time is up and cleaning up finished sessions.
    /// Returns the ids of hooks that no longer need to wait: expired requests (their hooks have already left)
    /// and the calls released by a pause that ran out - the app answers the latter.
    @discardableResult
    public mutating func tick(now: Date, autoHideDoneAfter: TimeInterval?) -> [String] {
        var expired: [String] = []
        for key in order {
            guard var s = sessions[key] else { continue }
            for i in s.pending.indices where s.pending[i].status == .open && now > s.pending[i].deadline.addingTimeInterval(1) {
                s.pending[i].status = .expired
                expired.append(s.pending[i].id)
            }
            if let until = s.hold?.until, now >= until { expired += Self.releaseHold(&s) }
            // The hook leaves at its own deadline; drop the call even if the close notification was lost.
            s.heldCalls.removeAll { now > $0.deadline.addingTimeInterval(1) }
            if let limit = autoHideDoneAfter, s.state == .done, let f = s.finishedAt, now.timeIntervalSince(f) > limit {
                s.hidden = true
            }
            sessions[key] = s
            if s.baseState == .ended, s.activePending == nil, !kept.contains(key), let f = s.finishedAt,
               now.timeIntervalSince(f) > Self.endedLinger {
                remove(key)
            }
        }
        return expired
    }

    public mutating func hide(_ key: String) {
        guard var s = sessions[key] else { return }
        s.hidden = true
        s.pending.removeAll { $0.status != .open }
        if s.baseState == .waitingPermission { s.baseState = .idle }
        sessions[key] = s
    }

    /// Bring back a hidden session (the agent map shows hidden ones too).
    public mutating func unhide(_ key: String) {
        guard var s = sessions[key] else { return }
        s.hidden = false
        sessions[key] = s
    }

    /// Remove an expired popup without hiding the session.
    public mutating func dismissExpired(_ key: String) {
        guard var s = sessions[key] else { return }
        s.pending.removeAll { $0.status == .expired }
        if s.baseState == .waitingPermission { s.baseState = .idle }
        sessions[key] = s
    }

    public mutating func remove(_ key: String) {
        sessions[key] = nil
        order.removeAll { $0 == key }
        kept.remove(key)
    }

    // MARK: - Sessions started by the app

    /// Enter a session before its first event arrives, or take over a listed one (an ended session that is being
    /// continued, a session handed to an editor). The host is replaced as a whole and an ended session becomes idle.
    /// Later events with the same session id merge into this entry. Returns the session key.
    @discardableResult
    public mutating func register(kind: AgentKind = .claude, sessionId: String, cwd: String, host: HostInfo, now: Date) -> String {
        let key = "\(kind.rawValue):\(sessionId)"
        ignored.removeAll { $0 == key }
        var s = sessions[key] ?? AgentSession(kind: kind, sessionId: sessionId, cwd: cwd, now: now)
        if sessions[key] == nil { order.append(key) }
        if s.cwd.isEmpty { s.cwd = cwd }
        s.host = host
        s.lastEventAt = now
        s.finishedAt = nil
        s.hidden = false
        s.revealed = true
        if s.baseState == .ended { s.baseState = .idle }
        sessions[key] = s
        return key
    }

    /// Keep an ended session listed (true) or let it go after the usual linger (false).
    public mutating func keep(_ key: String, _ on: Bool) {
        if on, sessions[key] != nil { kept.insert(key) } else { kept.remove(key) }
    }

    /// The CLI reported another session id than the one this entry was entered under. The entry moves to the new
    /// id; when events of the new id were already listed, that entry wins and the placeholder goes away.
    /// Returns the key to use from now on.
    @discardableResult
    public mutating func rekey(_ oldKey: String, toSessionId newId: String) -> String {
        guard let old = sessions[oldKey] else { return oldKey }
        let newKey = "\(old.kind.rawValue):\(newId)"
        guard newKey != oldKey else { return oldKey }
        let wasKept = kept.contains(oldKey)
        if var existing = sessions[newKey] {
            existing.host = old.host
            if existing.title.isEmpty { existing.title = old.title }
            sessions[newKey] = existing
            remove(oldKey)
        } else {
            var s = AgentSession(kind: old.kind, sessionId: newId, cwd: old.cwd, now: old.startedAt)
            s.title = old.title; s.host = old.host; s.baseState = old.baseState; s.steps = old.steps
            s.pending = old.pending; s.lastEventAt = old.lastEventAt; s.finishedAt = old.finishedAt
            s.lastMessage = old.lastMessage; s.model = old.model; s.transcriptPath = old.transcriptPath
            s.hidden = old.hidden; s.revealed = old.revealed; s.turnStartedAt = old.turnStartedAt
            s.backgroundTasks = old.backgroundTasks; s.hold = old.hold; s.heldCalls = old.heldCalls
            s.supportsHold = old.supportsHold
            sessions[newKey] = s
            if let i = order.firstIndex(of: oldKey) { order[i] = newKey } else { order.append(newKey) }
            sessions[oldKey] = nil
            kept.remove(oldKey)
        }
        if wasKept { kept.insert(newKey) }
        return newKey
    }

    /// The agent process died without SessionEnd.
    public mutating func markEnded(_ key: String, now: Date) -> [String] {
        guard var s = sessions[key] else { return [] }
        s.baseState = .ended
        s.finishedAt = now
        s.backgroundTasks.removeAll()
        let released = Self.resolveAll(&s) + Self.releaseHold(&s)
        sessions[key] = s
        return released
    }

    // MARK: - Internal

    private mutating func mutateSession(forRequest rid: String, _ body: (inout AgentSession) -> Void) {
        guard let key = order.first(where: { sessions[$0]?.pending.contains { $0.id == rid } == true }),
              var s = sessions[key] else { return }
        body(&s)
        sessions[key] = s
    }

    /// The session moved on: open requests are cleared (answered in the terminal), expired ones removed.
    private static func resolveAll(_ s: inout AgentSession) -> [String] {
        let released = s.pending.filter { $0.status == .open }.map(\.id)
        s.pending.removeAll()
        if s.baseState == .waitingPermission { s.baseState = .working }
        return released
    }

    /// A new request from the same agent (the main one or the same subagent) displaces its previous open requests:
    /// the agent will not ask the next one until the previous one is answered.
    private static func resolveSuperseded(_ s: inout AgentSession, agentId: String?) -> [String] {
        let old = s.pending.filter { $0.status == .open && $0.agentId == agentId }
        guard !old.isEmpty else { return [] }
        s.pending.removeAll { p in old.contains { $0.id == p.id } }
        return old.map(\.id)
    }

    /// Events with which a hidden session is shown again.
    static func unhides(_ b: AgentEvent.Body) -> Bool {
        switch b {
        case .promptSubmitted, .permissionRequested, .questionAsked: return true
        default: return false
        }
    }

    /// Insertions by Claude Code itself into the prompt stream: background task notifications, slash commands, command output.
    /// They start with a tag like `<task-notification>`; a live prompt almost never starts that way.
    public static func isInjectedPrompt(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("<"), let close = t.firstIndex(of: ">") else { return false }
        let tag = t[t.index(after: t.startIndex)..<close]
        return !tag.isEmpty && tag.count <= 40 && tag.allSatisfy { $0.isLowercase || $0 == "-" || $0 == "_" || $0.isNumber }
    }

    /// The tool finished - clear the request that belonged to it.
    private static func resolve(_ s: inout AgentSession, toolName: String, fingerprint fp: String, command fpCommand: String? = nil) -> [String] {
        if s.baseState == .waitingPermission { s.baseState = .working }
        let match: (PendingRequest) -> Bool = { p in
            switch p.kind {
            case .permission(let t, let input):
                if p.inputFingerprint == fp { return true }
                // For commands we compare the command itself: the agent may add a description to the request,
                // while other commands of the same tool run in parallel.
                if let want = Self.commandText(input), let got = fpCommand { return want == got }
                return t == toolName
            // The finished input differs from the asked one (the answers are added to it), so only the tool is compared.
            case .question: return toolName == ClaudeCodeAdapter.questionTool
            case .plan: return toolName == ClaudeCodeAdapter.planTool
            }
        }
        guard let i = s.pending.firstIndex(where: match) else { return [] }
        let p = s.pending.remove(at: i)
        return p.status == .open ? [p.id] : []
    }

    /// Launch in the background: Bash or Agent (formerly Task) with `run_in_background: true`.
    static func backgroundKind(_ tool: String, _ input: JSONValue) -> BackgroundTask.Kind? {
        guard input["run_in_background"]?.boolValue == true else { return nil }
        switch tool {
        case "Bash": return .shell
        case "Agent", "Task": return .agent
        default: return nil
        }
    }

    /// Id of the task that the tool stops (TaskStop, formerly KillShell/KillBash).
    static func stopTarget(_ tool: String, _ input: JSONValue) -> String? {
        guard ["TaskStop", "KillShell", "KillBash"].contains(tool) else { return nil }
        for k in ["task_id", "shell_id", "bash_id", "id"] {
            if let s = input[k]?.stringValue, !s.isEmpty { return s }
        }
        return nil
    }

    /// Command text from the tool input (Bash in Claude).
    static func commandText(_ input: JSONValue) -> String? {
        if let c = input["command"]?.stringValue ?? input["cmd"]?.stringValue {
            return c.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let parts = input["command"]?.arrayValue?.compactMap(\.stringValue), !parts.isEmpty {
            // ["/bin/zsh", "-lc", "command"] -> "command"
            return (parts.count >= 3 && parts[1].hasPrefix("-") ? parts[2] : parts.joined(separator: " "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func isEnd(_ b: AgentEvent.Body) -> Bool {
        if case .sessionEnded = b { return true }
        return false
    }

    static func merge(_ old: HostInfo, _ new: HostInfo) -> HostInfo {
        HostInfo(termProgram: new.termProgram ?? old.termProgram,
                 tty: new.tty ?? old.tty,
                 agentPid: new.agentPid ?? old.agentPid,
                 herdrPaneId: new.herdrPaneId ?? old.herdrPaneId,
                 herdrSocket: new.herdrSocket ?? old.herdrSocket,
                 processChain: new.processChain.isEmpty ? old.processChain : new.processChain,
                 appBundleId: new.appBundleId ?? old.appBundleId,
                 appName: new.appName ?? old.appName,
                 hostSessionId: new.hostSessionId ?? old.hostSessionId,
                 entrypoint: new.entrypoint ?? old.entrypoint)
    }

    static func makeTitle(_ prompt: String) -> String {
        let oneLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = oneLine.trimmingCharacters(in: .whitespaces)
        return t.count > 60 ? String(t.prefix(59)) + "…" : t
    }
}
