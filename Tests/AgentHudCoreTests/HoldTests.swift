import Darwin
import Foundation
import Testing
@testable import AgentHudCore

// Pause and Stop: a held session's tool calls wait in their `gate` hooks until released.

@Suite struct HoldStoreTests {
    let key = "claude:11111111-2222-3333-4444-555555555555"

    /// A store with one live session.
    func store() throws -> SessionStore {
        var st = SessionStore()
        for name in ["SessionStart", "UserPromptSubmit"] {
            for e in events(try message(name)) { st.apply(e) }
        }
        return st
    }

    /// A gate message goes through the same path as in the app: the tool event first, then the gate itself.
    @discardableResult
    func gate(_ st: inout SessionStore, _ rid: String, at t: Date = t0, agentId: String? = nil,
              deadline: Date? = nil) throws -> Bool {
        var m = try message("PreToolUse-Bash", mode: .gate, rid: rid)
        m.payload["tool_use_id"] = .string("tool-\(rid)")
        if let agentId { m.payload["agent_id"] = .string(agentId) }
        var answerNow = true
        for e in events(m, at: t) {
            st.apply(e)
            guard case .toolStarted(let tool, let input, _) = e.body else { continue }
            answerNow = st.gateArrived(sessionKey: e.sessionKey, requestId: rid,
                                       summary: adapter.summarize(toolName: tool, input: input, cwd: nil),
                                       agentId: e.agentId, deadline: deadline ?? t.addingTimeInterval(86395), now: t)
        }
        return answerNow
    }

    @Test func gateWithoutHoldIsAnsweredAtOnce() throws {
        var st = try store()
        #expect(try gate(&st, "g1") == true)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
        #expect(st.session(key)?.hold == nil)
        #expect(st.session(key)?.state == .working)
    }

    @Test func gateForUnknownSessionIsAnsweredAtOnce() {
        var st = SessionStore()
        let answerNow = st.gateArrived(sessionKey: "claude:nobody", requestId: "g", summary: "x", agentId: nil,
                                       deadline: t0.addingTimeInterval(10), now: t0)
        #expect(answerNow)
        #expect(st.sessions.isEmpty)
    }

    @Test func heldCallWaitsAndIsReleasedOnce() throws {
        var st = try store()
        #expect(st.hold(sessionKey: key, kind: .stop, now: t0) == true)
        #expect(try gate(&st, "g1") == false)
        let s = try #require(st.session(key))
        #expect(s.heldCalls.map(\.id) == ["g1"])
        #expect(s.heldCalls.first?.summary.hasPrefix("$ node -e") == true)
        #expect(s.state == .stopped)
        // The same payload still produced the usual step.
        #expect(s.steps.last?.id == "tool-g1")

        #expect(st.release(sessionKey: key) == ["g1"])
        #expect(st.release(sessionKey: key).isEmpty)
        #expect(st.session(key)?.hold == nil)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
        #expect(st.session(key)?.state == .working)
        // After the release the next call is not held.
        #expect(try gate(&st, "g2") == true)
    }

