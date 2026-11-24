import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Helpers

func fixture(_ name: String) throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/claude/\(name)", withExtension: "json"))
    return try JSONValue.parse(Data(contentsOf: url))
}

func message(_ name: String, mode: HookMode = .event, rid: String = "r1", deadline: Date? = nil,
             host: HostInfo = HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001", agentPid: 42)) throws -> HookMessage {
    HookMessage(agent: .claude, mode: mode, requestId: rid, deadline: deadline, host: host, payload: try fixture(name))
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
let adapter = ClaudeCodeAdapter()

func events(_ m: HookMessage, at t: Date = t0) -> [AgentEvent] { adapter.events(from: m, now: t) }

// MARK: - JSON

@Suite struct JSONTests {
    @Test func roundTripPreservesOrderAndNumbers() throws {
        let text = """
        {
          "zeta": 1,
          "alpha": {
            "n": 3650,
            "f": 1.5e3,
            "s": "grüß \\"Welt\\" \\n\\t/ \\u00e9 😀",
            "arr": [],
            "obj": {}
          },
          "list": [
            true,
            false,
            null
          ]
        }
        """
        let v = try JSONValue.parse(text)
        #expect(v.objectValue?.keys == ["zeta", "alpha", "list"])
        #expect(v["alpha"]?["n"] == .number("3650"))
        #expect(v["alpha"]?["s"]?.stringValue == "grüß \"Welt\" \n\t/ é 😀")
        let again = try JSONValue.parse(v.pretty())
        #expect(again == v)
        #expect(v.pretty().contains("\"n\": 3650"))
        #expect(v.pretty().contains("\"arr\": []"))
    }

    @Test func surrogatePairs() throws {
        #expect(try JSONValue.parse("\"\\ud83d\\ude00\"").stringValue == "😀")
    }

    @Test func rejectsGarbage() {
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{\"a\":}") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("{} x") }
        #expect(throws: JSONParseError.self) { try JSONValue.parse("\"open") }
    }

    @Test func compactEscapesControlChars() {
        let v: JSONValue = ["a": .string("x\u{01}y")]
        #expect(v.compact() == "{\"a\":\"x\\u0001y\"}")
    }

    @Test func objectSubscriptSetAndDelete() {
        var o = JSONObject()
        o["a"] = 1; o["b"] = 2; o["a"] = 3; o["b"] = nil
        #expect(o.keys == ["a"])
        #expect(o["a"] == .number("3"))
    }
}

// MARK: - Protocol

@Suite struct ProtocolTests {
    @Test func messageRoundTrip() throws {
        let m = try message("permission-PermissionRequest", mode: .permission, deadline: t0)
        let back = try #require(HookMessage.decode(m.encode()))
        #expect(back == m)
        #expect(!m.encode().contains("\n"))
    }

    @Test(arguments: [
        Decision.allow, .deny(reason: "not allowed"), .deny(reason: nil),
        .passthrough,
        .allowWith([["type": "setMode", "mode": "acceptEdits", "destination": "session"]]),
    ])
    func replyRoundTrip(_ d: Decision) throws {
        let r = HookReply(requestId: "abc", decision: d)
        #expect(HookReply.decode(r.encode()) == r)
    }

    @Test func badMessagesAreRejected() {
        #expect(HookMessage.decode("not json") == nil)
        #expect(HookMessage.decode("{\"agent\":\"unknown\",\"mode\":\"event\",\"request_id\":\"x\",\"payload\":{}}") == nil)
    }

    @Test func deadlineKeepsSafetyMargin() {
        #expect(HookTiming.deadline(now: t0, hookTimeout: 600) == t0.addingTimeInterval(595))
        #expect(HookTiming.deadline(now: t0, hookTimeout: 2) == t0.addingTimeInterval(1))
    }
}

// MARK: - Claude Code adapter

@Suite struct ClaudeAdapterTests {
    @Test func mapsRealEvents() throws {
        let cases: [(String, (AgentEvent.Body) -> Bool)] = [
            ("SessionStart", { if case .sessionStarted(let src, let model) = $0 { return src == "startup" && model == "claude-haiku-5-5" }; return false }),
            ("UserPromptSubmit", { if case .promptSubmitted(let p) = $0 { return p.hasPrefix("First use") }; return false }),
            ("PreToolUse-Bash", { if case .toolStarted(let t, _, let id) = $0 { return t == "Bash" && id != nil }; return false }),
            ("PostToolUse-Bash", { if case .toolFinished(let t, _, _, let ms, let failed, _) = $0 { return t == "Bash" && ms != nil && !failed }; return false }),
            ("Stop", { if case .stopped(let msg, false) = $0 { return msg?.contains("Red") == true }; return false }),
            ("Notification-permission_prompt", { if case .notification("permission_prompt", _) = $0 { return true }; return false }),
        ]
        for (name, check) in cases {
            let e = try #require(events(try message(name)).first, "no event for \(name)")
            #expect(check(e.body), "\(name): \(e.body)")
            #expect(e.sessionId == "11111111-2222-3333-4444-555555555555")
            #expect(e.cwd == "/Users/dev/project")
        }
    }

    @Test func permissionMode() throws {
        let p = try #require(events(try message("permission-PermissionRequest", mode: .permission, rid: "p1", deadline: t0)).first)
        guard case .permissionRequested("p1", "Bash", let input, t0, let suggestions) = p.body else { Issue.record("\(p.body)"); return }
        #expect(input["command"]?.stringValue?.contains("node -e") == true)
        #expect(suggestions.count == 1)
        #expect(suggestions.first?["destination"] == "localSettings")
    }

