import Foundation

/// One row of the mini chat built from a Claude Code transcript.
public struct ChatItem: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case user(String)                       // what the person typed
        case assistant(String)                  // assistant text (Markdown as written)
        case tool(name: String, summary: String, status: StepStatus)   // one tool call; status from its result (.running if none yet)
    }
    public let id: String        // stable across re-reads of a growing file
    public let time: Date?
    public let kind: Kind

    public init(id: String, time: Date?, kind: Kind) {
        self.id = id; self.time = time; self.kind = kind
    }
}

/// Reader for the JSONL transcript Claude Code appends to. Pure functions, no watching.
public enum Transcript {
    /// Last `limit` items of the main conversation. Reads at most `maxBytes` from the end of the file.
    public static func read(_ url: URL, limit: Int = 200, maxBytes: Int = 1_000_000) -> [ChatItem] {
        guard limit > 0, maxBytes > 0, let h = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return [] }
        let window = UInt64(maxBytes)
        var data: Data
        if size > window {
            // One extra byte before the window tells whether the window starts on a line boundary.
            let start = size - window - 1
            guard (try? h.seek(toOffset: start)) != nil, let d = try? h.read(upToCount: maxBytes + 1) else { return [] }
            // Drop everything up to and including the first newline: that line is complete or cut.
            guard let nl = d.firstIndex(of: 0x0A) else { return [] }
            data = d.subdata(in: d.index(after: nl)..<d.endIndex)
        } else {
            guard (try? h.seek(toOffset: 0)) != nil, let d = try? h.readToEnd() else { return [] }
            data = d
        }
        return parse(data, limit: limit)
    }

    public static func parse(_ data: Data, limit: Int = 200) -> [ChatItem] {
        guard limit > 0 else { return [] }
        let adapter = Adapters.adapter(for: .claude)
        var items: [ChatItem] = []
        var toolIndex: [String: Int] = [:]    // tool_use id -> index in items

        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let obj = try? JSONValue.parse(Data(line)), obj.objectValue != nil else { continue }
            guard obj["isSidechain"]?.boolValue != true, obj["isMeta"]?.boolValue != true else { continue }
            guard let type = obj["type"]?.stringValue, type == "user" || type == "assistant" else { continue }
            guard let uuid = obj["uuid"]?.stringValue, !uuid.isEmpty else { continue }
            let msg = obj["message"]
            let time = obj["timestamp"]?.stringValue.flatMap(parseDate)
            let content = msg?["content"]

            if type == "user" {
                if let s = content?.stringValue {
                    if let t = userText(s) { items.append(ChatItem(id: uuid, time: time, kind: .user(t))) }
                    continue
                }
                guard let blocks = content?.arrayValue else { continue }
                var texts: [String] = []
                for b in blocks {
                    switch b["type"]?.stringValue {
                    case "text":
                        if let t = b["text"]?.stringValue.flatMap(userText) { texts.append(t) }
                    case "tool_result":
                        if let id = b["tool_use_id"]?.stringValue, let i = toolIndex[id],
                           case .tool(let name, let summary, _) = items[i].kind {
                            let failed = b["is_error"]?.boolValue == true
                            items[i] = ChatItem(id: items[i].id, time: items[i].time,
                                                kind: .tool(name: name, summary: summary, status: failed ? .failed : .ok))
                        }
                    default: break    // images and unknown blocks are not shown
                    }
                }
                if !texts.isEmpty { items.append(ChatItem(id: uuid, time: time, kind: .user(texts.joined(separator: "\n")))) }
            } else {
                guard let blocks = content?.arrayValue else {
                    if let s = content?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        items.append(ChatItem(id: uuid, time: time, kind: .assistant(s)))
                    }
                    continue
                }
                var texts: [String] = []
                var firstTextIndex = 0
                func flush() {
                    guard !texts.isEmpty else { return }
                    items.append(ChatItem(id: "\(uuid)#\(firstTextIndex)", time: time, kind: .assistant(texts.joined(separator: "\n\n"))))
                    texts = []
                }
                for (i, b) in blocks.enumerated() {
                    switch b["type"]?.stringValue {
                    case "text":
                        guard let t = b["text"]?.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                        if texts.isEmpty { firstTextIndex = i }
                        texts.append(t)
                    case "tool_use":
                        flush()
                        guard let name = b["name"]?.stringValue, let id = b["id"]?.stringValue else { continue }
                        let summary = adapter.summarize(toolName: name, input: b["input"] ?? .null,
                                                        cwd: obj["cwd"]?.stringValue)
                        toolIndex[id] = items.count
                        items.append(ChatItem(id: id, time: time, kind: .tool(name: name, summary: summary, status: .running)))
                    case "thinking", "redacted_thinking":
                        continue    // does not break a run of text blocks
                    default:
                        flush()
                    }
                }
                flush()
            }
        }
        return items.count > limit ? Array(items.suffix(limit)) : items
    }

    // MARK: - Helpers

    /// Wrappers Claude Code injects as user turns; they are not what the person typed.
    private static let wrapperPrefixes = [
        "<system-reminder", "<command-name>", "<command-message>", "<command-args>",
        "<local-command-", "<task-notification", "<user-prompt-submit-hook", "<bash-input>",
        "<bash-stdout>", "<bash-stderr>", "[Request interrupted",
    ]

    private static func userText(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        for p in wrapperPrefixes where t.hasPrefix(p) { return nil }
        return s
    }

    // Formatters are costly to create; one pair is reused (they are only read after setup).
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private nonisolated(unsafe) static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ s: String) -> Date? {
        isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
