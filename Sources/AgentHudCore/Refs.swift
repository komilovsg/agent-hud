import Foundation

/// Branches and merge/pull request links found in commands and git output.
/// Pure functions: only strings in, no file reading.
public enum GitRefs {
    /// Branch names from git commands (including compound `a && b ; c`).
    /// `echo git checkout -b x` does not count: the command must start with `git`.
    public static func branches(inCommand command: String) -> [String] {
        var out: [String] = []
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), isBranchName(s), !out.contains(s) else { return }
            out.append(s)
        }
        for segment in segments(command) {
            var t = segment
            // Environment assignments at the start: FOO=1 git ...
            while let f = t.first, f.contains("="), !f.hasPrefix("-"), f.first != "=" { t.removeFirst() }
            guard t.first == "git" else { continue }
            t.removeFirst()
            // Global options before the subcommand: -C dir, -c k=v, --no-pager, etc.
            while let f = t.first, f.hasPrefix("-") {
                t.removeFirst()
                if f == "-C" || f == "-c" || f == "--git-dir" || f == "--work-tree", !t.isEmpty { t.removeFirst() }
            }
            guard let sub = t.first else { continue }
            let args = Array(t.dropFirst())
            switch sub {
            case "checkout", "switch": checkout(args).forEach(add)
            case "push": push(args).forEach(add)
            case "branch": add(branchCreate(args))
            default: break
            }
        }
        return out
    }

    /// Merge/pull request links in arbitrary text (command, stdout, stderr).
    /// A "create MR" link after push is kept without extra parameters, except the source branch.
    public static func links(inText text: String) -> [String] {
        var out: [String] = []
        for m in urlRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            var url = String(text[r])
            while let l = url.last, ".,;:!?)]}>'\"".contains(l) { url.removeLast() }
            if let link = normalize(url), !out.contains(link) { out.append(link) }
        }
        return out
    }

    /// Source branches from "create MR" links (`merge_request[source_branch]=...`).
    public static func branches(inText text: String) -> [String] {
        var out: [String] = []
        for link in links(inText: text) {
            guard let b = sourceBranch(link), !out.contains(b) else { continue }
            out.append(b)
        }
        return out
    }

    // MARK: - Parsing

    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s"'<>]+"#)
    private static let mrNumber = try! NSRegularExpression(pattern: #"^(https?://[^/?#\s]+/[^?#\s]*?/merge_requests/\d+)"#)
    private static let mrNew = try! NSRegularExpression(pattern: #"^(https?://[^/?#\s]+/[^?#\s]*?/merge_requests/new)(?:$|[?#])"#)
    private static let ghPull = try! NSRegularExpression(pattern: #"^(https://github\.com/[^/?#\s]+/[^/?#\s]+/pull/\d+)"#)
    private static let sourceKey = "merge_request%5Bsource_branch%5D="

    private static func firstGroup(_ re: NSRegularExpression, _ s: String) -> String? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func normalize(_ url: String) -> String? {
        if let s = firstGroup(mrNumber, url) { return s }
        if let s = firstGroup(ghPull, url) { return s }
        if let base = firstGroup(mrNew, url) {
            if let r = url.range(of: sourceKey) {
                let value = url[r.upperBound...].prefix { $0 != "&" && $0 != "#" }
                if !value.isEmpty { return base + "?" + sourceKey + value }
            }
            return base
        }
        return nil
    }

    private static func sourceBranch(_ link: String) -> String? {
        guard let r = link.range(of: sourceKey) else { return nil }
        let value = String(link[r.upperBound...].prefix { $0 != "&" && $0 != "#" })
        return value.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Command -> segments by `&&`, `||`, `;`, `|`, newlines; each one is words.
    private static func segments(_ command: String) -> [[String]] {
        var s = command
        for sep in ["&&", "||", ";", "|", "\n"] { s = s.replacingOccurrences(of: sep, with: "\u{1}") }
        return s.split(separator: "\u{1}").map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) }
            .filter { !$0.isEmpty }
    }

    private static func isBranchName(_ s: String) -> Bool {
        guard !s.isEmpty, s != "HEAD", s != "-", s != "--", s != ".", s != "..",
              !s.hasPrefix("-"), !s.hasPrefix("/"), !s.hasPrefix("~"), !s.hasPrefix("./"), !s.hasPrefix("../"),
              !s.contains("$"), !s.contains("`") else { return false }
        return true
    }

    private static func checkout(_ args: [String]) -> [String] {
        let creators: Set<String> = ["-b", "-B", "-c", "-C", "--create", "--force-create", "--orphan"]
        if let i = args.firstIndex(where: { creators.contains($0) }) {
            return i + 1 < args.count ? [args[i + 1]] : []
        }
        // Everything after `--` is paths; `git checkout X -- file` restores a file, no branch.
        if args.contains("--") { return [] }
        let positional = args.filter { !$0.hasPrefix("-") }
        return positional.count == 1 ? positional : []
    }

    private static func push(_ args: [String]) -> [String] {
        if args.contains(where: { $0 == "--delete" || $0 == "-d" }) { return [] }
        let positional = args.filter { !$0.hasPrefix("-") }
        guard positional.count >= 2 else { return [] }
        return positional.dropFirst().compactMap { spec in
            var s = spec
            if s.hasPrefix("+") { s.removeFirst() }
            if let c = s.lastIndex(of: ":") { s = String(s[s.index(after: c)...]) }
            if s.hasPrefix("refs/heads/") { s = String(s.dropFirst("refs/heads/".count)) }
            return s
        }
    }

    private static func branchCreate(_ args: [String]) -> String? {
        let readOnly: Set<String> = ["-d", "-D", "--delete", "-m", "-M", "--move", "-c", "-C", "--copy", "-a", "--all", "-l", "--list",
                                     "-r", "--remotes", "--show-current", "-v", "-vv", "--contains", "--merged", "--no-merged"]
        if args.contains(where: { readOnly.contains($0) }) { return nil }
        return args.first { !$0.hasPrefix("-") }
    }
}
