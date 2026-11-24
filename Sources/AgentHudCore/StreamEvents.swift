import Foundation

/// One thing learned from a line of the CLI's `stream-json` output.
public enum StreamEvent: Equatable, Sendable {
    /// The CLI reported the session it runs (`system` / `init`).
    case initialized(sessionId: String?, model: String?)
    /// New or changed chat rows; a row with a known id replaces the old one.
    case items([ChatItem])
    /// Text of the reply that is being written right now; empty when nothing is streaming.
    case partialText(String)
    case turnFinished(success: Bool, costUSD: Double?, error: String?)
    /// A retry, a denied tool call or another short remark for the person.
    case notice(String)
}

/// Turns stdout lines of a session run by this app into chat rows. Tolerant like `Transcript`:
/// a malformed line, an unknown type or a missing field yields no events and never fails.
public struct StreamParser: Sendable {
    private struct ToolCall: Sendable { var name: String; var summary: String }

    private let cwd: String?
    private var tools: [String: ToolCall] = [:]   // tool_use id -> what was shown for it
    private var partial = ""
    private var unnamed = 0                        // counter for lines without their own id

    public init(cwd: String? = nil) { self.cwd = cwd }

    public mutating func feed(_ line: String) -> [StreamEvent] { feed(Data(line.utf8)) }

    public mutating func feed(_ line: Data) -> [StreamEvent] {
        guard let obj = try? JSONValue.parse(line), obj.objectValue != nil,
              let type = obj["type"]?.stringValue else { return [] }
        // Messages produced inside a subagent belong to its own conversation, not to the main chat.
        let nested = obj["parent_tool_use_id"]?.stringValue?.isEmpty == false
        switch type {
        case "system": return system(obj)
        case "stream_event": return nested ? [] : streamEvent(obj["event"])
        case "assistant": return nested ? [] : assistant(obj)
        case "user": return toolResults(obj)
        case "result": return result(obj)
        default: return []
        }
    }

    // MARK: - Line kinds

    private func system(_ obj: JSONValue) -> [StreamEvent] {
        switch obj["subtype"]?.stringValue {
        case "init":
            return [.initialized(sessionId: obj["session_id"]?.stringValue, model: obj["model"]?.stringValue)]
        case "api_retry":
            var text = "Retrying the request"
            if let n = obj["attempt"]?.intValue {
                text += obj["max_retries"]?.intValue.map { " (attempt \(n) of \($0))" } ?? " (attempt \(n))"
            }
            if let why = obj["error"]?.stringValue, !why.isEmpty { text += ": \(Self.oneLine(why))" }
            return [.notice(text)]
        case "permission_denied":
            if let name = obj["tool_name"]?.stringValue {
                let summary = Adapters.adapter(for: .claude).summarize(toolName: name, input: obj["tool_input"] ?? .null, cwd: cwd)
                return [.notice("Denied: \(summary)")]
            }
            if let m = obj["message"]?.stringValue, !m.isEmpty { return [.notice("Denied: \(Self.oneLine(m))")] }
            return [.notice("A tool call was denied")]
        default:
            return []
        }
    }

    private mutating func streamEvent(_ event: JSONValue?) -> [StreamEvent] {
        switch event?["type"]?.stringValue {
        case "message_start":
            guard !partial.isEmpty else { return [] }
            partial = ""
            return [.partialText("")]
        case "content_block_delta":
            guard event?["delta"]?["type"]?.stringValue == "text_delta",
                  let t = event?["delta"]?["text"]?.stringValue, !t.isEmpty else { return [] }
            partial += t
            return [.partialText(partial)]
        default:
            return []
        }
    }