    @Test func pauseEndsByItselfAfterTheLimit() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .pause, now: t0)
        #expect(st.session(key)?.hold?.until == t0.addingTimeInterval(900))
        #expect(st.session(key)?.state == .paused)
        try gate(&st, "g1", at: t0.addingTimeInterval(1))

        #expect(st.tick(now: t0.addingTimeInterval(899), autoHideDoneAfter: nil).isEmpty)
        #expect(st.session(key)?.hold != nil)
        #expect(st.tick(now: t0.addingTimeInterval(900), autoHideDoneAfter: nil) == ["g1"])
        #expect(st.session(key)?.hold == nil)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
        #expect(st.tick(now: t0.addingTimeInterval(901), autoHideDoneAfter: nil).isEmpty)
    }

    @Test func pauseWithNothingHeldAlsoEnds() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .pause, now: t0)
        #expect(st.tick(now: t0.addingTimeInterval(900), autoHideDoneAfter: nil).isEmpty)
        #expect(st.session(key)?.hold == nil)
    }

    @Test func stopNeverExpiresByItself() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        #expect(st.session(key)?.hold?.until == nil)
        try gate(&st, "g1")
        for after in [900.0, 3600, 80000] {
            #expect(st.tick(now: t0.addingTimeInterval(after), autoHideDoneAfter: 60).isEmpty)
        }
        #expect(st.session(key)?.hold?.kind == .stop)
        #expect(st.session(key)?.heldCalls.map(\.id) == ["g1"])
        #expect(st.session(key)?.hidden == false)
    }

    @Test func heldCallIsForgottenAfterItsHookDeadline() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        try gate(&st, "g1", deadline: t0.addingTimeInterval(100))
        #expect(st.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: nil).isEmpty)
        #expect(st.session(key)?.heldCalls.count == 1)
        // The hook has left by itself: nothing to answer, and the session stays stopped.
        #expect(st.tick(now: t0.addingTimeInterval(102), autoHideDoneAfter: nil).isEmpty)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
        #expect(st.session(key)?.hold?.kind == .stop)
    }

    @Test func subagentCallsAreHeldAndAllReleased() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        #expect(try gate(&st, "g1") == false)
        #expect(try gate(&st, "g2", agentId: "ag1") == false)
        #expect(try gate(&st, "g3", agentId: "ag2") == false)
        // The same hook reported twice is one call.
        #expect(try gate(&st, "g3", agentId: "ag2") == false)
        let s = try #require(st.session(key))
        #expect(s.heldCalls.map(\.id) == ["g1", "g2", "g3"])
        #expect(s.heldCalls.map(\.agentId) == [nil, "ag1", "ag2"])
        #expect(st.release(sessionKey: key) == ["g1", "g2", "g3"])
    }

    @Test func connectionCloseRemovesHeldCall() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .pause, now: t0)
        try gate(&st, "g1")
        try gate(&st, "g2", agentId: "ag1")
        st.connectionClosed("g1", now: t0.addingTimeInterval(3))
        #expect(st.session(key)?.heldCalls.map(\.id) == ["g2"])
        #expect(st.session(key)?.hold?.kind == .pause)
        #expect(st.release(sessionKey: key) == ["g2"])
    }

    @Test func sessionEndReleases() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        try gate(&st, "g1")
        var p = try fixture("Stop"); p["hook_event_name"] = "SessionEnd"
        var released: [String] = []
        for e in events(HookMessage(agent: .claude, mode: .event, requestId: "z", deadline: nil, host: HostInfo(), payload: p)) {
            released += st.apply(e)
        }
        #expect(released == ["g1"])
        #expect(st.session(key)?.hold == nil)
        #expect(st.session(key)?.state == .ended)
        // An ended session cannot be held.
        #expect(st.hold(sessionKey: key, kind: .stop, now: t0) == false)
        #expect(try gate(&st, "g2") == true)
        #expect(st.session(key)?.heldCalls.isEmpty == true)
    }

    @Test func deadAgentProcessReleases() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        try gate(&st, "g1")
        #expect(st.markEnded(key, now: t0.addingTimeInterval(9)) == ["g1"])
        #expect(st.session(key)?.hold == nil)
    }

    @Test func serviceSessionReleases() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        try gate(&st, "g1")
        let released = st.apply(AgentEvent(kind: .claude, sessionId: "11111111-2222-3333-4444-555555555555",
                                           time: t0, body: .internalSession))
        #expect(released == ["g1"])
        #expect(st.session(key) == nil)
        // Its later gates are answered at once.
        #expect(try gate(&st, "g2") == true)
    }

    @Test func appStopReleasesEverything() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .stop, now: t0)
        try gate(&st, "g1")
        try gate(&st, "g2", agentId: "ag1")
        // A second session, paused.
        let other = AgentEvent(kind: .claude, sessionId: "other", cwd: "/p", time: t0, body: .promptSubmitted("hi"))
        st.apply(other)
        st.hold(sessionKey: other.sessionKey, kind: .pause, now: t0)
        let answerNow = st.gateArrived(sessionKey: other.sessionKey, requestId: "o1", summary: "Read a", agentId: nil,
                                       deadline: t0.addingTimeInterval(500), now: t0)
        #expect(!answerNow)

        #expect(st.releaseAll() == ["g1", "g2", "o1"])
        #expect(st.sessions.values.allSatisfy { $0.hold == nil && $0.heldCalls.isEmpty })
        #expect(st.releaseAll().isEmpty)
    }

    @Test func supportsHoldTurnsOnWithTheFirstGate() throws {
        var st = try store()
        #expect(st.session(key)?.supportsHold == false)
        // A plain PreToolUse event (hooks from before the update) does not count.
        for e in events(try message("PreToolUse-Bash")) { st.apply(e) }
        #expect(st.session(key)?.supportsHold == false)
        try gate(&st, "g1")
        #expect(st.session(key)?.supportsHold == true)
    }

    @Test func switchingKindKeepsHeldCalls() throws {
        var st = try store()
        st.hold(sessionKey: key, kind: .pause, now: t0)
        try gate(&st, "g1")
        st.hold(sessionKey: key, kind: .stop, now: t0.addingTimeInterval(60))
        var s = try #require(st.session(key))
        #expect(s.hold == Hold(kind: .stop, since: t0.addingTimeInterval(60)))
        #expect(s.hold?.until == nil)
        #expect(s.heldCalls.map(\.id) == ["g1"])
        // The pause that was replaced no longer ends the hold.
        #expect(st.tick(now: t0.addingTimeInterval(1000), autoHideDoneAfter: nil).isEmpty)

        st.hold(sessionKey: key, kind: .pause, now: t0.addingTimeInterval(2000))
        s = try #require(st.session(key))
        #expect(s.hold?.until == t0.addingTimeInterval(2900))
        #expect(s.heldCalls.map(\.id) == ["g1"])
        #expect(st.tick(now: t0.addingTimeInterval(2900), autoHideDoneAfter: nil) == ["g1"])
    }

    @Test func permissionRequestKeepsPriorityOverHold() throws {
        var st = try store()
        for e in events(try message("permission-PermissionRequest", mode: .permission, rid: "p1", deadline: t0.addingTimeInterval(595))) {
            st.apply(e)
        }
        st.hold(sessionKey: key, kind: .stop, now: t0)
        #expect(st.session(key)?.state == .waitingPermission)
        st.markAnswered("p1")
        #expect(st.session(key)?.state == .stopped)
    }

    @Test func holdOfUnknownSessionDoesNothing() {
        var st = SessionStore()
        #expect(st.hold(sessionKey: "claude:nobody", kind: .pause, now: t0) == false)
        #expect(st.release(sessionKey: "claude:nobody").isEmpty)
        #expect(st.releaseAll().isEmpty)
    }
}

