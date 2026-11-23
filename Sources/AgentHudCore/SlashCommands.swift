import Foundation

/// A slash command the chat input can suggest.
public struct SlashCommand: Identifiable, Equatable, Sendable {
    public enum Source: String, Sendable { case builtin, user, project, plugin }
    public var id: String { name }
    /// Without the leading slash, e.g. "compact", "seo:audit".
    public let name: String
    /// One line, may be empty.
    public let description: String
    /// e.g. "[instructions]".
    public let argumentHint: String?
    public let source: Source

    public init(name: String, description: String, argumentHint: String? = nil, source: Source) {
        self.name = name
        self.description = description
        self.argumentHint = argumentHint
        self.source = source
    }
}

public enum SlashCommands {
    // MARK: Built-in list

    private static func b(_ name: String, _ hint: String?, _ description: String) -> SlashCommand {
        SlashCommand(name: name, description: description, argumentHint: hint, source: .builtin)
    }

    /// Built-in commands and bundled skills from the public command reference (descriptions shortened).
    public static let builtin: [SlashCommand] = [
        b("add-dir", "<path>", "Add a working directory for file access"),
        b("agents", nil, "Manage subagents"),
        b("background", "[prompt]", "Detach the session to run in the background"),
        b("batch", "<instruction>", "Orchestrate large-scale changes in parallel"),
        b("branch", "[name]", "Branch the conversation at this point"),
        b("btw", "[question]", "Ask a side question without adding to the conversation"),
        b("bug", "[report]", "Report a bug or share the conversation"),
        b("cd", "<path>", "Move the session to a new working directory"),
        b("clear", "[name]", "Start a new conversation with empty context"),
        b("code-review", "[level] [target]", "Review a diff or pull request"),
        b("compact", "[instructions]", "Summarize the conversation to free up context"),
        b("config", "[key=value ...]", "Open settings"),
        b("context", "[all]", "Visualize current context usage"),
        b("copy", "[N]", "Copy the last response to the clipboard"),
        b("cost", nil, "Alias for /usage"),
        b("debug", "[description]", "Troubleshoot using the session debug log"),
        b("diff", nil, "Review changes in the working tree"),
        b("doctor", nil, "Diagnose installation and settings problems"),
        b("effort", "[level]", "Set the effort level"),
        b("exit", nil, "Exit the CLI"),
        b("export", "[filename]", "Export the conversation as plain text"),
        b("fast", "[on|off]", "Toggle fast mode"),
        b("feedback", "[report]", "Send product feedback"),
        b("fork", "[prompt]", "Copy the conversation into a new background session"),
        b("goal", "[condition|clear]", "Keep working until a condition is met"),
        b("help", nil, "Show help and available commands"),
        b("hooks", nil, "View hook configurations"),
        b("ide", nil, "Manage IDE integrations"),
        b("init", nil, "Initialize the project with a guide file"),
        b("insights", nil, "Generate a report analyzing recent sessions"),
        b("keybindings", nil, "Open the keyboard shortcuts file"),
        b("login", nil, "Sign in to your account"),
        b("logout", nil, "Sign out of your account"),
        b("loop", "[interval] [prompt]", "Run a prompt repeatedly"),
        b("mcp", nil, "Manage MCP server connections"),
        b("memory", nil, "Edit memory files"),
        b("model", "[model]", "Switch the model"),
        b("output-style", "[style]", "Switch the output style"),
        b("permissions", nil, "Manage tool permission rules"),
        b("plan", "[description]", "Enter plan mode"),
        b("plugin", "[subcommand]", "Manage plugins"),
        b("recap", nil, "Generate a one-line summary of the session"),
        b("reload-plugins", nil, "Reload active plugins"),
        b("reload-skills", nil, "Re-scan skill and command directories"),
        b("rename", "[name]", "Rename the current session"),
        b("resume", "[session]", "Resume a conversation"),
        b("review", "[level] [target]", "Alias of /code-review"),
        b("rewind", nil, "Rewind the conversation or code to a previous point"),
        b("run", nil, "Launch and drive the project's app"),
        b("sandbox", nil, "Toggle sandbox mode"),
        b("schedule", "[description]", "Manage scheduled cloud tasks"),
        b("security-review", nil, "Analyze the branch changes for vulnerabilities"),
        b("simplify", "[target]", "Review changed code for cleanups and apply them"),
        b("skills", nil, "List available skills"),
        b("stats", nil, "Alias for /usage"),
        b("status", nil, "Show version, model, account and connectivity"),
        b("statusline", nil, "Configure the status line"),
        b("tasks", nil, "View and manage background work"),
        b("theme", nil, "Change the color theme"),
        b("update-config", "[request]", "Change settings"),
        b("usage", nil, "Show session cost and plan usage"),
        b("verify", nil, "Confirm a change works by running the app"),
        b("vim", nil, "Toggle vim editing mode"),
    ]