    private mutating func assistant(_ obj: JSONValue) -> [StreamEvent] {
        let content = obj["message"]?["content"]
        let base: String
        if let u = obj["uuid"]?.stringValue, !u.isEmpty {
            base = u
        } else {
            unnamed += 1
            base = "\(obj["message"]?["id"]?.stringValue ?? "message")-\(unnamed)"
        }
        var out: [ChatItem] = []
        var sawText = false
        if let s = content?.stringValue {
            if !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(ChatItem(id: "\(base)#0", time: nil, kind: .assistant(s)))
                sawText = true
            }
        } else if let blocks = content?.arrayValue {
            let adapter = Adapters.adapter(for: .claude)
            var texts: [String] = []
            var firstTextIndex = 0
            func flush() {
                guard !texts.isEmpty else { return }
                out.append(ChatItem(id: "\(base)#\(firstTextIndex)", time: nil, kind: .assistant(texts.joined(separator: "\n\n"))))
                texts = []
            }
            for (i, b) in blocks.enumerated() {
                switch b["type"]?.stringValue {
                case "text":
                    guard let t = b["text"]?.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    if texts.isEmpty { firstTextIndex = i }
                    texts.append(t)
                    sawText = true
                case "tool_use":
                    flush()
                    guard let name = b["name"]?.stringValue, let id = b["id"]?.stringValue else { continue }
                    let summary = adapter.summarize(toolName: name, input: b["input"] ?? .null, cwd: cwd)
                    // A repeated line must not turn a finished call back into a running one.
                    guard tools[id] == nil else { continue }
                    tools[id] = ToolCall(name: name, summary: summary)
                    out.append(ChatItem(id: id, time: nil, kind: .tool(name: name, summary: summary, status: .running)))
                case "thinking", "redacted_thinking":
                    continue    // does not break a run of text blocks
                default:
                    flush()
                }
            }
            flush()
        }
        var events: [StreamEvent] = []
        if !out.isEmpty { events.append(.items(out)) }
        // The finished text replaces its streamed preview.
        if sawText, !partial.isEmpty {
            partial = ""
            events.append(.partialText(""))
        }
        return events
    }

    private func toolResults(_ obj: JSONValue) -> [StreamEvent] {
        guard let blocks = obj["message"]?["content"]?.arrayValue else { return [] }
        var out: [ChatItem] = []
        for b in blocks where b["type"]?.stringValue == "tool_result" {
            guard let id = b["tool_use_id"]?.stringValue, let call = tools[id] else { continue }
            let failed = b["is_error"]?.boolValue == true
            out.append(ChatItem(id: id, time: nil, kind: .tool(name: call.name, summary: call.summary, status: failed ? .failed : .ok)))
        }
        return out.isEmpty ? [] : [.items(out)]
    }

    private mutating func result(_ obj: JSONValue) -> [StreamEvent] {
        let subtype = obj["subtype"]?.stringValue
        let success = subtype == "success" && obj["is_error"]?.boolValue != true
        var error: String?
        if !success {
            error = obj["result"]?.stringValue ?? obj["error"]?.stringValue
                ?? obj["errors"]?.arrayValue?.compactMap(\.stringValue).first ?? subtype
            error = error.map(Self.oneLine)
        }
        var events: [StreamEvent] = []
        if !partial.isEmpty {
            partial = ""
            events.append(.partialText(""))
        }
        events.append(.turnFinished(success: success, costUSD: obj["total_cost_usd"]?.doubleValue, error: error))
        return events
    }

    private static func oneLine(_ s: String) -> String {
        let t = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return t.count > 300 ? String(t.prefix(299)) + "…" : t
    }

    // MARK: - Input and merging

    /// One user turn for the CLI's stdin: a single JSON line with a trailing newline.
    /// The text only ever travels as a JSON string, so its content cannot change the line's structure.
    public static func userLine(_ text: String) -> Data {
        let line: JSONValue = .object(JSONObject([
            "type": "user",
            "message": .object(JSONObject(["role": "user", "content": .string(text)])),
            "parent_tool_use_id": .null,
        ]))
        return Data((line.compact() + "\n").utf8)
    }

    /// Applies `.items` to a chat: a known id is replaced in place, a new one is appended. At most `limit` rows are kept.
    public static func merge(_ updates: [ChatItem], into items: inout [ChatItem], limit: Int = 400) {
        for u in updates {
            if let i = items.lastIndex(where: { $0.id == u.id }) { items[i] = u } else { items.append(u) }
        }
        if items.count > limit { items.removeFirst(items.count - limit) }
    }
}
