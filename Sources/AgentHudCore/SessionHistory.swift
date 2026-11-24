import Foundation

/// A finished (or possibly still open) conversation found in the Claude Code transcript folder.
public struct PastSession: Identifiable, Equatable, Sendable {
    public let id: String            // session uuid
    public let cwd: String           // project directory taken from the transcript
    public let title: String
    public let lastActivity: Date    // file modification date
    public let sizeBytes: Int

    public init(id: String, cwd: String, title: String, lastActivity: Date, sizeBytes: Int) {
        self.id = id; self.cwd = cwd; self.title = title; self.lastActivity = lastActivity; self.sizeBytes = sizeBytes
    }
}

/// Lists past sessions from `~/.claude/projects/<encoded cwd>/<uuid>.jsonl`. Pure reads, no caching, no watching.
public enum SessionHistory {
    public static let untitled = "Untitled session"
    static let titleLimit = 80

    /// Wrappers injected as user turns; same list as the chat reader, which keeps its own private.
    private static let wrapperPrefixes = [
        "<system-reminder", "<command-name>", "<command-message>", "<command-args>",
        "<local-command-", "<task-notification", "<user-prompt-submit-hook", "<bash-input>",
        "<bash-stdout>", "<bash-stderr>", "[Request interrupted",
    ]

    /// Most recent first. Reads at most `headBytes` from the start (and, for a title entry near the end,
    /// `tailBytes` from the end) of each file. Only the newest `limit * 2` files by date are parsed.
    public static func recent(home: URL, limit: Int = 40, headBytes: Int = 64_000, tailBytes: Int = 64_000) -> [PastSession] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }

        struct Candidate { let url: URL; let id: String; let date: Date; let size: Int }
        var found: [Candidate] = []
        for folder in folders {
            guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for f in files where f.pathExtension == "jsonl" {
                let id = f.deletingPathExtension().lastPathComponent
                guard isSessionId(id), let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                found.append(Candidate(url: f, id: id.lowercased(), date: v.contentModificationDate ?? .distantPast, size: v.fileSize ?? 0))
            }
        }
        found.sort { $0.date > $1.date }

        var out: [PastSession] = []
        var seen = Set<String>()
        for c in found.prefix(limit * 2) where !seen.contains(c.id) {
            guard let info = inspect(c.url, size: c.size, headBytes: headBytes, tailBytes: tailBytes),
                  let title = info.title ?? info.firstMessage else { continue }
            seen.insert(c.id)
            out.append(PastSession(id: c.id, cwd: info.cwd, title: title, lastActivity: c.date, sizeBytes: c.size))
            if out.count == limit { break }
        }
        return out
    }

    /// The file was written within `window` of `now`: another process may still be using the session.
    public static func isPossiblyLive(_ s: PastSession, now: Date, window: TimeInterval = 120) -> Bool {
        now.timeIntervalSince(s.lastActivity) <= window
    }

    /// "just now", "5 min ago", "3 h ago", "yesterday", "4 days ago", then a plain date.
    public static func relativeTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "\(Int(seconds / 3600)) h ago" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        return f.string(from: date)
    }

    // MARK: - Reading one file

    private struct Info { var cwd = ""; var title: String?; var firstMessage: String? }

    private static func isSessionId(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    private static func inspect(_ url: URL, size: Int, headBytes: Int, tailBytes: Int) -> Info? {
        guard size > 0, headBytes > 0, let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: 0)) != nil, var head = try? h.read(upToCount: headBytes), !head.isEmpty else { return nil }
        let headIsWhole = size <= head.count
        // A window that ends mid-line: the last line is incomplete.
        if !headIsWhole, let nl = head.lastIndex(of: 0x0A) { head = head.subdata(in: head.startIndex..<nl) }

        var info = Info()
        for line in head.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if info.cwd.isEmpty || info.firstMessage == nil {
                guard let obj = parse(line) else { continue }
                if info.cwd.isEmpty, obj["isSidechain"]?.boolValue != true, let c = obj["cwd"]?.stringValue, !c.isEmpty { info.cwd = c }
                if info.firstMessage == nil, let m = firstUserMessage(obj) { info.firstMessage = m }
                if let t = title(in: obj) { info.title = t }
            } else if let t = titleLine(line) {
                info.title = t
            }
        }

        // The generated title is written late: the last one near the end wins.
        if !headIsWhole, tailBytes > 0 {
            let want = min(tailBytes, size)
            if (try? h.seek(toOffset: UInt64(size - want))) != nil, let tail = try? h.read(upToCount: want) {
                // The first line of the window may be cut.
                let body = tail.firstIndex(of: 0x0A).map { tail.subdata(in: tail.index(after: $0)..<tail.endIndex) } ?? Data()
                for line in body.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    if let t = titleLine(line) { info.title = t }
                }
            }
        }
        return info
    }

    private static func parse(_ line: Data.SubSequence) -> JSONValue? {
        guard let v = try? JSONValue.parse(Data(line)), v.objectValue != nil else { return nil }
        return v
    }

    private static func titleLine(_ line: Data.SubSequence) -> String? {
        // Cheap filter first: most lines are large tool results.
        guard line.count < 4096, line.range(of: Data("\"ai-title\"".utf8)) != nil || line.range(of: Data("\"summary\"".utf8)) != nil,
              let obj = parse(line) else { return nil }
        return title(in: obj)
    }

    private static func title(in obj: JSONValue) -> String? {
        let raw: String?
        switch obj["type"]?.stringValue {
        case "ai-title": raw = obj["aiTitle"]?.stringValue
        case "summary": raw = obj["summary"]?.stringValue
        default: return nil
        }
        return raw.flatMap(firstLine)
    }

    /// The first real thing the person typed, by the same rules as the chat reader.
    private static func firstUserMessage(_ obj: JSONValue) -> String? {
        guard obj["type"]?.stringValue == "user", obj["isSidechain"]?.boolValue != true, obj["isMeta"]?.boolValue != true else { return nil }
        let content = obj["message"]?["content"]
        if let s = content?.stringValue { return userText(s).flatMap(firstLine) }
        for b in content?.arrayValue ?? [] where b["type"]?.stringValue == "text" {
            if let t = b["text"]?.stringValue.flatMap(userText).flatMap(firstLine) { return t }
        }
        return nil
    }

    private static func userText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        for p in wrapperPrefixes where t.hasPrefix(p) { return nil }
        return t
    }

    /// First non-empty line, at most `titleLimit` characters.
    static func firstLine(_ s: String) -> String? {
        guard let line = s.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) else { return nil }
        return line.count > titleLimit ? String(line.prefix(titleLimit - 1)) + "…" : line
    }
}