    // MARK: Discovery

    private static let maxHeadBytes = 8 * 1024
    private static let maxCommandDepth = 4
    private static let maxDescription = 120

    /// Built-in + user + project + plugin commands and skills, de-duplicated by name
    /// (project > user > plugin > builtin), sorted by name. Never throws.
    public static func available(home: URL, projectDir: URL?) -> [SlashCommand] {
        var groups: [[SlashCommand]] = []
        if let p = projectDir {
            let c = p.appendingPathComponent(".claude", isDirectory: true)
            groups.append(scanCommands(c.appendingPathComponent("commands", isDirectory: true), prefix: "", source: .project)
                + scanSkills(c.appendingPathComponent("skills", isDirectory: true), prefix: "", source: .project))
        }
        let userRoot = home.appendingPathComponent(".claude", isDirectory: true)
        groups.append(scanCommands(userRoot.appendingPathComponent("commands", isDirectory: true), prefix: "", source: .user)
            + scanSkills(userRoot.appendingPathComponent("skills", isDirectory: true), prefix: "", source: .user))
        groups.append(pluginCommands(home: home, projectDir: projectDir))
        groups.append(builtin)

        var seen = Set<String>()
        var out: [SlashCommand] = []
        for g in groups {
            for c in g where seen.insert(c.name).inserted { out.append(c) }
        }
        return out.sorted { $0.name < $1.name }
    }

