import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Transcript reader

@Suite struct TranscriptTests {
    func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/claude/\(name)", withExtension: "jsonl"))
        return try Data(contentsOf: url)
    }

    func line(_ type: String, uuid: String, content: String, extra: String = "") -> String {
        #"{"type":"\#(type)","uuid":"\#(uuid)","isSidechain":false\#(extra),"timestamp":"2026-01-01T10:00:00.000Z","message":{"role":"\#(type)","content":\#(content)}}"#
    }

    func userLine(_ uuid: String, _ text: String) -> String { line("user", uuid: uuid, content: "\"\(text)\"") }
    func assistantLine(_ uuid: String, _ text: String) -> String {
        line("assistant", uuid: uuid, content: #"[{"type":"text","text":"\#(text)"}]"#)
    }
    func toolUseLine(_ uuid: String, _ id: String) -> String {
        line("assistant", uuid: uuid, content: #"[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"ls"}}]"#)
    }
    func toolResultLine(_ uuid: String, _ id: String) -> String {
        line("user", uuid: uuid, content: #"[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok","is_error":false}]"#)
    }
    func data(_ lines: [String]) -> Data { Data((lines.joined(separator: "\n") + "\n").utf8) }

    func tempFile(_ d: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try d.write(to: url)
        return url
    }

    @Test func basicConversation() throws {
        let items = Transcript.parse(try fixtureData("transcript-basic"))
        let kinds = items.map(\.kind)
        #expect(kinds == [
            .user("fix the login form"),
            .assistant("Looking at the form."),
            .assistant("Second paragraph.\n\nThird."),
            .tool(name: "Read", summary: "Read src/Login.tsx", status: .ok),
            .tool(name: "Bash", summary: "$ npm test", status: .failed),
            .user("now add a test"),
            .assistant("Adding it."),
            .tool(name: "Edit", summary: "Edit src/Login.test.tsx", status: .running),
        ])
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(items[3].id == "toolu_read")
        #expect(items[0].time != nil)
    }

    @Test func skipsNoise() throws {
        let text = items(try fixtureData("transcript-basic")).joined(separator: "|")
        for bad in ["sidechain", "hmm", "system-reminder", "/clear", "file body", "cut off"] {
            #expect(!text.contains(bad), "\(bad)")
        }
    }

    func items(_ d: Data) -> [String] {
        Transcript.parse(d).map {
            switch $0.kind {
            case .user(let s), .assistant(let s): return s
            case .tool(_, let s, _): return s
            }
        }
    }

    @Test func toolResultOnlyUserEntryIsNotAMessage() {
        let d = data([toolUseLine("a1", "t1"), toolResultLine("u1", "t1")])
        let r = Transcript.parse(d)
        #expect(r.count == 1)
        #expect(r[0].kind == .tool(name: "Bash", summary: "$ ls", status: .ok))
    }

    @Test func contentAsStringAndAsBlocks() {
        let d = data([
            userLine("u1", "plain string"),
            line("user", uuid: "u2", content: #"[{"type":"text","text":"block array"}]"#),
        ])
        #expect(Transcript.parse(d).map(\.kind) == [.user("plain string"), .user("block array")])
    }

    @Test func metaAndWrappersSkipped() {
        let d = data([
            line("user", uuid: "m1", content: "\"hidden\"", extra: #","isMeta":true"#),
            userLine("w1", "<system-reminder>x</system-reminder>"),
            userLine("w2", "<local-command-caveat>x</local-command-caveat>"),
            userLine("w3", "<task-notification>x</task-notification>"),
            userLine("u1", "real"),
        ])
        #expect(Transcript.parse(d).map(\.kind) == [.user("real")])
    }

    @Test func malformedAndTruncatedLines() {
        var raw = data(["{not json", "[]", "42", "{}", #"{"type":"user"}"#, #"{"type":"user","uuid":"x","message":5}"#,
                        #"{"type":"user","uuid":"y","message":{"content":[1,"a",null]}}"#,
                        #"{"type":"weird","uuid":"z"}"#, userLine("u1", "ok")])
        raw.append(Data(#"{"type":"assistant","uuid":"cut","message":{"content":[{"type":"te"#.utf8))
        #expect(Transcript.parse(raw).map(\.kind) == [.user("ok")])
        #expect(Transcript.parse(Data()).isEmpty)
        #expect(Transcript.parse(Data([0xFF, 0xFE, 0x0A, 0x00])).isEmpty)
    }

    @Test func limitKeepsLast() {
        let d = data((1...10).map { userLine("u\($0)", "m\($0)") })
        #expect(Transcript.parse(d, limit: 3).map(\.kind) == [.user("m8"), .user("m9"), .user("m10")])
        #expect(Transcript.parse(d, limit: 0).isEmpty)
        #expect(Transcript.parse(d, limit: 100).count == 10)
    }

    @Test func idsStableWhenFileGrows() {
        let base = [userLine("u1", "a"), assistantLine("a1", "b"), toolUseLine("a2", "t1")]
        let first = Transcript.parse(data(base))
        let grown = Transcript.parse(data(base + [toolResultLine("u2", "t1"), assistantLine("a3", "c")]))
        #expect(first.map(\.id) == Array(grown.map(\.id).prefix(3)))
        #expect(first[2].kind == .tool(name: "Bash", summary: "$ ls", status: .running))
        #expect(grown[2].kind == .tool(name: "Bash", summary: "$ ls", status: .ok))
    }

    @Test func missingFileIsEmpty() {
        #expect(Transcript.read(URL(fileURLWithPath: "/nonexistent/acme-web/none.jsonl")).isEmpty)
    }

    @Test func tailWindowCutsMidLineAndDropsOrphanResult() throws {
        var lines = [userLine("u0", "first")]
        lines.append(toolUseLine("a1", "t1"))
        lines.append(toolResultLine("u1", "t1"))
        lines.append(userLine("u2", "second"))
        lines.append(assistantLine("a2", "third"))
        let all = data(lines)
        let url = try tempFile(all)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Transcript.read(url).count == 4)

        // Window starts in the middle of the tool_use line: the result is an orphan and is ignored.
        let tailBytes = lines.suffix(3).map { $0.utf8.count + 1 }.reduce(0, +) + 5
        let r = Transcript.read(url, maxBytes: tailBytes)
        #expect(r.map(\.kind) == [.user("second"), .assistant("third")])

        // Window starting exactly on a line boundary keeps that line.
        let exact = lines.suffix(2).map { $0.utf8.count + 1 }.reduce(0, +)
        #expect(Transcript.read(url, maxBytes: exact).count == 2)
        // Tiny window: nothing complete, no crash.
        #expect(Transcript.read(url, maxBytes: 3).isEmpty)
    }

    @Test func largeFileReadsOnlyTheWindow() throws {
        var s = ""
        var i = 0
        while s.utf8.count < 5_000_000 {
            s += userLine("u\(i)", String(repeating: "x", count: 200)) + "\n"
            i += 1
        }
        let url = try tempFile(Data(s.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let t = Date()
        let r = Transcript.read(url)
        let elapsed = Date().timeIntervalSince(t)
        #expect(r.count == 200)
        #expect(r.last?.id == "u\(i - 1)")
        #expect(elapsed < 2)
    }
}