    @Test func shouldForward() throws {
        #expect(adapter.shouldForward(mode: .permission, payload: try fixture("permission-PermissionRequest")))
        var ask = try fixture("permission-PermissionRequest")
        ask["tool_name"] = "AskUserQuestion"
        #expect(!adapter.shouldForward(mode: .permission, payload: ask))
        // The question is answered by its own hook on PreToolUse; a plan is approved from the card.
        #expect(adapter.shouldForward(mode: .permission, payload: try fixture("permission-ExitPlanMode")))
    }

    @Test func permissionOutputs() throws {
        let payload = try fixture("permission-PermissionRequest")
        let allow = try JSONValue.parse(try #require(adapter.hookOutput(for: .allow, mode: .permission, payload: payload)))
        #expect(allow["hookSpecificOutput"]?["hookEventName"] == "PermissionRequest")
        #expect(allow["hookSpecificOutput"]?["decision"]?["behavior"] == "allow")

        let deny = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: "  dangerous "), mode: .permission, payload: payload)))
        #expect(deny["hookSpecificOutput"]?["decision"]?["behavior"] == "deny")
        #expect(deny["hookSpecificOutput"]?["decision"]?["message"] == "dangerous")

        let denyEmpty = try JSONValue.parse(try #require(adapter.hookOutput(for: .deny(reason: ""), mode: .permission, payload: payload)))
        #expect(denyEmpty["hookSpecificOutput"]?["decision"]?["message"]?.stringValue?.isEmpty == false)

        #expect(adapter.hookOutput(for: .passthrough, mode: .permission, payload: payload) == nil)
        #expect(adapter.hookOutput(for: .allow, mode: .event, payload: payload) == nil)
    }

    @Test func summaries() {
        func s(_ t: String, _ i: JSONValue) -> String { adapter.summarize(toolName: t, input: i, cwd: "/p") }
        #expect(s("Bash", ["command": "npm test\nsecond line"]) == "$ npm test")
        #expect(s("Read", ["file_path": "/p/src/a.ts"]) == "Read src/a.ts")
        #expect(s("Edit", ["file_path": "/other/b.ts"]) == "Edit /other/b.ts")
        #expect(s("Grep", ["pattern": "foo"]) == "Grep \"foo\"")
        #expect(s("WebFetch", ["url": "https://example.com/x"]) == "WebFetch example.com")
        #expect(s("mcp__brain__search", ["query": "x"]) == "brain · search")
        #expect(s("mcp__claude-in-chrome__tabs_create_mcp", [:]) == "claude-in-chrome · tabs_create_mcp")
        #expect(s("Task", ["description": "Find the bug"]) == "Agent: Find the bug")
        #expect(s("Unknown", [:]) == "Unknown")
    }
}

// MARK: - Session store

@Suite struct SessionStoreTests {
    func run(_ names: [(String, HookMode, String)], store: inout SessionStore, start: Date = t0) throws -> [String] {
        var released: [String] = []
        for (k, (name, mode, rid)) in names.enumerated() {
            let t = start.addingTimeInterval(TimeInterval(k))
            for e in events(try message(name, mode: mode, rid: rid, deadline: t.addingTimeInterval(595)), at: t) {
                released += store.apply(e)
            }
        }
        return released
    }

    var key: String { "claude:11111111-2222-3333-4444-555555555555" }

    @Test func fullHappyPath() throws {
        var st = SessionStore()
        _ = try run([("SessionStart", .event, "a"), ("UserPromptSubmit", .event, "b")], store: &st)
        var s = try #require(st.session(key))
        #expect(s.state == .working)
        #expect(s.title.hasPrefix("First use the AskUserQuestion"))
        #expect(s.host.tty == "/dev/ttys001")
        #expect(s.projectName == "project")

        _ = try run([("PreToolUse-AskUserQuestion", .event, "c")], store: &st)
        #expect(st.session(key)?.state == .working)
        #expect(st.openRequestCount == 0)

        _ = try run([("PostToolUse-AskUserQuestion", .event, "d"), ("PreToolUse-Bash", .event, "e"),
                     ("permission-PermissionRequest", .permission, "p1")], store: &st)
        #expect(st.session(key)?.state == .waitingPermission)
        // A permission_prompt notification does not override an open request
        _ = try run([("Notification-permission_prompt", .event, "n")], store: &st)
        #expect(st.session(key)?.activePending?.id == "p1")
        st.markAnswered("p1")
        _ = try run([("PostToolUse-Bash", .event, "f"), ("Stop", .event, "g")], store: &st)
        s = try #require(st.session(key))
        #expect(s.state == .done)
        #expect(s.lastMessage?.contains("Red") == true)
        #expect(s.steps.map(\.toolName) == ["AskUserQuestion", "Bash"])
        #expect(s.steps.allSatisfy { $0.status == .ok })
        #expect(s.steps[1].durationMs != nil)
    }