    /// First bytes of a file as text; nil when unreadable. Invalid UTF-8 is replaced, not rejected.
    private static func head(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: maxHeadBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    private static func entries(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// `user-invocable: false` hides the entry from the `/` menu.
    private static func hidden(_ fm: [String: String]) -> Bool {
        fm["user-invocable"]?.lowercased() == "false"
    }

    private static func make(name: String, fm: [String: String], source: SlashCommand.Source) -> SlashCommand? {
        guard !hidden(fm) else { return nil }
        let hint = fm["argument-hint"].flatMap { $0.isEmpty ? nil : $0 }
        return SlashCommand(name: name, description: oneLine(fm["description"] ?? ""), argumentHint: hint, source: source)
    }

    /// `commands/a/b.md` becomes `a:b`; sub-folders go up to `maxCommandDepth` levels.
    private static func scanCommands(_ dir: URL, prefix: String, source: SlashCommand.Source, depth: Int = 0) -> [SlashCommand] {
        var out: [SlashCommand] = []
        for entry in entries(dir) {
            let url = dir.appendingPathComponent(entry)
            if isDir(url) {
                if depth < maxCommandDepth {
                    out += scanCommands(url, prefix: prefix + entry + ":", source: source, depth: depth + 1)
                }
            } else if entry.lowercased().hasSuffix(".md") {
                let base = String(entry.dropLast(3))
                guard !base.isEmpty else { continue }
                let fm = head(url).map(frontmatter) ?? [:]
                if let c = make(name: prefix + base, fm: fm, source: source) { out.append(c) }
            }
        }
        return out
    }

    /// `skills/<folder>/SKILL.md`; the frontmatter `name` wins over the folder name. Symlinked folders are followed.
    private static func scanSkills(_ dir: URL, prefix: String, source: SlashCommand.Source) -> [SlashCommand] {
        var out: [SlashCommand] = []
        for entry in entries(dir) {
            let folder = dir.appendingPathComponent(entry, isDirectory: true)
            guard isDir(folder), let text = head(folder.appendingPathComponent("SKILL.md")) else { continue }
            let fm = frontmatter(text)
            let name = fm["name"].flatMap { $0.isEmpty ? nil : $0 } ?? entry
            if let c = make(name: prefix + name, fm: fm, source: source) { out.append(c) }
        }
        return out
    }

    /// Installed plugins are listed in `~/.claude/plugins/installed_plugins.json` (`plugins` maps
    /// `name@marketplace` to install records with `installPath`). Plugins switched off in `settings.json` are skipped.
    private static func pluginCommands(home: URL, projectDir: URL?) -> [SlashCommand] {
        let root = home.appendingPathComponent(".claude", isDirectory: true)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("plugins/installed_plugins.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = json["plugins"] as? [String: Any] else { return [] }
        var disabled = Set<String>()
        if let sd = try? Data(contentsOf: root.appendingPathComponent("settings.json")),
           let sj = try? JSONSerialization.jsonObject(with: sd) as? [String: Any],
           let enabled = sj["enabledPlugins"] as? [String: Any] {
            for (k, v) in enabled where (v as? Bool) == false { disabled.insert(k) }
        }
        var out: [SlashCommand] = []
        for key in plugins.keys.sorted() where !disabled.contains(key) {
            guard let records = plugins[key] as? [[String: Any]] else { continue }
            let pluginName = String(key.split(separator: "@", maxSplits: 1).first ?? "")
            guard !pluginName.isEmpty else { continue }
            for r in records {
                guard let path = r["installPath"] as? String, !path.isEmpty else { continue }
                // Project-scoped installs apply only to their own project.
                if let scope = r["scope"] as? String, scope != "user" {
                    guard let pp = r["projectPath"] as? String, let pd = projectDir,
                          URL(fileURLWithPath: pp).standardizedFileURL.path == pd.standardizedFileURL.path else { continue }
                }
                let base = URL(fileURLWithPath: path, isDirectory: true)
                out += scanCommands(base.appendingPathComponent("commands", isDirectory: true), prefix: pluginName + ":", source: .plugin)
                out += scanSkills(base.appendingPathComponent("skills", isDirectory: true), prefix: pluginName + ":", source: .plugin)
                if let text = head(base.appendingPathComponent("SKILL.md")) {
                    let fm = frontmatter(text)
                    let n = fm["name"].flatMap { $0.isEmpty ? nil : $0 } ?? pluginName
                    if let c = make(name: n.hasPrefix(pluginName + ":") || n == pluginName ? n : pluginName + ":" + n, fm: fm, source: .plugin) {
                        out.append(c)
                    }
                }
                break // one install per plugin is enough
            }
        }
        return out
    }

    // MARK: Suggestions

    /// Suggestions for what is typed so far. `input` is the whole field text.
    /// Returns [] unless the text is a single token starting with "/" (no spaces yet).
    public static func suggestions(for input: String, in commands: [SlashCommand], limit: Int = 8) -> [SlashCommand] {
        guard input.hasPrefix("/"), limit > 0,
              !input.contains(where: { $0.isWhitespace }) else { return [] }
        let q = String(input.dropFirst()).lowercased()
        if q.isEmpty { return Array(commands.sorted { $0.name < $1.name }.prefix(limit)) }

        var ranked: [(Int, SlashCommand)] = []
        for c in commands {
            let n = c.name.lowercased()
            let rank: Int
            if n == q { rank = 0 }
            else if n.hasPrefix(q) { rank = 1 }
            else if n.split(whereSeparator: { $0 == ":" || $0 == "-" }).dropFirst().contains(where: { $0.hasPrefix(q) }) { rank = 2 }
            else if n.contains(q) { rank = 3 }
            else { continue }
            ranked.append((rank, c))
        }
        ranked.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1.name < $1.1.name }
        return ranked.prefix(limit).map(\.1)
    }

    // MARK: Frontmatter

    /// Minimal YAML-frontmatter reader: top-level `key: value` lines between the opening and closing `---`.
    /// Quoted values are unquoted; block scalars (`|`, `>`) and empty values take the first non-empty indented line.
    static func frontmatter(_ text: String) -> [String: String] {
        var t = text
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        let lines = t.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var out: [String: String] = [:]
        var i = 1
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            i += 1
            guard let f = line.first, f != " ", f != "\t", f != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value == "|" || value == ">" || value == "|-" || value == ">-" || value == "|+" || value == ">+" {
                var j = i
                value = ""
                while j < lines.count, let c = lines[j].first, c == " " || c == "\t" || lines[j].isEmpty {
                    let s = lines[j].trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { value = s; break }
                    j += 1
                }
            }
            out[key] = unquote(value)
        }
        return out
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, let l = s.last, f == l, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// First line, trimmed, capped at 120 characters.
    private static func oneLine(_ s: String) -> String {
        let line = s.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return line.count > maxDescription ? String(line.prefix(maxDescription - 1)) + "…" : line
    }
}