@Suite struct HoldTextTests {
    @Test func countdownAndStatusLines() {
        #expect(Hold.countdown(761) == "12:41")
        #expect(Hold.countdown(900) == "15:00")
        #expect(Hold.countdown(5) == "00:05")
        #expect(Hold.countdown(-3) == "00:00")

        let pause = Hold(kind: .pause, since: t0)
        #expect(pause.remaining(at: t0) == 900)
        #expect(pause.remaining(at: t0.addingTimeInterval(139)) == 761)
        #expect(pause.remaining(at: t0.addingTimeInterval(2000)) == 0)
        #expect(pause.statusLine(at: t0.addingTimeInterval(139)) == "Paused · 12:41 left")

        let stop = Hold(kind: .stop, since: t0)
        #expect(stop.remaining(at: t0) == nil)
        #expect(stop.statusLine(at: t0.addingTimeInterval(20)) == "Stopped · just now")
        #expect(stop.statusLine(at: t0.addingTimeInterval(8 * 60 + 5)) == "Stopped · for 8 min")
        #expect(stop.statusLine(at: t0.addingTimeInterval(3 * 3600 + 120)) == "Stopped · for 3 h 2 min")
    }

    @Test func waitingLines() {
        var s = AgentSession(kind: .claude, sessionId: "x", cwd: "/p", now: t0)
        s.hold = Hold(kind: .stop, since: t0)
        #expect(s.holdWaitingLines() == ["Takes effect before the agent's next action"])
        for i in 1...5 {
            s.heldCalls.append(HeldCall(id: "g\(i)", summary: "Read f\(i)", since: t0, deadline: t0.addingTimeInterval(10)))
        }
        #expect(s.holdWaitingLines() == ["Holding: Read f1", "Holding: Read f2", "Holding: Read f3", "and 2 more"])
        s.heldCalls.removeLast(2)
        #expect(s.holdWaitingLines() == ["Holding: Read f1", "Holding: Read f2", "Holding: Read f3"])
    }
}

