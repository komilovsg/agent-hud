import Foundation

/// Адаптер Claude Code: хуки из `~/.claude/settings.json`.
/// Документация: https://code.claude.com/docs/en/hooks
public struct ClaudeCodeAdapter: AgentAdapter {
    public init() {}

    public var kind: AgentKind { .claude }

    /// Инструменты, на которые хук разрешений не отвечает: вопрос и одобрение плана остаются
    /// в обычном интерфейсе Claude Code.
    static let permissionPassthroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    public func shouldForward(mode: HookMode, payload: JSONValue) -> Bool {
        let tool = payload["tool_name"]?.stringValue ?? ""
        switch mode {
        case .event: return payload["session_id"]?.stringValue != nil
        case .permission: return !Self.permissionPassthroughTools.contains(tool)
        }
    }

    public func events(from message: HookMessage, now: Date) -> [AgentEvent] {
        let p = message.payload
        guard let sid = p["session_id"]?.stringValue else { return [] }
        let name = p["hook_event_name"]?.stringValue ?? ""
        let toolName = p["tool_name"]?.stringValue ?? ""
        let input = p["tool_input"] ?? .object(JSONObject())
        let toolUseId = p["tool_use_id"]?.stringValue
        let deadline = message.deadline ?? HookTiming.deadline(now: now, hookTimeout: HookTiming.defaultTimeout)

        func make(_ body: AgentEvent.Body) -> AgentEvent {
            AgentEvent(kind: .claude, sessionId: sid, cwd: p["cwd"]?.stringValue,
                       transcriptPath: p["transcript_path"]?.stringValue,
                       agentId: p["agent_id"]?.stringValue,
                       host: message.host.isEmpty ? nil : message.host, time: now, body: body)
        }

        switch message.mode {
        case .permission:
            return [make(.permissionRequested(requestId: message.requestId, toolName: toolName, input: input, deadline: deadline,
                                              suggestions: p["permission_suggestions"]?.arrayValue ?? []))]
        case .event:
            break
        }

        switch name {
        case "SessionStart":
            return [make(.sessionStarted(source: p["source"]?.stringValue, model: Self.modelName(p["model"])))]
        case "UserPromptSubmit":
            return [make(.promptSubmitted(p["prompt"]?.stringValue ?? ""))]
        case "PreToolUse":
            return [make(.toolStarted(toolName: toolName, input: input, toolUseId: toolUseId))]
        case "PostToolUse":
            return [make(.toolFinished(toolName: toolName, input: input, toolUseId: toolUseId,
                                       durationMs: p["duration_ms"]?.intValue, failed: false))]
        case "PostToolUseFailure":
            return [make(.toolFinished(toolName: toolName, input: input, toolUseId: toolUseId,
                                       durationMs: p["duration_ms"]?.intValue, failed: true))]
        case "SubagentStart":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            var e = make(.subagentStarted(agentId: aid, agentType: p["agent_type"]?.stringValue))
            e.agentId = nil
            return [e]
        case "SubagentStop":
            guard let aid = p["agent_id"]?.stringValue else { return [] }
            var e = make(.subagentStopped(agentId: aid))
            e.agentId = nil
            return [e]
        case "Stop":
            return [make(.stopped(lastMessage: p["last_assistant_message"]?.stringValue, failed: false))]
        case "StopFailure":
            return [make(.stopped(lastMessage: p["error"]?.stringValue ?? p["last_assistant_message"]?.stringValue, failed: true))]
        case "SessionEnd":
            return [make(.sessionEnded(reason: p["reason"]?.stringValue))]
        case "Notification":
            return [make(.notification(type: p["notification_type"]?.stringValue, message: p["message"]?.stringValue))]
        default:
            return []
        }
    }

    public func hookOutput(for decision: Decision, mode: HookMode, payload: JSONValue) -> String? {
        switch (mode, decision) {
        case (_, .passthrough), (.event, _):
            return nil
        case (.permission, .allow):
            return Self.permissionOutput(Self.allowDecision(payload: payload, updates: []))
        case (.permission, .allowWith(let updates)):
            return Self.permissionOutput(Self.allowDecision(payload: payload, updates: updates))
        case (.permission, .deny(let reason)):
            let given = (reason?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            let msg = given ?? "Пользователь отклонил это действие в AgentHUD."
            return Self.permissionOutput(["behavior": "deny", "message": .string(msg)])
        }
    }

    /// `allow` для PermissionRequest. Документация: `updatedPermissions` — правила и режим (можно вернуть одну из `permission_suggestions` без изменений).
    static func allowDecision(payload: JSONValue, updates: [JSONValue]) -> JSONValue {
        var d = JSONObject()
        d["behavior"] = "allow"
        if !updates.isEmpty { d["updatedPermissions"] = .array(updates) }
        return .object(d)
    }

    static func permissionOutput(_ decision: JSONValue) -> String {
        let out: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return out.compact()
    }

    static func modelName(_ v: JSONValue?) -> String? {
        if let s = v?.stringValue { return s }
        return v?["display_name"]?.stringValue ?? v?["id"]?.stringValue
    }

    // MARK: - Краткая суть шага

    public func summarize(toolName: String, input: JSONValue, cwd: String?) -> String {
        func path(_ key: String = "file_path") -> String {
            Self.shortPath(input[key]?.stringValue ?? input["path"]?.stringValue ?? "", cwd: cwd)
        }
        func firstLine(_ s: String, max: Int = 80) -> String {
            let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return line.count > max ? String(line.prefix(max - 1)) + "…" : line
        }

        switch toolName {
        case "Bash":
            return "$ " + firstLine(input["command"]?.stringValue ?? "")
        case "Read": return "Read " + path()
        case "Write": return "Write " + path()
        case "Edit", "MultiEdit": return "Edit " + path()
        case "NotebookEdit": return "Edit " + path("notebook_path")
        case "Grep":
            let pat = input["pattern"]?.stringValue ?? ""
            return "Grep \"\(firstLine(pat, max: 50))\""
        case "Glob": return "Glob " + (input["pattern"]?.stringValue ?? "")
        case "WebFetch":
            let url = input["url"]?.stringValue ?? ""
            return "WebFetch " + (URL(string: url)?.host ?? url)
        case "WebSearch": return "WebSearch \"\(firstLine(input["query"]?.stringValue ?? "", max: 60))\""
        case "Task", "Agent":
            return "Агент: " + firstLine(input["description"]?.stringValue ?? input["subagent_type"]?.stringValue ?? "")
        case "TodoWrite": return "Обновил список задач"
        case "Skill": return "Скилл " + (input["skill"]?.stringValue ?? "")
        default:
            if toolName.hasPrefix("mcp__") {
                let parts = toolName.split(separator: "_", omittingEmptySubsequences: true)
                // mcp__server__tool → ["mcp", "server", "tool"...]; имя сервера может содержать "_"
                let comps = toolName.dropFirst(5).components(separatedBy: "__")
                if comps.count >= 2 { return "\(comps[0]) · \(comps.dropFirst().joined(separator: "__"))" }
                return parts.dropFirst().joined(separator: " ")
            }
            return toolName
        }
    }

    static func shortPath(_ p: String, cwd: String?) -> String {
        guard !p.isEmpty else { return "" }
        if let cwd, !cwd.isEmpty, p.hasPrefix(cwd + "/") { return String(p.dropFirst(cwd.count + 1)) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p.hasPrefix(home + "/") { return "~/" + p.dropFirst(home.count + 1) }
        return p
    }
}