    @Test func answeredInTerminalReleasesHook() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("PreToolUse-Bash", .event, "b"),
                     ("permission-PermissionRequest", .permission, "p1")], store: &st)
        #expect(st.session(key)?.state == .waitingPermission)
        let released = try run([("PostToolUse-Bash", .event, "c")], store: &st)
        #expect(released == ["p1"])
        #expect(st.session(key)?.activePending == nil)
        #expect(st.session(key)?.state == .working)
    }

    @Test func stopReleasesOpenRequests() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("permission-PermissionRequest", .permission, "p1")], store: &st)
        let released = try run([("Stop", .event, "b")], store: &st)
        #expect(released == ["p1"])
        #expect(st.session(key)?.state == .done)
    }

    @Test func connectionClosedBeforeDeadlineMeansAnsweredElsewhere() throws {
        var st = SessionStore()
        _ = try run([("permission-PermissionRequest", .permission, "p1")], store: &st)
        st.connectionClosed("p1", now: t0.addingTimeInterval(10))
        #expect(st.session(key)?.pending.isEmpty == true)
    }

    @Test func expiryByConnectionCloseAndByTick() throws {
        var st = SessionStore()
        _ = try run([("permission-PermissionRequest", .permission, "p1")], store: &st)
        st.connectionClosed("p1", now: t0.addingTimeInterval(594))
        #expect(st.session(key)?.state == .expired)

        var st2 = SessionStore()
        _ = try run([("permission-PermissionRequest", .permission, "p1")], store: &st2)
        #expect(st2.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: nil).isEmpty)
        #expect(st2.tick(now: t0.addingTimeInterval(597), autoHideDoneAfter: nil) == ["p1"])
        #expect(st2.session(key)?.state == .expired)
        // The session moved on - the expired popup disappears
        _ = try run([("PostToolUse-Bash", .event, "x")], store: &st2, start: t0.addingTimeInterval(600))
        #expect(st2.session(key)?.state == .working)
    }

    @Test func notificationWithoutPendingMeansWaitingInTerminal() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("Notification-permission_prompt", .event, "n")], store: &st)
        let s = try #require(st.session(key))
        #expect(s.state == .waitingPermission)
        #expect(s.activePending == nil)
        _ = try run([("PostToolUse-Bash", .event, "c")], store: &st)
        #expect(st.session(key)?.state == .working)
    }

    @Test func sessionEndRemovesAfterLinger() throws {
        var st = SessionStore()
        _ = try run([("SessionStart", .event, "a")], store: &st)
        var p = try fixture("Stop"); p["hook_event_name"] = "SessionEnd"; p["reason"] = "prompt_input_exit"
        for e in adapter.events(from: HookMessage(agent: .claude, mode: .event, requestId: "z", deadline: nil, host: HostInfo(), payload: p), now: t0) {
            st.apply(e)
        }
        #expect(st.session(key)?.state == .ended)
        st.tick(now: t0.addingTimeInterval(1), autoHideDoneAfter: nil)
        #expect(st.session(key) != nil)
        st.tick(now: t0.addingTimeInterval(5), autoHideDoneAfter: nil)
        #expect(st.session(key) == nil)
        #expect(st.order.isEmpty)
    }

    @Test func autoHideDone() throws {
        var st = SessionStore()
        _ = try run([("UserPromptSubmit", .event, "a"), ("Stop", .event, "b")], store: &st)
        st.tick(now: t0.addingTimeInterval(100), autoHideDoneAfter: 60)
        #expect(st.visibleSessions.isEmpty)
        // A new prompt shows the session again
        _ = try run([("UserPromptSubmit", .event, "c")], store: &st, start: t0.addingTimeInterval(200))
        #expect(st.visibleSessions.count == 1)
    }

    @Test func stepsAreCapped() throws {
        var st = SessionStore()
        let base = try message("PreToolUse-Bash")
        for i in 0..<(AgentSession.maxSteps + 20) {
            var m = base
            m.payload["tool_use_id"] = .string("t\(i)")
            for e in events(m) { st.apply(e) }
        }
        #expect(st.session(key)?.steps.count == AgentSession.maxSteps)
        #expect(st.session(key)?.steps.last?.id == "t\(AgentSession.maxSteps + 19)")
    }

    @Test func subagentSteps() throws {
        var st = SessionStore()
        var p = try fixture("Stop")
        p["hook_event_name"] = "SubagentStart"; p["agent_id"] = "ag1"; p["agent_type"] = "Explore"
        let m = HookMessage(agent: .claude, mode: .event, requestId: "s", deadline: nil, host: HostInfo(), payload: p)
        for e in events(m) { st.apply(e) }
        #expect(st.session(key)?.steps.first?.summary == "Subagent: Explore")
        p["hook_event_name"] = "SubagentStop"
        for e in events(HookMessage(agent: .claude, mode: .event, requestId: "s2", deadline: nil, host: HostInfo(), payload: p), at: t0.addingTimeInterval(3)) {
            st.apply(e)
        }
        #expect(st.session(key)?.steps.first?.status == .ok)
        #expect(st.session(key)?.steps.first?.durationMs == 3000)
    }
}

// MARK: - Hook installer

@Suite struct InstallerTests {
    let foreign = """
    {
      "env": {
        "A": "1"
      },
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "bash ~/.claude/hooks/guard.sh",
                "timeout": 5
              }
            ]
          }
        ],
        "SessionStart": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "~/.claude/hooks/herdr-agent-state.sh session"
              }
            ]
          }
        ]
      },
      "model": "opus"
    }

    """

    let installer = ClaudeHookInstaller(hookPath: "/Users/dev/.local/bin/agenthud-hook", timeout: 600)

