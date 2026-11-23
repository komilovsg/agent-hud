import Foundation

/// "Red flag" rule: a dangerous Bash command. A request with a flag is shown in red,
/// and "Allow always" is not offered for it.
public struct RedFlagRule: Equatable, Sendable {
    public var id: String
    public var title: String
    /// Case-insensitive NSRegularExpression; searched anywhere in the full command line.
    public var pattern: String

    public init(id: String, title: String, pattern: String) {
        self.id = id
        self.title = title
        self.pattern = pattern
    }
}

/// A set of rules from the user's file (`red-flags.json`) or the built-in one.
public struct RedFlagSet: Sendable {
    public var rules: [RedFlagRule]
    /// What is wrong with the rules file - as text for the user.
    public var problems: [String]

    public init(rules: [RedFlagRule], problems: [String] = []) {
        self.rules = rules
        self.problems = problems
    }

    /// All rules the command matches. Only Bash has flags.
    public func matches(toolName: String, input: JSONValue) -> [RedFlagRule] {
        guard toolName == "Bash", let cmd = input["command"]?.stringValue else { return [] }
        let range = NSRange(cmd.startIndex..., in: cmd)
        return rules.filter { rule in
            guard let re = Self.regex(rule.pattern) else { return false }
            return re.firstMatch(in: cmd, range: range) != nil
        }
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    // MARK: File

    /// Reads the rules. Any trouble with the file - built-in rules plus a description of the problem:
    /// a broken file must not silently turn the protection off.
    public static func load(from url: URL) -> RedFlagSet {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((defaultsJSON.pretty() + "\n").utf8).write(to: url, options: .atomic)
            return RedFlagSet(rules: defaults)
        }
        // We do not overwrite the user's file: they will fix it themselves.
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            return RedFlagSet(rules: defaults, problems: ["\(name) cannot be read - built-in rules are in effect"])
        }
        let json: JSONValue
        do {
            json = try JSONValue.parse(data)
        } catch {
            return RedFlagSet(rules: defaults, problems: ["\(name): \(error) - built-in rules are in effect"])
        }
        guard let list = json["rules"]?.arrayValue else {
            return RedFlagSet(rules: defaults, problems: ["\(name): no rules array - built-in rules are in effect"])
        }
        // An empty array is a deliberate user choice: no rules.
        var rules: [RedFlagRule] = []
        var problems: [String] = []
        for (i, entry) in list.enumerated() {
            let id = entry["id"]?.stringValue ?? ""
            let label = id.isEmpty ? "№\(i + 1)" : id
            guard !id.isEmpty, let title = entry["title"]?.stringValue, !title.isEmpty,
                  let pattern = entry["pattern"]?.stringValue, !pattern.isEmpty else {
                problems.append("Rule \(label): non-empty id, title and pattern are required - skipped")
                continue
            }
            guard regex(pattern) != nil else {
                problems.append("Rule \(label): invalid regular expression - skipped")
                continue
            }
            rules.append(RedFlagRule(id: id, title: title, pattern: pattern))
        }
        return RedFlagSet(rules: rules, problems: problems)
    }

    static var defaultsJSON: JSONValue {
        let list = defaults.map { r -> JSONValue in
            ["id": .string(r.id), "title": .string(r.title), "pattern": .string(r.pattern)]
        }
        return ["version": 1, "rules": .array(list)]
    }

    // MARK: Built-in rules

    /// Start of a command name: not the tail of another word (`perform`, `legit`), but a path (`/bin/rm`) is fine.
    private static let cmd = #"(?<![\w.-])"#
    /// The rest of a single simple command: we do not cross `;`, `&`, `|` and a newline.
    private static let seg = #"[^;&|\n]*?"#
    /// End of an argument word.
    private static let end = #"(?=$|[\s;&|)"'])"#
    /// `git push`, including `git -C dir push`.
    private static let gitPush = cmd + #"git\s+(?:"# + seg + #"\s)?push"#

    public static let defaults: [RedFlagRule] = [
        RedFlagRule(
            id: "push-protected",
            title: "Push to a protected branch (main, master, dev, develop)",
            // The branch is a separate word or the right part of a refspec (`HEAD:main`); `feature/dev-tools` and `develop-2` do not match.
            pattern: gitPush + #"\s(?:"# + seg + #"[\s"'])?\+?(?:[^\s:;&|]*:)?(?:refs/heads/)?(?:main|master|dev|develop)"# + end
        ),
        RedFlagRule(
            id: "force",
            title: "Forced operation (--force, push -f, +refspec)",
            pattern: #"(?<![\w-])--force(?:-with-lease|-if-includes)?(?=$|[\s=;&|)"'])"#
                + "|" + gitPush + #"\s(?:"# + seg + #"\s)?(?:-[a-z]*f[a-z]*"# + end + #"|\+[^\s;&|]+)"#
        ),
        RedFlagRule(
            id: "mr-create",
            title: "Creating or merging a merge request / pull request",
            pattern: #"(?:(?<![\w-])-o\s*|--push-option[=\s]\s*)["']?merge_request\."#
                + "|" + cmd + #"glab\s+(?:"# + seg + #"\s)?mr\s+(?:create|new|merge|update|approve)"# + end
                + "|" + cmd + #"gh\s+(?:"# + seg + #"\s)?pr\s+(?:create|merge)"# + end
        ),
        RedFlagRule(
            id: "rm-rf",
            title: "Recursive delete without confirmation (rm -rf)",
            // Two independent conditions on one command: there is recursion and there is force, in any order and form.
            pattern: cmd + #"rm(?=\s)"#
                + #"(?=[^;&|\n]*\s(?:-[a-z]*r[a-z]*|--recursive)"# + end + ")"
                + #"(?=[^;&|\n]*\s(?:-[a-z]*f[a-z]*|--force)"# + end + ")"
        ),
        RedFlagRule(
            id: "db-migrate",
            title: "Database migration or write",
            // For psql/pg_restore the flag is an explicit server address. `-h`/`-p` are case-sensitive: `-H` and `-P` mean something else in psql.
            pattern: cmd + #"alembic\s+(?:"# + seg + #"\s)?(?:upgrade|downgrade)(?![\w-])"#
                + "|" + cmd + #"prisma\s+(?:"# + seg + #"\s)?migrate\s+(?:deploy|reset)(?![\w-])"#
                + "|" + cmd + #"artisan\s+(?:"# + seg + #"\s)?migrate(?!\w)"#
                + "|" + #"(?<![\w-])manage\.py\s+(?:"# + seg + #"\s)?migrate(?!\w)"#
                + "|" + cmd + #"(?:psql|pg_restore)(?=\s)(?=[^;&|\n]*(?:\s(?-i:-[hp])|\s--(?:host|port)(?![\w-])|postgres(?:ql)?://))"#
        ),
    ]
}