@Suite struct GateProtocolTests {
    @Test func gateMessageRoundTrip() throws {
        let m = try message("PreToolUse-Bash", mode: .gate, rid: "g1", deadline: t0)
        let line = m.encode()
        #expect(line.contains("\"mode\":\"gate\""))
        #expect(!line.contains("\n"))
        #expect(try #require(HookMessage.decode(line)) == m)
        #expect(HookMode.gate.isSync)
        #expect(HookMode(rawValue: "gate") == .gate)
    }

    @Test func proceedReplyDecodes() {
        let line = HookReply(requestId: "g1", decision: .passthrough).encode()
        #expect(HookReply.decode(line) == HookReply(requestId: "g1", decision: .passthrough))
        // A reply is never mistaken for a hold notice, and the other way round.
        #expect(HoldNotice.decode(line) == nil)
    }

    @Test func holdNoticeRoundTrip() {
        let pause = HoldNotice(requestId: "g1", until: t0.addingTimeInterval(900))
        #expect(HoldNotice.decode(pause.encode()) == pause)
        let stop = HoldNotice(requestId: "g1", until: nil)
        #expect(HoldNotice.decode(stop.encode()) == stop)
        #expect(HookReply.decode(pause.encode()) == nil)
        #expect(HookReply.decode(stop.encode()) == nil)
        #expect(HoldNotice.decode("not json") == nil)
        #expect(HoldNotice.decode("{\"request_id\":\"g1\"}") == nil)
        #expect(HoldNotice.decode("{\"request_id\":\"g1\",\"held\":false}") == nil)
    }

    @Test func timings() {
        #expect(HookTiming.gateTimeout == 86400)
        #expect(HookTiming.pauseLimit == 900)
        #expect(HookTiming.deadline(now: t0, hookTimeout: HookTiming.gateTimeout) == t0.addingTimeInterval(86395))
    }

    /// No wait of the gate hook is unbounded, and none passes the hook's own deadline.
    @Test func gateWaitIsAlwaysBounded() {
        let deadline = t0.addingTimeInterval(86395)
        // No word from the app: two seconds, then the call proceeds.
        #expect(HookTiming.gateWaitLimit(started: t0, deadline: deadline, notice: nil) == t0.addingTimeInterval(2))
        #expect(HookTiming.gateWaitLimit(started: t0, deadline: t0.addingTimeInterval(1), notice: nil) == t0.addingTimeInterval(1))
        // Pause: until it ends plus the margin, even if the app never replies.
        let pause = HoldNotice(requestId: "g", until: t0.addingTimeInterval(900))
        #expect(HookTiming.gateWaitLimit(started: t0, deadline: deadline, notice: pause) == t0.addingTimeInterval(905))
        #expect(HookTiming.gateWaitLimit(started: t0, deadline: t0.addingTimeInterval(300), notice: pause) == t0.addingTimeInterval(300))
        // Stop: the hook's own deadline.
        #expect(HookTiming.gateWaitLimit(started: t0, deadline: deadline, notice: HoldNotice(requestId: "g", until: nil)) == deadline)
    }

    /// A notice and the reply sent back to back must both be read: losing the reply would keep the hook waiting.
    @Test func lineReaderKeepsTheSecondLine() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]) }
        let notice = HoldNotice(requestId: "g1", until: nil).encode()
        let reply = HookReply(requestId: "g1", decision: .passthrough).encode()
        let both = Array((notice + "\n" + reply + "\n").utf8)
        #expect(write(fds[1], both, both.count) == both.count)
        close(fds[1])

        var reader = SocketIO.LineReader(fd: fds[0])
        let soon = Date().addingTimeInterval(2)
        #expect(reader.next(until: soon) == notice)
        #expect(reader.next(until: soon) == reply)
        #expect(reader.next(until: soon) == nil)   // closed
    }

    @Test func lineReaderTimesOut() {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        var reader = SocketIO.LineReader(fd: fds[0])
        let started = Date()
        #expect(reader.next(until: started.addingTimeInterval(0.2)) == nil)
        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(reader.next(until: started) == nil)   // a deadline in the past returns at once
    }
}

