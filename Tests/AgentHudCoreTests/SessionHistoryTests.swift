import Foundation
import Testing
@testable import AgentHudCore

@Suite struct SessionHistoryTests {
    func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        return home
    }

    func uuid() -> String { UUID().uuidString.lowercased() }

    func user(_ text: String, cwd: String = "/work/app", extra: String = "") -> String {
        let t = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        return #"{"type":"user","uuid":"\#(uuid())","isSidechain":false\#(extra),"cwd":"\#(cwd)","message":{"role":"user","content":"\#(t)"}}"#
    }
    func aiTitle(_ t: String) -> String { #"{"type":"ai-title","aiTitle":"\#(t)","sessionId":"x"}"# }

    @discardableResult
    func write(_ home: URL, folder: String = "-work-app", id: String? = nil, lines: [String], age: TimeInterval = 0,
               now: Date = Date()) throws -> String {
        let sid = id ?? uuid()
        let dir = home.appendingPathComponent(".claude/projects/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(sid).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return sid
    }

    @Test func newestFirstAndLimit() throws {
        let home = try makeHome()
        let a = try write(home, lines: [user("old")], age: 3000)
        let b = try write(home, lines: [user("new")], age: 10)
        let c = try write(home, lines: [user("middle")], age: 500)
        #expect(SessionHistory.recent(home: home).map(\.id) == [b, c, a])
        #expect(SessionHistory.recent(home: home, limit: 2).map(\.id) == [b, c])
        #expect(SessionHistory.recent(home: home, limit: 0).isEmpty)
    }

    @Test func missingFolderGivesNothing() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("nohome-\(UUID().uuidString)")
        #expect(SessionHistory.recent(home: home).isEmpty)
    }

    @Test func onlyTopLevelUuidFiles() throws {
        let home = try makeHome()
        let good = try write(home, lines: [user("real")])
        try write(home, id: "agent-1234abcd", lines: [user("agent file")])
        try write(home, id: "notes", lines: [user("other")])
        // Side transcripts live in <uuid>/subagents/.
        let sub = home.appendingPathComponent(".claude/projects/-work-app/\(good)/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data((user("sub", extra: "") + "\n").utf8).write(to: sub.appendingPathComponent("\(uuid()).jsonl"))
        #expect(SessionHistory.recent(home: home).map(\.id) == [good])
    }

    @Test func titlePrecedence() throws {
        let home = try makeHome()
        let both = try write(home, lines: [user("typed first"), aiTitle("Generated one"), aiTitle("Generated two")], age: 1)
        let typed = try write(home, lines: [user("typed only\nsecond line")], age: 2)
        try write(home, lines: [#"{"type":"mode","mode":"x"}"#, #"{"type":"queue-operation"}"#], age: 3)   // nothing: skipped
        let onlyTitle = try write(home, lines: [aiTitle("Title without messages")], age: 4)
        let r = SessionHistory.recent(home: home)
        #expect(r.map(\.id) == [both, typed, onlyTitle])
        #expect(r.map(\.title) == ["Generated two", "typed only", "Title without messages"])
    }

    @Test func untitledConstantAndLongTitle() throws {
        let home = try makeHome()
        try write(home, lines: [user(String(repeating: "x", count: 200))])
        let t = try #require(SessionHistory.recent(home: home).first).title
        #expect(t.count == 80 && t.hasSuffix("…"))
        #expect(SessionHistory.untitled == "Untitled session")
    }

    @Test func firstMessageRulesMatchTranscript() throws {
        let home = try makeHome()
        let lines = [
            user("meta text", extra: #","isMeta":true"#),
            user("<system-reminder>injected</system-reminder>"),
            user("<command-name>/clear</command-name>"),
            user("[Request interrupted by user]"),
            #"{"type":"user","uuid":"u1","cwd":"/work/app","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"ok"}]}}"#,
            #"{"type":"user","uuid":"u2","isSidechain":true,"cwd":"/work/app","message":{"role":"user","content":"side"}}"#,
            #"{"type":"assistant","uuid":"a1","cwd":"/work/app","message":{"role":"assistant","content":"hi"}}"#,
            #"{"type":"user","uuid":"u3","cwd":"/work/app","message":{"role":"user","content":[{"type":"text","text":"<system-reminder>x</system-reminder>"},{"type":"text","text":"  the real one  "}]}}"#,
            user("a later one"),
        ]
        try write(home, lines: lines)
        #expect(SessionHistory.recent(home: home).first?.title == "the real one")
    }

    @Test func wrapperOnlyFileIsSkipped() throws {
        let home = try makeHome()
        try write(home, lines: [user("<local-command-stdout>ok</local-command-stdout>"), user("<bash-input>ls</bash-input>")])
        #expect(SessionHistory.recent(home: home).isEmpty)
    }

    @Test func cwdComesFromTheFileNotTheFolderName() throws {
        let home = try makeHome()
        // "-work-my-app" could be /work/my/app or /work/my-app.
        try write(home, folder: "-work-my-app", lines: [#"{"type":"mode","mode":"x"}"#, user("hi", cwd: "/work/my-app")])
        let s = try #require(SessionHistory.recent(home: home).first)
        #expect(s.cwd == "/work/my-app")
    }

    @Test func garbageAndEmptyFilesAreTolerated() throws {
        let home = try makeHome()
        let ok = try write(home, lines: [user("fine")], age: 5)
        try write(home, lines: ["not json at all", "{broken", "\u{0}\u{1}"], age: 1)
        let dir = home.appendingPathComponent(".claude/projects/-work-app")
        try Data().write(to: dir.appendingPathComponent("\(uuid()).jsonl"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("\(uuid()).jsonl"), withIntermediateDirectories: false)
        #expect(SessionHistory.recent(home: home).map(\.id) == [ok])
    }

    @Test func bigFileIsReadPartially() throws {
        let home = try makeHome()
        let pad = #"{"type":"file-history-snapshot","blob":""# + String(repeating: "a", count: 9_000) + #""}"#
        var lines = [user("start of a big one")]
        for _ in 0..<600 { lines.append(pad) }       // about 5.4 MB
        lines.append(aiTitle("Late title"))
        let id = try write(home, lines: lines)
        let start = Date()
        let r = SessionHistory.recent(home: home)
        #expect(Date().timeIntervalSince(start) < 1)
        let s = try #require(r.first)
        #expect(s.id == id && s.title == "Late title" && s.sizeBytes > 5_000_000)
    }

    @Test func bigFileWithoutTitleUsesFirstMessage() throws {
        let home = try makeHome()
        let pad = #"{"type":"x","blob":""# + String(repeating: "a", count: 9_000) + #""}"#
        try write(home, lines: [user("only head")] + Array(repeating: pad, count: 20))
        #expect(SessionHistory.recent(home: home, headBytes: 10_000, tailBytes: 10_000).first?.title == "only head")
    }

    @Test func manyFilesOnlyNewestAreParsed() throws {
        let home = try makeHome()
        var ids: [String] = []
        for i in 0..<60 { ids.append(try write(home, lines: [user("m\(i)")], age: TimeInterval(i * 10))) }
        let r = SessionHistory.recent(home: home, limit: 5)
        #expect(r.map(\.id) == Array(ids.prefix(5)))
    }

    @Test func possiblyLiveBoundary() {
        let now = Date()
        func s(_ age: TimeInterval) -> PastSession {
            PastSession(id: "i", cwd: "/a", title: "t", lastActivity: now.addingTimeInterval(-age), sizeBytes: 1)
        }
        #expect(SessionHistory.isPossiblyLive(s(0), now: now))
        #expect(SessionHistory.isPossiblyLive(s(120), now: now))
        #expect(!SessionHistory.isPossiblyLive(s(120.5), now: now))
        #expect(SessionHistory.isPossiblyLive(s(200), now: now, window: 300))
    }

    @Test func relativeTimeWording() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 15))!
        func r(_ ago: TimeInterval) -> String { SessionHistory.relativeTime(now.addingTimeInterval(-ago), now: now, calendar: cal) }
        #expect(r(10) == "just now")
        #expect(r(300) == "5 min ago")
        #expect(r(3 * 3600) == "3 h ago")
        #expect(r(18 * 3600) == "yesterday")      // 21:00 the day before
        #expect(r(3 * 86400) == "3 days ago")
        #expect(r(20 * 86400) == "Nov 3")
        #expect(r(400 * 86400) == "Oct 19 2025")
    }
}
