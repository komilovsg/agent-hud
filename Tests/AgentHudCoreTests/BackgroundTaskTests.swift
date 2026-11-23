import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Фоновые задачи

@Suite struct BackgroundTaskTests {
    let sid = "bg-session"
    var key: String { "claude:\(sid)" }

    func ev(_ dt: TimeInterval, _ body: AgentEvent.Body) -> AgentEvent {
        AgentEvent(kind: .claude, sessionId: sid, cwd: "/Users/dev/project", time: t0.addingTimeInterval(dt), body: body)
    }

    func shell(_ dt: TimeInterval, id: String?, use: String = "u1", bg: Bool = true) -> AgentEvent {
        var input: JSONValue = ["command": "sleep 1000"]
        if bg { input = ["command": "sleep 1000", "run_in_background": true] }
        return ev(dt, .toolFinished(toolName: "Bash", input: input, toolUseId: use, durationMs: 5, failed: false, backgroundId: id))
    }

    func agent(_ dt: TimeInterval, id: String?, use: String = "a1", bg: Bool = true, tool: String = "Agent") -> AgentEvent {
        let input: JSONValue = bg ? ["description": "helper", "run_in_background": true] : ["description": "helper"]
        return ev(dt, .toolFinished(toolName: tool, input: input, toolUseId: use, durationMs: 5, failed: false, backgroundId: id))
    }

    func stop(_ dt: TimeInterval, tool: String = "TaskStop", key k: String = "task_id", id: String) -> AgentEvent {
        ev(dt, .toolFinished(toolName: tool, input: .object(JSONObject([JSONObject.Entry(k, .string(id))])), toolUseId: "s\(dt)", durationMs: 1, failed: false))
    }

    func tasks(_ st: SessionStore) -> [BackgroundTask] { st.session(key)?.backgroundTasks ?? [] }

    @Test func adapterExtractsBackgroundIds() throws {
        let sh = try #require(events(try message("PostToolUse-Bash-background")).first)
        guard case .toolFinished("Bash", _, _, _, _, let a) = sh.body else { Issue.record("\(sh.body)"); return }
        #expect(a == "bgtask1")
        let ag = try #require(events(try message("PostToolUse-Agent-background")).first)
        guard case .toolFinished("Agent", _, _, _, _, let b) = ag.body else { Issue.record("\(ag.body)"); return }
        #expect(b == "agentsyn1")
        // Обычный Bash без фонового id.
        let plain = try #require(events(try message("PostToolUse-Bash")).first)
        guard case .toolFinished(_, _, _, _, _, let c) = plain.body else { Issue.record("\(plain.body)"); return }
        #expect(c == nil)
    }

    @Test func shellStartIsListed() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1"))
        let t = tasks(st)
        #expect(t.count == 1)
        #expect(t[0].id == "b1")
        #expect(t[0].kind == .shell)
        #expect(t[0].title.hasPrefix("$ "))
        #expect(t[0].startedAt == t0)
    }

    @Test func missingIdFallsBackToToolUseId() {
        var st = SessionStore()
        st.apply(shell(0, id: nil, use: "toolu_x"))
        #expect(tasks(st).map(\.id) == ["toolu_x"])
    }

    @Test func stopByIdRemoves() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1"))
        st.apply(shell(1, id: "b2", use: "u2"))
        st.apply(stop(2, id: "b1"))
        #expect(tasks(st).map(\.id) == ["b2"])
        st.apply(stop(3, tool: "KillShell", key: "shell_id", id: "b2"))
        #expect(tasks(st).isEmpty)
    }

    @Test func unknownStopRemovesNothing() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1"))
        st.apply(stop(1, id: "nope"))
        #expect(tasks(st).map(\.id) == ["b1"])
    }

    @Test func backgroundAgentRemovedBySubagentStop() {
        var st = SessionStore()
        st.apply(agent(0, id: "ag1"))
        #expect(tasks(st).first?.kind == .agent)
        #expect(tasks(st).first?.agentId == "ag1")
        st.apply(ev(1, .subagentStopped(agentId: "other")))
        #expect(tasks(st).count == 1)
        st.apply(ev(2, .subagentStopped(agentId: "ag1")))
        #expect(tasks(st).isEmpty)
    }

    @Test func oldTaskToolNameCounts() {
        var st = SessionStore()
        st.apply(agent(0, id: "ag1", tool: "Task"))
        #expect(tasks(st).count == 1)
    }

    @Test func sessionEndClears() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1"))
        st.apply(agent(1, id: "ag1"))
        st.apply(ev(2, .sessionEnded(reason: nil)))
        #expect(tasks(st).isEmpty)
    }

    @Test func foregroundCallsAreNeverListed() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1", bg: false))
        st.apply(agent(1, id: "ag1", bg: false))
        st.apply(ev(2, .toolFinished(toolName: "Read", input: ["run_in_background": true], toolUseId: "r", durationMs: 1, failed: false)))
        #expect(tasks(st).isEmpty)
    }

    @Test func failedStartIsNotListed() {
        var st = SessionStore()
        st.apply(ev(0, .toolFinished(toolName: "Bash", input: ["command": "x", "run_in_background": true],
                                     toolUseId: "u", durationMs: 1, failed: true, backgroundId: "b1")))
        #expect(tasks(st).isEmpty)
    }

    @Test func ageAndHungBoundary() {
        let task = BackgroundTask(id: "b", kind: .shell, title: "$ x", startedAt: t0)
        #expect(BackgroundTask.hungAfter == 3600)
        #expect(task.age(at: t0.addingTimeInterval(90)) == 90)
        #expect(!task.isHung(at: t0.addingTimeInterval(59 * 60 + 59)))
        #expect(task.isHung(at: t0.addingTimeInterval(60 * 60)))
        #expect(task.age(at: t0.addingTimeInterval(-5)) == 0)
    }

    @Test func sessionHelpers() {
        var st = SessionStore()
        st.apply(shell(0, id: "old"))
        st.apply(shell(3000, id: "new", use: "u2"))
        let s = st.session(key)!
        let now = t0.addingTimeInterval(3700)
        #expect(s.hungCount(at: now) == 1)
        #expect(s.oldestBackground(at: now)?.id == "old")
        #expect(s.hungCount(at: t0.addingTimeInterval(3599)) == 0)
        #expect(SessionStore().session(key)?.oldestBackground(at: now) == nil)
    }

    @Test func capKeepsNewest50() {
        var st = SessionStore()
        for i in 0..<55 { st.apply(shell(Double(i), id: "b\(i)", use: "u\(i)")) }
        let t = tasks(st)
        #expect(t.count == 50)
        #expect(t.first?.id == "b5")
        #expect(t.last?.id == "b54")
    }

    @Test func duplicateEventsAreIdempotent() {
        var st = SessionStore()
        st.apply(shell(0, id: "b1"))
        st.apply(shell(5, id: "b1"))
        #expect(tasks(st).count == 1)
        #expect(tasks(st).first?.startedAt == t0)
    }
}