    @Test func installKeepsForeignHooksAndOrder() throws {
        let before = try JSONValue.parse(foreign)
        let after = installer.install(into: before)
        #expect(after.objectValue?.keys == ["env", "hooks", "model"])
        let pre = try #require(after["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 3)
        #expect(pre[0]["hooks"]?[0]?["command"] == "bash ~/.claude/hooks/guard.sh")
        // PreToolUse is the synchronous gate (it can hold a tool call), so it is not async and has its own timeout.
        #expect(pre[1]["hooks"]?[0]?["command"]?.stringValue?.hasSuffix("claude gate --timeout 86400") == true)
        #expect(pre[1]["hooks"]?[0]?["async"] == nil)
        #expect(pre[1]["hooks"]?[0]?["timeout"] == 86400)
        #expect(after["hooks"]?["PostToolUse"]?[0]?["hooks"]?[0]?["async"] == true)
        // The question entry sits next to the gate and waits as long as a permission request.
        #expect(pre[2]["matcher"] == "AskUserQuestion")
        #expect(pre[2]["hooks"]?[0]?["command"]?.stringValue?.hasSuffix("claude question --timeout 600") == true)
        #expect(pre[2]["hooks"]?[0]?["timeout"] == 600)
        #expect(pre[2]["hooks"]?[0]?["async"] == nil)
        let perm = try #require(after["hooks"]?["PermissionRequest"]?.arrayValue)
        #expect(perm[0]["hooks"]?[0]?["command"]?.stringValue?.hasSuffix("claude permission --timeout 600") == true)
        #expect(after["hooks"]?["Stop"]?[0]?["matcher"] == nil)
        #expect(ClaudeHookInstaller.isInstalled(in: after))
        #expect(!ClaudeHookInstaller.isInstalled(in: before))
    }

    @Test func installIsIdempotentAndUninstallRestores() throws {
        let before = try JSONValue.parse(foreign)
        let once = installer.install(into: before)
        let twice = installer.install(into: once)
        #expect(once == twice)
        let removed = ClaudeHookInstaller.uninstall(from: twice)
        #expect(removed == before)
        #expect(removed.pretty() + "\n" == foreign)
    }

    @Test func uninstallKeepsMixedGroups() throws {
        let mixed: JSONValue = ["hooks": ["Stop": [["hooks": [
            ["type": "command", "command": "other"],
            ["type": "command", "command": "/x/agenthud-hook claude event"],
        ]]]]]
        let r = ClaudeHookInstaller.uninstall(from: mixed)
        #expect(r["hooks"]?["Stop"]?[0]?["hooks"]?.arrayValue?.count == 1)
        #expect(r["hooks"]?["Stop"]?[0]?["hooks"]?[0]?["command"] == "other")
    }

    @Test func pathsWithSpacesAreQuoted() {
        let i = ClaudeHookInstaller(hookPath: "/Users/dev/My Apps/agenthud-hook", timeout: 30)
        #expect(i.command(.event) == "'/Users/dev/My Apps/agenthud-hook' claude event")
    }

    @Test func fileApplyMakesBackupAndPreservesFormatting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try foreign.write(to: file, atomically: true, encoding: .utf8)

        let r = try ClaudeHookInstaller.apply(file: file, now: t0) { installer.install(into: $0) }
        let backup = try #require(r.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == foreign)
        #expect(ClaudeHookInstaller.isInstalled(in: try JSONValue.parse(Data(contentsOf: file))))

        let r2 = try ClaudeHookInstaller.apply(file: file, now: t0.addingTimeInterval(1)) { ClaudeHookInstaller.uninstall(from: $0) }
        #expect(r2.backup != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == foreign)

        // No changes - no write and no backup
        let r3 = try ClaudeHookInstaller.apply(file: file) { $0 }
        #expect(r3.backup == nil)
    }

    @Test func missingFileIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agenthud-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try ClaudeHookInstaller.apply(file: file) { installer.install(into: $0) }
        #expect(ClaudeHookInstaller.isInstalled(in: try JSONValue.parse(Data(contentsOf: file))))
    }
}

// MARK: - HostProbe

@Suite struct HostProbeTests {
    @Test func agentIsFirstNonShellAncestor() {
        let chain = [
            HostProbe.ProcInfo(pid: 10, ppid: 9, tty: "/dev/ttys001", name: "sh"),
            HostProbe.ProcInfo(pid: 9, ppid: 8, tty: "/dev/ttys001", name: "2.1.322"),
            HostProbe.ProcInfo(pid: 8, ppid: 1, tty: "/dev/ttys001", name: "zsh"),
        ]
        #expect(HostProbe.agentProcess(in: chain)?.pid == 9)
    }

    @Test func currentProcessHasChain() {
        let h = HostProbe.current(env: [:])
        #expect(h.agentPid != nil)
        #expect(!h.processChain.isEmpty)
        let herdr = HostProbe.current(env: ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p2", "HERDR_SOCKET_PATH": "/s"])
        #expect(herdr.herdrPaneId == "w1:p2")
    }

    @Test func labels() {
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001").label == "Terminal")
        #expect(HostInfo(tty: "/dev/ttys001", herdrPaneId: "p").label == "herdr")
        // A terminal launched from the app stays a terminal.
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001", appBundleId: HostInfo.claudeDesktop).label == "Terminal")
    }
}

@Suite struct InteractiveFilterTests {
    let tty = HostInfo(tty: "/dev/ttys001")
    let claudeApp = HostInfo(appBundleId: HostInfo.claudeDesktop, appName: "Claude", hostSessionId: "local_1")

    @Test func terminalSessions() {
        #expect(HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]))
        #expect(HostProbe.isInteractive(kind: .claude, host: tty, env: [:]))
    }

    @Test func cursorCountsAsEditor() {
        let cursor = HostInfo(appBundleId: HostInfo.cursor, appName: "Cursor", entrypoint: HostInfo.vscodeEntrypoint)
        #expect(HostProbe.isInteractive(kind: .claude, host: cursor, env: ["CLAUDE_CODE_ENTRYPOINT": HostInfo.vscodeEntrypoint]))
        #expect(cursor.isEditor && cursor.label == "Cursor")
        // Any other editor built on VS Code is shown too, under its own name.
        let other = HostInfo(appBundleId: "com.example.editor", appName: "Example", entrypoint: HostInfo.vscodeEntrypoint)
        #expect(HostProbe.isInteractive(kind: .claude, host: other, env: ["CLAUDE_CODE_ENTRYPOINT": HostInfo.vscodeEntrypoint]))
        #expect(other.label == "Example")
    }

