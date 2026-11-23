import Foundation

/// Подключение и отключение хуков AgentHUD в конфиге агента
/// (`~/.claude/settings.json`).
/// Чужие хуки не трогаем; свои узнаём по имени `agenthud-hook` в команде.
public struct HookInstaller: Sendable {
    public static let marker = "agenthud-hook"

    public var agent: AgentKind
    public var hookPath: String
    public var timeout: Int

    public init(agent: AgentKind = .claude, hookPath: String, timeout: Int = HookTiming.defaultTimeout) {
        self.agent = agent
        self.hookPath = hookPath
        self.timeout = timeout
    }

    /// Подписка на событие. `matcher == nil` — у события нет матчера.
    /// `fixedTimeout` — для событий с жёстким лимитом.
    struct Spec {
        let event: String
        let matcher: String?
        let mode: HookMode
        var async: Bool? = nil
        var fixedTimeout: Int? = nil
    }

    var specs: [Spec] {
        switch agent {
        case .claude:
            return [
                Spec(event: "SessionStart", matcher: nil, mode: .event),
                Spec(event: "UserPromptSubmit", matcher: nil, mode: .event),
                Spec(event: "PreToolUse", matcher: "*", mode: .event),
                Spec(event: "PermissionRequest", matcher: "*", mode: .permission),
                Spec(event: "PostToolUse", matcher: "*", mode: .event),
                Spec(event: "PostToolUseFailure", matcher: "*", mode: .event),
                Spec(event: "Notification", matcher: nil, mode: .event),
                Spec(event: "SubagentStart", matcher: nil, mode: .event),
                Spec(event: "SubagentStop", matcher: nil, mode: .event),
                Spec(event: "Stop", matcher: nil, mode: .event),
                Spec(event: "StopFailure", matcher: nil, mode: .event),
                Spec(event: "SessionEnd", matcher: nil, mode: .event),
            ]
        }
    }

    func command(_ mode: HookMode) -> String {
        var cmd = "\(Self.shellQuote(hookPath)) \(agent.rawValue) \(mode.rawValue)"
        if mode.isSync { cmd += " --timeout \(timeout)" }
        return cmd
    }

    func hookEntry(_ spec: Spec) -> JSONValue {
        var h = JSONObject()
        h["type"] = "command"
        h["command"] = .string(command(spec.mode))
        if spec.mode.isSync {
            h["timeout"] = .int(timeout)
        } else {
            if spec.async ?? true { h["async"] = true }
            h["timeout"] = .int(spec.fixedTimeout ?? 10)
        }
        return .object(h)
    }

    func hookEntry(_ mode: HookMode) -> JSONValue {
        hookEntry(Spec(event: "", matcher: nil, mode: mode))
    }

    /// Блоки, которые AgentHUD добавляет (для показа пользователю).
    public func plannedEntries() -> JSONValue {
        var hooks = JSONObject()
        for spec in specs {
            var group = JSONObject()
            if let m = spec.matcher { group["matcher"] = .string(m) }
            group["hooks"] = [hookEntry(spec)]
            var arr = hooks[spec.event]?.arrayValue ?? []
            arr.append(.object(group))
            hooks[spec.event] = .array(arr)
        }
        return .object(hooks)
    }

    // MARK: - Преобразования JSON

    /// Добавить хуки AgentHUD (старые записи AgentHUD сначала убираются — операция идемпотентна).
    public func install(into settings: JSONValue) -> JSONValue {
        var root = Self.uninstall(from: settings).objectValue ?? JSONObject()
        var hooks = root["hooks"]?.objectValue ?? JSONObject()
        for spec in specs {
            var group = JSONObject()
            if let m = spec.matcher { group["matcher"] = .string(m) }
            group["hooks"] = [hookEntry(spec)]
            var arr = hooks[spec.event]?.arrayValue ?? []
            arr.append(.object(group))
            hooks[spec.event] = .array(arr)
        }
        root["hooks"] = .object(hooks)
        return .object(root)
    }

    /// Убрать только записи AgentHUD. Пустые группы и события удаляются, чужие — остаются как были.
    public static func uninstall(from settings: JSONValue) -> JSONValue {
        guard var root = settings.objectValue else { return settings }
        guard var hooks = root["hooks"]?.objectValue else { return settings }
        for entry in hooks.entries {
            guard let groups = entry.value.arrayValue else { continue }
            var newGroups: [JSONValue] = []
            var changed = false
            for g in groups {
                guard var go = g.objectValue, let list = go["hooks"]?.arrayValue else { newGroups.append(g); continue }
                let kept = list.filter { !isOurs($0) }
                if kept.count == list.count { newGroups.append(g); continue }
                changed = true
                if kept.isEmpty { continue }
                go["hooks"] = .array(kept)
                newGroups.append(.object(go))
            }
            guard changed else { continue }
            hooks[entry.key] = newGroups.isEmpty ? nil : .array(newGroups)
        }
        root["hooks"] = hooks.isEmpty ? nil : .object(hooks)
        return .object(root)
    }

    public static func isInstalled(in settings: JSONValue) -> Bool {
        for entry in settings["hooks"]?.objectValue?.entries ?? [] {
            for g in entry.value.arrayValue ?? [] {
                if (g["hooks"]?.arrayValue ?? []).contains(where: isOurs) { return true }
            }
        }
        return false
    }

    static func isOurs(_ hook: JSONValue) -> Bool {
        hook["command"]?.stringValue?.contains(marker) == true
    }

    static func shellQuote(_ s: String) -> String {
        if s.allSatisfy({ $0.isLetter || $0.isNumber || "/._-~".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Работа с файлом

    public struct FileResult: Sendable {
        public let backup: URL?
        public let before: String
        public let after: String
    }

    /// Что получится в файле — без записи.
    public static func preview(file: URL, transform: (JSONValue) -> JSONValue) throws -> (before: String, after: String) {
        let (value, before, trailingNewline) = try read(file)
        var after = transform(value).pretty()
        if trailingNewline { after += "\n" }
        return (before, after)
    }

    /// Бэкап → проверка → атомарная запись.
    @discardableResult
    public static func apply(file: URL, now: Date = Date(), transform: (JSONValue) -> JSONValue) throws -> FileResult {
        let fm = FileManager.default
        let (value, before, trailingNewline) = try read(file)
        var after = transform(value).pretty()
        if trailingNewline { after += "\n" }
        _ = try JSONValue.parse(after)   // результат обязан быть валидным JSON
        guard after != before else { return FileResult(backup: nil, before: before, after: after) }

        var backup: URL?
        if fm.fileExists(atPath: file.path) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            let b = file.deletingLastPathComponent()
                .appendingPathComponent(file.lastPathComponent + ".agenthud-backup-" + f.string(from: now))
            try? fm.removeItem(at: b)
            try fm.copyItem(at: file, to: b)
            backup = b
        } else {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).agenthud-tmp")
        try Data(after.utf8).write(to: tmp)
        if fm.fileExists(atPath: file.path) {
            _ = try fm.replaceItemAt(file, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: file)
        }
        return FileResult(backup: backup, before: before, after: after)
    }

    static func read(_ file: URL) throws -> (JSONValue, String, Bool) {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return (.object(JSONObject()), "", true)
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? JSONValue.object(JSONObject()) : try JSONValue.parse(text)
        return (value, text, text.hasSuffix("\n"))
    }
}

/// Старое имя — для совместимости.
public typealias ClaudeHookInstaller = HookInstaller