@Suite struct GateAdapterTests {
    @Test func gateModeStillYieldsToolStarted() throws {
        let gate = events(try message("PreToolUse-Bash", mode: .gate, rid: "g1"))
        let plain = events(try message("PreToolUse-Bash", mode: .event, rid: "g1"))
        #expect(gate == plain)
        #expect(gate.count == 1)
        guard case .toolStarted(let tool, _, let id) = try #require(gate.first).body else {
            Issue.record("expected toolStarted")
            return
        }
        #expect(tool == "Bash")
        #expect(id == "toolu_01CqCicFYu2bJp8W1kYijWFn")
    }

    @Test func gateIsForwardedOnlyWithASession() throws {
        #expect(adapter.shouldForward(mode: .gate, payload: try fixture("PreToolUse-Bash")))
        #expect(!adapter.shouldForward(mode: .gate, payload: ["tool_name": "Bash"]))
    }

    /// Whatever the app replies, a gate hook prints nothing: empty stdout lets the tool call go on as usual.
    @Test(arguments: [Decision.passthrough, .allow, .deny(reason: "no"), .allowWith([["type": "addRules"]])])
    func gateNeverPrintsADecision(_ d: Decision) throws {
        #expect(adapter.hookOutput(for: d, mode: .gate, payload: try fixture("PreToolUse-Bash")) == nil)
    }
}

@Suite struct GateInstallerTests {
    let installer = ClaudeHookInstaller(hookPath: "/Users/dev/.local/bin/agenthud-hook", timeout: 600)
    let hook = "/Users/dev/.local/bin/agenthud-hook"