    @Test func desktopSessions() {
        #expect(HostProbe.isInteractive(kind: .claude, host: claudeApp,
                                        env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CODE_HOST_SESSION_ID": "local_1"]))
        #expect(claudeApp.isDesktopApp && !tty.isDesktopApp)
        #expect(claudeApp.label == "Claude app")
    }

    @Test func automationIsSkipped() {
        // Service request of the Claude app - no session id
        #expect(!HostProbe.isInteractive(kind: .claude, host: claudeApp, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: HostInfo(), env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]))
        // claude-vscode without a VS Code process among the ancestors - not a real extension panel.
        #expect(!HostProbe.isInteractive(kind: .claude, host: tty, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]))
        // Script: neither a TTY nor an app
        #expect(!HostProbe.isInteractive(kind: .claude, host: HostInfo(), env: [:]))
        #expect(HostProbe.isInteractive(kind: .claude, host: HostInfo(), env: ["AGENTHUD_ANY_HOST": "1"]))
    }

    @Test func bundleFromExecutable() {
        #expect(HostProbe.bundlePath(forExecutable: "/Applications/Claude.app/Contents/MacOS/Claude") == "/Applications/Claude.app")
        #expect(HostProbe.bundlePath(forExecutable: "/usr/bin/zsh") == nil)
    }

    @Test func hostRoundTrip() {
        let h = HostInfo(tty: nil, agentPid: 5, appBundleId: HostInfo.claudeDesktop, appName: "Claude", hostSessionId: "x")
        #expect(HostInfo(json: h.toJSON()) == h)
    }
}

// MARK: - VS Code

@Suite struct VSCodeTests {
    let vscode = HostInfo(agentPid: 7, processChain: ["claude", "Code Helper (Plugin)", "Code"],
                          appBundleId: HostInfo.vscode, appName: "Code", entrypoint: HostInfo.vscodeEntrypoint)

    @Test func vscodeSessionsAreInteractive() {
        #expect(HostProbe.isInteractive(kind: .claude, host: vscode, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]))
        // No GUI app in the chain, or an SDK run: still passed through.
        let headless = HostInfo(entrypoint: "claude-vscode")
        #expect(!HostProbe.isInteractive(kind: .claude, host: headless, env: ["CLAUDE_CODE_ENTRYPOINT": "claude-vscode"]))
        #expect(!HostProbe.isInteractive(kind: .claude, host: vscode, env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]))
    }

    @Test func placeAndLabels() {
        #expect(vscode.isEditor && vscode.place == .editor && !vscode.isDesktopApp)
        #expect(vscode.label == "VS Code")
        let term = HostInfo(termProgram: "vscode", tty: "/dev/ttys009", entrypoint: "cli")
        #expect(term.isEditorTerminal && term.place == .terminal)
        #expect(term.label == "terminal VS Code")
        #expect(HostInfo(appBundleId: HostInfo.claudeDesktop, hostSessionId: "local_1").place == .desktopApp)
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001").place == .terminal)
    }

    @Test func entrypointSurvivesRoundTripAndMerge() {
        #expect(HostInfo(json: vscode.toJSON()) == vscode)
        let merged = SessionStore.merge(vscode, HostInfo(agentPid: 9))
        #expect(merged.entrypoint == HostInfo.vscodeEntrypoint && merged.agentPid == 9)
    }
}

// MARK: - Allow always

@Suite struct PermissionRulesTests {
    @Test func bashPatterns() {
        #expect(PermissionRules.bashPattern("npm run build") == "npm run *")
        #expect(PermissionRules.bashPattern("pnpm run build") == "pnpm run *")
        #expect(PermissionRules.bashPattern("kill 41684 41849") == "kill *")
        #expect(PermissionRules.bashPattern("ls") == nil)                       // single word - an exact rule
        #expect(PermissionRules.bashPattern("pnpm -C x build") == nil)          // flag as the second word
        #expect(PermissionRules.bashPattern("npm test && npm run lint") == nil) // compound
        #expect(PermissionRules.bashPattern("rm -rf dist") == nil)              // dangerous to pattern
        #expect(PermissionRules.bashPattern("node -e 'x'") == nil)              // arbitrary code
        #expect(PermissionRules.bashPattern("FOO=1 npm test") == nil)
        #expect(PermissionRules.bashPattern("cat a.txt | head") == nil)
    }

    @Test func exactOnlyToolsNeverGetWildcard() {
        for cmd in ["git push origin main", "git status", "git -C x status", "uv run pytest -q", "docker compose up -d",
                    "docker run --rm alpine sh", "npx expo start --clear", "make deploy"] {
            #expect(PermissionRules.bashPattern(cmd) == cmd, "\(cmd)")
            let opts = PermissionRules.options(toolName: "Bash", input: ["command": .string(cmd)], suggestions: [])
            #expect(opts.count == 2 && opts.allSatisfy(\.generated), "\(cmd)")
            for o in opts {
                let content = o.update["rules"]?[0]?["ruleContent"]?.stringValue
                #expect(content == cmd, "\(cmd)")
                #expect(!o.title.contains("*"), "\(cmd)")
            }
        }
        // An asterisk in the command itself would become a pattern - we do not offer a rule.
        #expect(PermissionRules.bashPattern("git log --grep=* ") == nil)
        #expect(PermissionRules.options(toolName: "Bash", input: ["command": "make *"], suggestions: []).isEmpty)
        // Compound commands still get no rule.
        #expect(PermissionRules.bashPattern("git add . && git push") == nil)
        #expect(PermissionRules.bashPattern("make build | tee log") == nil)
    }

