import Foundation

/// "Allow always" options for a permission request.
///
/// Claude Code accepts `updatedPermissions` in the hook response - the same entries it sends
/// in `permission_suggestions` (https://code.claude.com/docs/en/hooks, PermissionRequest).
/// The agent's suggestions are often an exact command (`kill 41684 41849`), which makes the rule list
/// grow. So for simple commands we add a pattern by the first words: `Bash(npm run *)`.
public struct RuleOption: Equatable, Sendable, Identifiable {
    public var id: String { update.compact() }
    /// «Bash(npm run *)»
    public var title: String
    /// "in this project", "in all projects", "until the session ends"
    public var scope: String
    /// One entry for `updatedPermissions`.
    public var update: JSONValue
    /// A pattern invented by the HUD (not an agent suggestion).
    public var generated: Bool
}

public enum PermissionRules {
    /// Where the rule is stored. https://code.claude.com/docs/en/hooks - "Permission update entries".
    public static func scopeTitle(_ destination: String?) -> String {
        switch destination {
        case "session": return "until the session ends"
        case "localSettings": return "in this project"
        case "projectSettings": return "in this project (shared file)"
        case "userSettings": return "in all projects"
        default: return destination ?? ""
        }
    }

    public static func options(toolName: String, input: JSONValue, suggestions: [JSONValue],
                               redFlags: [RedFlagRule] = []) -> [RuleOption] {
        // A dangerous command must not be allowed forever: neither by a HUD pattern nor by an agent suggestion.
        guard redFlags.isEmpty else { return [] }
        var out: [RuleOption] = []
        func add(_ o: RuleOption) { if !out.contains(where: { $0.id == o.id }) { out.append(o) } }

        if toolName == "Bash", let cmd = input["command"]?.stringValue, let pattern = bashPattern(cmd) {
            for dest in ["localSettings", "userSettings"] {
                add(RuleOption(title: "Bash(\(pattern))", scope: scopeTitle(dest),
                               update: addRule(tool: "Bash", content: pattern, destination: dest), generated: true))
            }
        }
        for s in suggestions {
            guard let title = describe(s) else { continue }
            add(RuleOption(title: title, scope: scopeTitle(s["destination"]?.stringValue), update: s, generated: false))
        }
        // MCP tools: a rule for the whole tool (without ruleContent - otherwise the rule would match nothing).
        if toolName.hasPrefix("mcp__"), !out.contains(where: { $0.update["type"]?.stringValue == "addRules" }) {
            add(RuleOption(title: toolName, scope: scopeTitle("localSettings"),
                           update: addRule(tool: toolName, content: nil, destination: "localSettings"), generated: true))
        }
        return out
    }

    static func addRule(tool: String, content: String?, destination: String) -> JSONValue {
        var rule = JSONObject()
        rule["toolName"] = .string(tool)
        if let content { rule["ruleContent"] = .string(content) }
        return ["type": "addRules", "rules": [.object(rule)], "behavior": "allow", "destination": .string(destination)]
    }

    /// Label for an `updatedPermissions` entry. `nil` - the entry is not about "allow".
    public static func describe(_ entry: JSONValue) -> String? {
        switch entry["type"]?.stringValue {
        case "addRules", "replaceRules":
            guard entry["behavior"]?.stringValue == "allow" else { return nil }
            let rules = (entry["rules"]?.arrayValue ?? []).compactMap { r -> String? in
                guard let tool = r["toolName"]?.stringValue else { return nil }
                if let c = r["ruleContent"]?.stringValue, !c.isEmpty {
                    return "\(tool)(\(c.count > 60 ? String(c.prefix(59)) + "…" : c))"
                }
                return tool
            }
            return rules.isEmpty ? nil : rules.joined(separator: ", ")
        case "setMode":
            switch entry["mode"]?.stringValue {
            case "acceptEdits": return "Accept file edits without asking"
            case "default", "manual": return "Default mode"
            case "plan": return "Planning mode"
            default: return nil   // other modes (including no-questions ones) are not enabled from the HUD
            }
        case "addDirectories":
            let dirs = (entry["directories"]?.arrayValue ?? []).compactMap(\.stringValue)
            return dirs.isEmpty ? nil : "Access to folder " + dirs.joined(separator: ", ")
        default:
            return nil
        }
    }

    /// First words that are usually followed by an argument: `npm run build` -> `npm run *`.
    static let subcommandTools: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "npx", "bunx", "git", "gh", "docker", "kubectl", "go", "cargo", "swift",
        "pod", "expo", "eas", "flutter", "dart", "pip", "pip3", "brew", "make", "xcodebuild", "xcrun", "adb",
        "fastlane", "bundle", "composer", "dotnet", "uv", "poetry", "nx", "turbo", "vite", "next", "jest", "vitest",
        "tsc", "eslint", "prettier", "prisma", "supabase", "firebase", "react-native",
    ]

    /// Commands for which a pattern is too broad (they run arbitrary code or are dangerous) - only an exact rule.
    static let noPattern: Set<String> = [
        "rm", "sudo", "su", "dd", "chmod", "chown", "mkfs", "curl", "wget", "ssh", "scp", "rsync", "eval", "exec",
        "xargs", "env", "node", "python", "python3", "ruby", "perl", "php", "bash", "sh", "zsh", "fish", "osascript",
        "open", "mv", "cp", "tee", "find", "awk", "sed", "deno",
    ]

    /// These tools run arbitrary subcommands (push, run, exec...): the HUD rule for them is only the exact command.
    static let exactOnly: Set<String> = ["git", "uv", "docker", "npx", "make"]

    /// Pattern for a simple command, or `nil` if a pattern is not needed or is dangerous.
    public static func bashPattern(_ command: String) -> String? {
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return nil }
        // Claude Code checks compound commands part by part - a pattern for the whole line would not help.
        for bad in ["&&", "||", ";", "|", "`", "$(", ">", "<", "\n", "&"] where cmd.contains(bad) { return nil }
        let words = cmd.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = words.first, !first.contains("="), !first.hasPrefix("."), !first.hasPrefix("/"),
              !noPattern.contains(first) else { return nil }
        if exactOnly.contains(first) {
            // An asterisk in an exact command would become a pattern.
            return cmd.contains("*") ? nil : cmd
        }
        if subcommandTools.contains(first) {
            // `git status` -> `git status *` (matches without arguments too). A flag as the second word - unclear what to pattern.
            guard words.count >= 2, !words[1].hasPrefix("-") else { return nil }
            return "\(first) \(words[1]) *"
        }
        // `kill 41684 41849` -> `kill *`. A single word - an exact rule is no worse than a pattern.
        return words.count >= 2 ? "\(first) *" : nil
    }
}