    /// An install made before Pause / Stop: PreToolUse is a plain async event. Foreign hooks sit around ours.
    var old: JSONValue {
        [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "bash ~/guard.sh", "timeout": 5]]],
                    ["matcher": "*", "hooks": [["type": "command", "command": .string("\(hook) claude event"), "async": true, "timeout": 10]]],
                    ["matcher": "Write", "hooks": [["type": "command", "command": "lint.sh"]]],
                ],
                "PermissionRequest": [
                    ["matcher": "*", "hooks": [["type": "command", "command": .string("\(hook) claude permission --timeout 600"), "timeout": 600]]],
                ],
                "Stop": [
                    ["hooks": [["type": "command", "command": "notify.sh"]]],
                    ["hooks": [["type": "command", "command": .string("\(hook) claude event"), "async": true, "timeout": 10]]],
                ],
            ],
            "model": "opus",
        ]
    }

    func ours(_ settings: JSONValue, _ event: String) -> [JSONValue] {
        (settings["hooks"]?[event]?.arrayValue ?? []).flatMap { $0["hooks"]?.arrayValue ?? [] }
            .filter { $0["command"]?.stringValue?.contains("agenthud-hook") == true }
    }

    func foreign(_ settings: JSONValue, _ event: String) -> [String] {
        (settings["hooks"]?[event]?.arrayValue ?? []).flatMap { $0["hooks"]?.arrayValue ?? [] }
            .compactMap { $0["command"]?.stringValue }.filter { !$0.contains("agenthud-hook") }
    }

    @Test func freshInstallHasTheGateEntry() throws {
        let after = installer.install(into: .object(JSONObject()))
        let pre = ours(after, "PreToolUse")
        #expect(pre.count == 1)
        #expect(pre[0]["command"]?.stringValue == "\(hook) claude gate --timeout 86400")
        #expect(pre[0]["timeout"] == 86400)
        #expect(pre[0]["async"] == nil)
        #expect(pre[0]["type"] == "command")
        #expect(after["hooks"]?["PreToolUse"]?[0]?["matcher"] == "*")
        // The permission entry keeps the user's answer time; the other events stay asynchronous.
        #expect(ours(after, "PermissionRequest")[0]["timeout"] == 600)
        #expect(ours(after, "PostToolUse")[0]["command"]?.stringValue == "\(hook) claude event")
        #expect(ours(after, "PostToolUse")[0]["async"] == true)
        #expect(installer.plannedEntries()["PreToolUse"]?[0]?["hooks"]?[0]?["timeout"] == 86400)
        #expect(ClaudeHookInstaller.isInstalled(in: after))
        #expect(!ClaudeHookInstaller.needsUpdate(in: after))
    }

    @Test func gateTimeoutDoesNotFollowTheAnswerTime() {
        let short = ClaudeHookInstaller(hookPath: hook, timeout: 120)
        #expect(short.command(.gate) == "\(hook) claude gate --timeout 86400")
        #expect(short.command(.permission) == "\(hook) claude permission --timeout 120")
        #expect(!ClaudeHookInstaller.needsUpdate(in: short.install(into: .object(JSONObject()))))
    }

    @Test func oldInstallNeedsUpdate() {
        #expect(ClaudeHookInstaller.isInstalled(in: old))
        #expect(ClaudeHookInstaller.needsUpdate(in: old))
        // Not installed at all - nothing to update.
        #expect(!ClaudeHookInstaller.needsUpdate(in: .object(JSONObject())))
        #expect(!ClaudeHookInstaller.needsUpdate(in: ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": "lint.sh"]]]]]]))
    }

    @Test func needsUpdateWhenGateTimeoutDiffersOrEntryIsMissing() {
        var wrongTimeout = installer.install(into: .object(JSONObject()))
        var groups = wrongTimeout["hooks"]?["PreToolUse"]?.arrayValue ?? []
        groups[0]["hooks"] = [["type": "command", "command": .string("\(hook) claude gate --timeout 600"), "timeout": 600]]
        wrongTimeout["hooks"]?["PreToolUse"] = .array(groups)
        #expect(ClaudeHookInstaller.needsUpdate(in: wrongTimeout))

        // The command is right but the entry's own timeout is not.
        groups[0]["hooks"] = [["type": "command", "command": .string("\(hook) claude gate --timeout 86400"), "timeout": 600]]
        wrongTimeout["hooks"]?["PreToolUse"] = .array(groups)
        #expect(ClaudeHookInstaller.needsUpdate(in: wrongTimeout))

        // Our hooks are there, but none on PreToolUse.
        let noPre: JSONValue = ["hooks": ["Stop": [["hooks": [["type": "command", "command": .string("\(hook) claude event")]]]]]]
        #expect(ClaudeHookInstaller.isInstalled(in: noPre))
        #expect(ClaudeHookInstaller.needsUpdate(in: noPre))
    }

    @Test func installUpgradesInPlaceKeepingForeignHooksAndOrder() {
        let after = installer.install(into: old)
        #expect(!ClaudeHookInstaller.needsUpdate(in: after))
        #expect(ClaudeHookInstaller.isInstalled(in: after))
        #expect(after["model"] == "opus")
        // One entry of ours per event, and the PreToolUse one is the gate.
        #expect(ours(after, "PreToolUse").map { $0["command"]?.stringValue } == ["\(hook) claude gate --timeout 86400"])
        #expect(ours(after, "PermissionRequest").count == 1)
        #expect(ours(after, "Stop").count == 1)
        #expect(!after.compact().contains("claude event\",\"async\":true,\"timeout\":10}]},{\"matcher\":\"Write\""))
        // Foreign hooks are untouched and keep their order.
        #expect(foreign(after, "PreToolUse") == ["bash ~/guard.sh", "lint.sh"])
        #expect(foreign(after, "Stop") == ["notify.sh"])
        #expect(after["hooks"]?["PreToolUse"]?[0] == old["hooks"]?["PreToolUse"]?[0])
        #expect(after["hooks"]?["PreToolUse"]?[1] == old["hooks"]?["PreToolUse"]?[2])
        // Idempotent.
        #expect(installer.install(into: after) == after)
    }

    @Test func uninstallRemovesOldAndNewForms() {
        let foreignOnly: JSONValue = [
            "hooks": [
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "bash ~/guard.sh", "timeout": 5]]],
                    ["matcher": "Write", "hooks": [["type": "command", "command": "lint.sh"]]],
                ],
                "Stop": [["hooks": [["type": "command", "command": "notify.sh"]]]],
            ],
            "model": "opus",
        ]
        #expect(ClaudeHookInstaller.uninstall(from: old) == foreignOnly)
        #expect(ClaudeHookInstaller.uninstall(from: installer.install(into: old)) == foreignOnly)
        // Both forms side by side (a half-finished manual edit).
        var both = installer.install(into: old)
        var groups = both["hooks"]?["PreToolUse"]?.arrayValue ?? []
        groups.append(["matcher": "*", "hooks": [["type": "command", "command": .string("\(hook) claude event"), "async": true]]])
        both["hooks"]?["PreToolUse"] = .array(groups)
        #expect(ClaudeHookInstaller.uninstall(from: both) == foreignOnly)
        #expect(!ClaudeHookInstaller.isInstalled(in: foreignOnly))
    }
}