    @Test func otherToolsKeepTemplates() {
        let opts = PermissionRules.options(toolName: "Bash", input: ["command": "pnpm run build"], suggestions: [])
        #expect(opts.map(\.title) == ["Bash(pnpm run *)", "Bash(pnpm run *)"])
        #expect(PermissionRules.bashPattern("kill 41684 41849") == "kill *")
        #expect(PermissionRules.bashPattern("gh pr view 12") == "gh pr *")
    }

    @Test func optionsCombineTemplateAndSuggestions() throws {
        let payload = try fixture("permission-PermissionRequest")
        var input = JSONObject()
        input["command"] = "npm run test:unit"
        let opts = PermissionRules.options(toolName: "Bash", input: .object(input),
                                           suggestions: payload["permission_suggestions"]?.arrayValue ?? [])
        #expect(opts.count == 3)
        #expect(opts[0].title == "Bash(npm run *)" && opts[0].scope == "in this project" && opts[0].generated)
        #expect(opts[1].update["destination"] == "userSettings")
        #expect(opts[2].generated == false && opts[2].title.hasPrefix("Bash(node -e"))
        // The Claude suggestion is returned unchanged (as the documentation says).
        #expect(opts[2].update == payload["permission_suggestions"]?[0])
    }

    @Test func mcpGetsWholeToolRuleWithoutContent() {
        let opts = PermissionRules.options(toolName: "mcp__figma__get_file", input: [:], suggestions: [])
        #expect(opts.count == 1)
        #expect(opts[0].update["rules"]?[0]?["ruleContent"] == nil)
        #expect(opts[0].update["rules"]?[0]?["toolName"] == "mcp__figma__get_file")
    }

    @Test func describesEntries() {
        #expect(PermissionRules.describe(["type": "setMode", "mode": "acceptEdits", "destination": "session"])
                == "Accept file edits without asking")
        #expect(PermissionRules.describe(["type": "setMode", "mode": "bypassPermissions", "destination": "session"]) == nil)
        #expect(PermissionRules.describe(["type": "addRules", "behavior": "deny", "rules": [["toolName": "Bash"]]]) == nil)
    }

    @Test func allowWithOutputs() throws {
        let payload = try fixture("permission-PermissionRequest")
        let rule = try #require(payload["permission_suggestions"]?.arrayValue?.first)
        let out = try JSONValue.parse(try #require(adapter.hookOutput(for: .allowWith([rule]), mode: .permission, payload: payload)))
        let d = try #require(out["hookSpecificOutput"]?["decision"])
        #expect(d["behavior"] == "allow")
        #expect(d["updatedPermissions"]?.arrayValue == [rule])
        #expect(d["updatedInput"] == nil)
        #expect(Decision.allowWith([rule]).logLabel == "allowed always")
    }
}

@Suite struct ProjectNamesTests {
    @Test func displayNames() {
        #expect(ProjectNames.displayName(cwd: "/Users/dev/acme-hrm/front") == "acme-hrm/front")
        #expect(ProjectNames.displayName(cwd: "/Users/dev/acme-web-client") == "acme-web-client")
        #expect(ProjectNames.displayName(cwd: "/") == "/")
    }

    @Test func shortLabelsDropCommonPrefixAndResolveClashes() {
        let l = ProjectNames.shortLabels(for: [
            "/d/acme-mobile-app", "/d/acme-web-client", "/d/acme-platform", "/d/acme-hrm/front", "/d/acme.hrm.v2",
        ])
        #expect(l["/d/acme-mobile-app"] == "mobile")
        #expect(l["/d/acme-web-client"] == "web")
        #expect(l["/d/acme-platform"] == "platform")
        #expect(l["/d/acme-hrm/front"] == "hrm-front")
        #expect(l["/d/acme.hrm.v2"] == "hrm-v2")
        #expect(Set(l.values).count == 5)
    }

    @Test func singleAndUnrelated() {
        #expect(ProjectNames.shortLabels(for: ["/d/taklif"]) == ["/d/taklif": "taklif"])
        #expect(ProjectNames.shortLabels(for: ["/d/a-very-long-project-name"])["/d/a-very-long-project-name"]?.count == 10)
        // Projects without a shared first word keep the full name.
        let l = ProjectNames.shortLabels(for: ["/d/taklif", "/d/qr-menu", "/d/taklif"])
        #expect(l == ["/d/taklif": "taklif", "/d/qr-menu": "qr-menu"])
    }

    @Test func sharedPrefixOnlyAmongRelatives() {
        let l = ProjectNames.shortLabels(for: ["/d/agent-hub", "/d/acme-platform", "/d/acme-mobile-app/acme-mobile-app"])
        #expect(l["/d/agent-hub"] == "agent-hub")              // it used to be "agent"
        #expect(l["/d/acme-platform"] == "platform")
        #expect(l["/d/acme-mobile-app/acme-mobile-app"] == "mobile")
        // A single "relative" does not lose the prefix.
        #expect(ProjectNames.shortLabels(for: ["/d/agent-hub", "/d/acme-platform"])["/d/acme-platform"] == "acme-plat…")
    }

    @Test func labelsAreStableWithinUniverse() {
        // Labels are computed from a stable set of projects: a session leaving does not change the others' labels.
        let universe = ["/d/acme-mobile", "/d/acme-web", "/d/acme-api", "/d/taklif"]
        let all = ProjectNames.shortLabels(for: universe)
        let fewer = ProjectNames.shortLabels(for: universe + ["/d/acme-web"])
        #expect(all == fewer)
        #expect(all["/d/acme-web"] == "web" && all["/d/taklif"] == "taklif")
    }

    @Test func stableHue() {
        #expect(ProjectNames.hue(cwd: "/a") == ProjectNames.hue(cwd: "/a"))
        #expect((0..<1).contains(ProjectNames.hue(cwd: "/b")))
    }
}

// MARK: - Activity log and summary

@Suite struct ActivityTests {
    func rec(_ k: ActivityRecord.Kind, _ dt: TimeInterval, _ sid: String, _ cwd: String, _ text: String,
             detail: String? = nil, failed: Bool = false, stats: TurnStats? = nil) -> ActivityRecord {
        ActivityRecord(kind: k, time: t0.addingTimeInterval(dt), agent: "claude", session: sid,
                       project: ProjectNames.displayName(cwd: cwd), cwd: cwd, text: text, detail: detail, failed: failed, stats: stats)
    }

    @Test func recordRoundTrip() {
        let r = rec(.stop, 10, "s", "/p", "result", failed: true,
                    stats: TurnStats(tools: ["Edit": 2, "Bash": 1], files: ["a.ts"], subagents: 1, durationSec: 90))
        #expect(ActivityRecord(json: r.toJSON()) == r)
        #expect(ActivityRecord(json: ["kind": "nope"]) == nil)
    }

    @Test func buildPairsPromptsWithStops() {
        let st = TurnStats(tools: ["Edit": 3, "Bash": 2], files: ["src/a.ts", "src/b.ts"], durationSec: 600)
        let days = DailySummary.build([
            rec(.prompt, 0, "s1", "/d/mobile-app", "Fix the screen"),
            rec(.prompt, 30, "s2", "/d/web-client", "Update the copy"),
            rec(.stop, 600, "s1", "/d/mobile-app", "Done", stats: st),
            rec(.decision, 100, "s1", "/d/mobile-app", "$ npm test", detail: "allowed"),
            rec(.prompt, 700, "s1", "/d/mobile-app", "Another task"),
        ])
        #expect(days.map(\.name) == ["mobile-app", "web-client"])
        #expect(days[0].turns.count == 2)
        #expect(days[0].turns[0].end != nil && days[0].turns[0].stats.edits == 3 && days[0].turns[0].message == "Done")
        #expect(days[0].turns[1].end == nil)
        #expect(days[0].decisions == ["allowed": 1])
        #expect(days[0].workedSec == 600 && days[0].commands == 2)
        #expect(days[1].turns[0].end == nil)
    }

    @Test func markdown() {
        let st = TurnStats(tools: ["Edit": 3, "Bash": 2], files: ["src/a.ts"], durationSec: 1500)
        let md = DailySummary.markdown(DailySummary.build([
            rec(.prompt, 0, "s1", "/d/mobile-app", "Fix the screen\nsecond line"),
            rec(.stop, 1500, "s1", "/d/mobile-app", "Done, tests are green", stats: st),
        ]), day: t0)
        #expect(md.hasPrefix("# Daily summary · "))
        #expect(md.contains("**Total:** 1 task in 1 project · agents worked 25 min"))
        #expect(md.contains("## mobile-app"))
        #expect(md.contains("Fix the screen — done in 25 min · edits 3 · commands 2"))
        #expect(!md.contains("second line"))
        #expect(md.contains("  - Result: Done, tests are green"))
        #expect(md.contains("  - Files: a.ts"))
        #expect(DailySummary.markdown([], day: t0).contains("No agent activity"))
    }

    @Test func helpers() {
        #expect(DailySummary.duration(30) == "30 s")
        #expect(DailySummary.duration(3720) == "1 h 02 min")
        #expect(DailySummary.plural(1, "task", "tasks") == "task")
        #expect(DailySummary.plural(3, "task", "tasks") == "tasks")
        #expect(DailySummary.plural(11, "task", "tasks") == "tasks")
    }

    @Test func fileAppendAndRead() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ahud-act-\(UUID().uuidString)")
        supportDirLock.lock()
        setenv("AGENTHUD_SUPPORT_DIR", dir.path, 1)
        defer { unsetenv("AGENTHUD_SUPPORT_DIR"); try? FileManager.default.removeItem(at: dir); supportDirLock.unlock() }
        let a = rec(.prompt, 0, "s", "/p", "one"), b = rec(.stop, 5, "s", "/p", "two")
        ActivityLog.append(a)
        ActivityLog.append(b)
        #expect(ActivityLog.read(day: t0) == [a, b])
    }

    @Test func turnStatsFromSession() throws {
        var st = SessionStore()
        for e in events(try message("UserPromptSubmit"), at: t0) { st.apply(e) }
        func tool(_ name: String, _ input: JSONValue, _ id: String, _ dt: TimeInterval) {
            st.apply(AgentEvent(kind: .claude, sessionId: "11111111-2222-3333-4444-555555555555", cwd: "/Users/dev/project",
                                time: t0.addingTimeInterval(dt), body: .toolStarted(toolName: name, input: input, toolUseId: id)))
        }
        tool("Edit", ["file_path": "/Users/dev/project/src/a.ts"], "1", 1)
        tool("Edit", ["file_path": "/Users/dev/project/src/a.ts"], "2", 2)
        tool("Bash", ["command": "npm test"], "3", 3)
        let s = try #require(st.session("claude:11111111-2222-3333-4444-555555555555"))
        let stats = s.turnStats(until: t0.addingTimeInterval(60))
        #expect(stats.edits == 2 && stats.commands == 1)
        #expect(stats.files == ["src/a.ts"])
        #expect(stats.durationSec == 60)
    }
}

// MARK: - Flicker: requests, notifications, hiding (fork 0.2.1)

@Suite struct StaleStateTests {
    let sid = "11111111-2222-3333-4444-555555555555"
    var key: String { "claude:" + sid }

    func ev(_ dt: TimeInterval, _ body: AgentEvent.Body, agent: String? = nil, host: HostInfo? = nil) -> AgentEvent {
        AgentEvent(kind: .claude, sessionId: sid, cwd: "/Users/dev/project", agentId: agent, host: host,
                   time: t0.addingTimeInterval(dt), body: body)
    }

    func perm(_ rid: String, _ cmd: String, _ dt: TimeInterval, agent: String? = nil) -> AgentEvent {
        ev(dt, .permissionRequested(requestId: rid, toolName: "Bash", input: ["command": .string(cmd)],
                                    deadline: t0.addingTimeInterval(600), suggestions: []), agent: agent)
    }

    @Test func newRequestOfSameAgentSupersedesOld() {
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("task")))
        #expect(st.apply(perm("r1", "rm -rf a", 1)).isEmpty)
        // Answered "No" in VS Code: there will be no PostToolUse. The next request from the same agent clears the previous one.
        #expect(st.apply(perm("r2", "ls", 2)) == ["r1"])
        #expect(st.session(key)?.pending.map(\.id) == ["r2"])
        // A subagent's request does not displace the main agent's request - and vice versa.
        #expect(st.apply(perm("s1", "npm test", 3, agent: "sub-1")).isEmpty)
        #expect(Set(st.session(key)?.pending.map(\.id) ?? []) == ["r2", "s1"])
    }

    @Test func subagentStopReleasesItsRequests() {
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("task")))
        st.apply(perm("s1", "npm test", 1, agent: "sub-1"))
        #expect(st.session(key)?.state == .waitingPermission)
        #expect(st.apply(ev(2, .subagentStopped(agentId: "sub-1"))) == ["s1"])
        #expect(st.session(key)?.state == .working)
    }

    @Test func lateNotificationAfterStopIsIgnored() {
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("task")))
        st.apply(ev(1, .stopped(lastMessage: "done", failed: false)))
        st.apply(ev(2, .notification(type: "permission_prompt", message: nil)))
        #expect(st.session(key)?.state == .done)          // before: a false "Waiting for permission" until the next task
        st.apply(ev(3, .promptSubmitted("more")))
        st.apply(ev(4, .notification(type: "permission_prompt", message: nil)))
        #expect(st.session(key)?.state == .waitingPermission)   // in the middle of a turn - still waiting
    }

    @Test func injectedPromptsDoNotBecomeTitles() {
        #expect(SessionStore.isInjectedPrompt("<task-notification>\n<task-id>x</task-id>"))
        #expect(SessionStore.isInjectedPrompt("  <command-name>/review</command-name>"))
        #expect(!SessionStore.isInjectedPrompt("Fix <div> in the header"))
        #expect(!SessionStore.isInjectedPrompt("<Div> is broken"))
        #expect(!SessionStore.isInjectedPrompt("a regular prompt"))
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("Fix the jobs screen")))
        st.apply(ev(1, .promptSubmitted("<task-notification><task-id>b1</task-id></task-notification>")))
        #expect(st.session(key)?.title == "Fix the jobs screen")
        // The first real task stays the title (answers to agent questions do not overwrite it).
        st.apply(ev(2, .promptSubmitted("red")))
        #expect(st.session(key)?.title == "Fix the jobs screen")
        // If the HUD saw the session from the middle and an insertion came first - the first live prompt becomes the title.
        var mid = SessionStore()
        mid.apply(ev(0, .promptSubmitted("<task-notification>x</task-notification>")))
        #expect(mid.session(key)?.title == "")
        mid.apply(ev(1, .promptSubmitted("Make a commit")))
        #expect(mid.session(key)?.title == "Make a commit")
    }

    @Test func hiddenStaysHiddenUntilNewTaskOrRequest() {
        var st = SessionStore()
        st.apply(ev(0, .promptSubmitted("task")))
        st.hide(key)
        st.apply(ev(1, .toolStarted(toolName: "Read", input: ["file_path": "/a"], toolUseId: "t1")))
        st.apply(ev(2, .toolFinished(toolName: "Read", input: ["file_path": "/a"], toolUseId: "t1", durationMs: 1, failed: false)))
        #expect(st.session(key)?.hidden == true)     // before: came back on the very first step
        st.apply(perm("r1", "ls", 3))
        #expect(st.session(key)?.hidden == false)    // it needs you - we show it
        st.hide(key)
        st.apply(ev(4, .promptSubmitted("new")))
        #expect(st.session(key)?.hidden == false)
    }

    @Test func editorSessionAppearsWithFirstTask() {
        let vscode = HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)
        var st = SessionStore()
        st.apply(ev(0, .sessionStarted(source: "startup", model: nil), host: vscode))
        #expect(st.visibleSessions.isEmpty)          // an open Claude panel without a task - not in the HUD
        st.apply(ev(1, .promptSubmitted("task")))
        #expect(st.visibleSessions.count == 1)
        // A terminal session is visible at once, as before.
        var term = SessionStore()
        term.apply(ev(0, .sessionStarted(source: "startup", model: nil), host: HostInfo(tty: "/dev/ttys001")))
        #expect(term.visibleSessions.count == 1)
    }
}
