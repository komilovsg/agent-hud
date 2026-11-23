import Foundation
import Testing
@testable import AgentHudCore

// MARK: - Sessions run by the app: life cycle, command line, CLI lookup

@Suite struct OwnedSessionLogicTests {
    typealias S = OwnedSessionLogic.State
    typealias E = OwnedSessionLogic.Event

    func logic(_ events: [E]) -> OwnedSessionLogic {
        var l = OwnedSessionLogic()
        for e in events { l.handle(e) }
        return l
    }

    /// How to get into each state.
    var paths: [(S, [E])] {
        [(.starting, [.spawned]),
         (.idle, [.spawned, .initReceived]),
         (.running, [.spawned, .initReceived, .userSent]),
         (.interrupting, [.spawned, .initReceived, .userSent, .interruptRequested]),
         (.handingOver, [.spawned, .initReceived, .stdinClosed]),
         (.exited(0), [.spawned, .initReceived, .processExited(0)])]
    }

    @Test func transitionTable() {
        // nil - the event is refused and the state stays.
        let table: [(E, [S?])] = [
            //                     starting   idle        running        interrupting   handingOver   exited
            (.spawned,            [.starting, nil,        nil,           nil,           nil,          nil]),
            (.initReceived,       [.idle,     .idle,      .running,      .interrupting, .handingOver, nil]),
            (.userSent,           [.running,  .running,   nil,           nil,           nil,          nil]),
            (.turnFinished,       [nil,       nil,        .idle,         .idle,         nil,          nil]),
            (.interruptRequested, [nil,       nil,        .interrupting, nil,           nil,          nil]),
            (.stdinClosed,        [.handingOver, .handingOver, .handingOver, .handingOver, nil,       nil]),
            (.processExited(7),   [.exited(7), .exited(7), .exited(7),   .exited(7),    .exited(7),   nil]),
        ]
        for (event, row) in table {
            for (i, (from, path)) in paths.enumerated() {
                var l = logic(path)
                #expect(l.state == from)
                let accepted = l.handle(event)
                #expect(accepted == (row[i] != nil), "\(event) in \(from)")
                #expect(l.state == (row[i] ?? from), "\(event) in \(from)")
            }
        }
    }

    @Test func queries() {
        //                 state          send   interrupt handOver live
        let want: [(S, Bool, Bool, Bool, Bool)] = [
            (.starting,     true,  false, false, true),
            (.idle,         true,  false, true,  true),
            (.running,      false, true,  false, true),
            (.interrupting, false, false, false, true),
            (.handingOver,  false, false, false, true),
            (.exited(0),    false, false, false, false),
        ]
        for (i, (state, path)) in paths.enumerated() {
            let l = logic(path)
            #expect(l.state == state)
            #expect(l.canSend == want[i].1, "\(state)")
            #expect(l.canInterrupt == want[i].2, "\(state)")
            #expect(l.canHandOver == want[i].3, "\(state)")
            #expect(l.isLive == want[i].4, "\(state)")
        }
    }

    @Test func firstMessageBeforeTheSessionIsReported() {
        var l = logic([.spawned, .userSent])
        #expect(l.state == .running && !l.initialized)
        l.handle(.initReceived)
        #expect(l.state == .running && l.initialized)
        l.handle(.turnFinished)
        #expect(l.state == .idle)
    }

    @Test func exitBeforeInitIsRemembered() {
        #expect(logic([.spawned, .processExited(1)]).initialized == false)
        #expect(logic([.spawned, .initReceived, .processExited(1)]).initialized == true)
    }

    @Test func oneOwnerPerSession() {
        // Not ours: only when the store shows it ended.
        #expect(OwnedSessionLogic.canResumeHere(owned: nil, sessionEnded: true))
        #expect(!OwnedSessionLogic.canResumeHere(owned: nil, sessionEnded: false))
        // Ours and running in any form: never, whatever the store says.
        for (state, path) in paths where state != .exited(0) {
            #expect(!logic(path).canResumeHere(sessionEnded: true), "\(state)")
            #expect(!logic(path).canResumeHere(sessionEnded: false), "\(state)")
        }
        // Ours and gone.
        #expect(logic([.spawned, .processExited(0)]).canResumeHere(sessionEnded: false))
        #expect(logic([.spawned, .processExited(9)]).canResumeHere(sessionEnded: true))
    }

    // MARK: Command line

    let id = "0F8FAD5B-D9CB-469F-A165-70867728950E"

    @Test func argumentsForNewAndResume() {
        let base = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--include-partial-messages", "--permission-mode", "default"]
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: false, model: nil) == base + ["--session-id", id.lowercased()])
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: true, model: nil) == base + ["--resume", id.lowercased()])
        #expect(OwnedSessionLogic.arguments(sessionId: id, resume: false, model: "claude-sonnet-5[1m]")
                == base + ["--session-id", id.lowercased(), "--model", "claude-sonnet-5[1m]"])
    }

    /// Nothing that approves tools without the person, skips the hooks or changes the permission mode may ever be passed.
    static let forbidden = ["bypassPermissions", "dontAsk", "acceptEdits", "--dangerously-skip-permissions", "--bare",
                            "--allowedTools", "--allowed-tools", "--permission-prompts", "--permission-prompt-tool"]

    @Test func forbiddenFlagsNeverAppear() {
        let hostile = ["--dangerously-skip-permissions", "--bare", "bypassPermissions", "x --allowedTools Bash", "-p",
                       "--permission-mode=acceptEdits", "auto", "dontAsk", "acceptEdits", "a\nb", "a b", "", "--permission-prompts none",
                       "$(touch /tmp/x)", "`id`", "x;rm -rf /", "sonnet", "claude-opus-5"]
        let ids = [id, id.lowercased(), "", "not-a-uuid", "--dangerously-skip-permissions", "--bare", id + " --bare", "../../x"]
        for sid in ids {
            for resume in [false, true] {
                for model in [nil] + hostile.map(Optional.some) {
                    let args = OwnedSessionLogic.arguments(sessionId: sid, resume: resume, model: model)
                    for f in Self.forbidden {
                        #expect(!args.contains { $0.contains(f) }, "\(f) in \(args)")
                    }
                    guard !args.isEmpty else {
                        #expect(UUID(uuidString: sid) == nil)
                        continue
                    }
                    // The permission mode is given exactly once and is the default one.
                    #expect(args.filter { $0.hasPrefix("--permission-mode") } == ["--permission-mode"])
                    #expect(args[args.firstIndex(of: "--permission-mode")! + 1] == "default")
                    // Exactly one of the two identity flags, followed by the id.
                    #expect(args.contains("--resume") != args.contains("--session-id"))
                    #expect(args[args.firstIndex(of: resume ? "--resume" : "--session-id")! + 1] == sid.lowercased())
                    // A model is the only optional part and is passed only when it looks like a model name.
                    let known: Set<String> = ["-p", "--input-format", "stream-json", "--output-format", "--verbose",
                                              "--include-partial-messages", "--permission-mode", "default",
                                              "--resume", "--session-id", "--model", sid.lowercased()]
                    let extra = args.filter { !known.contains($0) }
                    #expect(extra.isEmpty || (extra == [model ?? ""] && args.suffix(2) == ["--model", model ?? ""]
                                              && ["sonnet", "claude-opus-5"].contains(model ?? "")), "\(args)")
                    #expect(args.allSatisfy { !$0.contains(" ") && !$0.contains("\n") && !$0.contains("=") })
                }
            }
        }
    }

    @Test func sessionIdMustBeAUuid() {
        #expect(OwnedSessionLogic.isValidSessionId(id))
        #expect(OwnedSessionLogic.isValidSessionId(id.lowercased()))
        for bad in ["", "abc", "--resume", id + "x", " " + id] { #expect(!OwnedSessionLogic.isValidSessionId(bad)) }
        #expect(OwnedSessionLogic.arguments(sessionId: "abc", resume: true, model: nil).isEmpty)
    }

    @Test func modelNames() {
        for ok in ["sonnet", "opus", "haiku", "claude-sonnet-5", "claude-opus-5[1m]", "claude-haiku-4.5"] { #expect(OwnedSessionLogic.isValidModel(ok)) }
        for bad in ["", "auto", "default", "-p", "--model", "claude-x y", "claude-x;ls", "gpt", "Sonnet ", String(repeating: "claude-", count: 20)] {
            #expect(!OwnedSessionLogic.isValidModel(bad), "\(bad)")
        }
    }

    // MARK: Finding the CLI

    @Test func discoveryOrder() {
        let home = "/Users/dev"
        let all = OwnedSessionLogic.executableCandidates(home: home)
        #expect(all == ["/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/Users/dev/.local/bin/claude", "/Users/dev/.claude/local/claude"])
        // The first existing one wins, in list order.
        for (i, want) in all.enumerated() {
            let present = Set(all[i...])
            var asked: [String] = []
            let got = OwnedSessionLogic.findExecutable(override: nil, home: home) { asked.append($0); return present.contains($0) }
            #expect(got == want)
            #expect(asked == Array(all[...i]))
        }
        #expect(OwnedSessionLogic.findExecutable(override: nil, home: home) { _ in false } == nil)
        #expect(OwnedSessionLogic.findExecutable(override: "", home: home) { $0 == all[1] } == all[1])
    }

    @Test func overrideIsNeverReplacedByADefault() {
        let home = "/Users/dev"
        #expect(OwnedSessionLogic.findExecutable(override: "/tmp/fake", home: home) { _ in true } == "/tmp/fake")
        // A wrong override means "not found", even when a real install exists.
        var asked: [String] = []
        #expect(OwnedSessionLogic.findExecutable(override: "/tmp/missing", home: home) { asked.append($0); return $0 != "/tmp/missing" } == nil)
        #expect(asked == ["/tmp/missing"])
    }

    @Test func recentFolders() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        let seen = (0..<12).map { (cwd: "/p/\($0 % 10)", at: t.addingTimeInterval(Double($0))) } + [(cwd: "", at: t.addingTimeInterval(99))]
        let got = OwnedSessionLogic.recentFolders(seen)
        #expect(got == ["/p/1", "/p/0", "/p/9", "/p/8", "/p/7", "/p/6", "/p/5", "/p/4"])
        #expect(OwnedSessionLogic.recentFolders(seen, limit: 2) == ["/p/1", "/p/0"])
        #expect(OwnedSessionLogic.recentFolders([]) == [])
    }
}

// MARK: - Store entries of sessions run by the app

@Suite struct OwnedStoreTests {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let sid = "0f8fad5b-d9cb-469f-a165-70867728950e"

    func ev(_ body: AgentEvent.Body, _ t: TimeInterval, session: String? = nil, host: HostInfo? = nil) -> AgentEvent {
        AgentEvent(kind: .claude, sessionId: session ?? sid, cwd: "/work/app", host: host, time: now.addingTimeInterval(t), body: body)
    }

    @Test func hostRunByTheApp() {
        let h = HostInfo.ownedByHud
        #expect(h.isHud && h.place == .hud && h.label == "Agent HUD")
        #expect(!h.isEditor && !h.isDesktopApp && !h.isEmpty)
        #expect(HostInfo(json: h.toJSON()) == h)
        // The app's own bundle wins over whatever else the hook saw around the process.
        #expect(HostInfo(termProgram: "Apple_Terminal", tty: "/dev/ttys001", appBundleId: HostInfo.agentHud).place == .hud)
        #expect(HostInfo(appBundleId: HostInfo.vscode).place == .editor)
        #expect(SendHostKind(host: h) == .unsupported)
    }

    @Test func hookEventsMergeIntoTheRegisteredEntry() {
        var store = SessionStore()
        let key = store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        #expect(key == "claude:\(sid)")
        #expect(store.visibleSessions.map(\.id) == [key])
        #expect(store.session(key)?.baseState == .starting)
        #expect(store.session(key)?.projectName == ProjectNames.displayName(cwd: "/work/app"))

        // Hook events of the same session: with a host that knows only the process, and with no host at all.
        store.apply(ev(.sessionStarted(source: "startup", model: "claude-x"), 1, host: HostInfo(agentPid: 4242, entrypoint: "sdk-cli")))
        store.apply(ev(.promptSubmitted("Fix the form"), 2))
        store.apply(ev(.toolStarted(toolName: "Bash", input: ["command": "ls"], toolUseId: "t1"), 3))
        #expect(store.order == [key])
        #expect(store.sessions.count == 1)
        let s = store.session(key)!
        #expect(s.host.isHud && s.host.agentPid == 4242)
        #expect(s.baseState == .working && s.title == "Fix the form" && s.model == "claude-x" && s.steps.count == 1)
    }

    @Test func endedSessionOfOursStaysListed() {
        var store = SessionStore()
        let key = store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        store.keep(key, true)
        store.apply(ev(.sessionEnded(reason: nil), 1))
        store.tick(now: now.addingTimeInterval(60), autoHideDoneAfter: nil)
        #expect(store.session(key)?.baseState == .ended)
        // Let go: removed after the usual linger.
        store.keep(key, false)
        store.tick(now: now.addingTimeInterval(61), autoHideDoneAfter: nil)
        #expect(store.session(key) == nil && store.kept.isEmpty)
        // Keeping an unknown session does nothing.
        store.keep("claude:nope", true)
        #expect(store.kept.isEmpty)
    }

    @Test func registerRevivesAnEndedSessionAndReplacesTheHost() {
        var store = SessionStore()
        let editor = HostInfo(agentPid: 77, appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)
        store.apply(ev(.sessionStarted(source: nil, model: nil), 0, host: editor))
        store.apply(ev(.promptSubmitted("Task"), 1, host: editor))
        store.apply(ev(.sessionEnded(reason: nil), 2, host: editor))
        let key = "claude:\(sid)"
        #expect(store.session(key)?.baseState == .ended)

        store.register(sessionId: sid, cwd: "/elsewhere", host: .ownedByHud, now: now.addingTimeInterval(3))
        let s = store.session(key)!
        #expect(s.baseState == .idle && s.finishedAt == nil)
        // Nothing of the editor is left: no stale process id to be found dead, no editor entry point.
        #expect(s.host == .ownedByHud && !s.host.isEditor)
        #expect(s.cwd == "/work/app" && s.title == "Task")
        store.tick(now: now.addingTimeInterval(60), autoHideDoneAfter: nil)
        #expect(store.session(key) != nil)

        // And the other way round: handed to an editor.
        store.register(sessionId: sid, cwd: "/work/app", host: HostInfo(appBundleId: HostInfo.cursor, entrypoint: HostInfo.vscodeEntrypoint),
                       now: now.addingTimeInterval(70))
        #expect(store.session(key)?.host.place == .editor && store.session(key)?.host.label == "Cursor")
        #expect(store.order == [key])
    }

    @Test func registerShowsAHiddenOrUnrevealedSession() {
        var store = SessionStore()
        store.apply(ev(.sessionStarted(source: nil, model: nil), 0, host: HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)))
        #expect(store.visibleSessions.isEmpty)      // an editor session without a task is not shown
        store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        #expect(store.visibleSessions.count == 1)
        store.hide("claude:\(sid)")
        store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        #expect(store.visibleSessions.count == 1)
    }

    @Test func rekeyMovesThePlaceholder() {
        var store = SessionStore()
        let other = "11111111-2222-3333-4444-555555555555"
        let old = store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        store.keep(old, true)
        store.apply(ev(.promptSubmitted("Task"), 1))
        let key = store.rekey(old, toSessionId: other)
        #expect(key == "claude:\(other)")
        #expect(store.order == [key] && store.session(old) == nil)
        let s = store.session(key)!
        #expect(s.sessionId == other && s.title == "Task" && s.host.isHud && s.baseState == .working && s.cwd == "/work/app")
        #expect(store.kept == [key])
        // Same id or unknown key: nothing happens.
        #expect(store.rekey(key, toSessionId: other) == key)
        #expect(store.rekey("claude:nope", toSessionId: other) == "claude:nope")
        #expect(store.sessions.count == 1)
    }

    @Test func rekeyOntoAnEntryThatAlreadyHasEvents() {
        var store = SessionStore()
        let other = "11111111-2222-3333-4444-555555555555"
        let old = store.register(sessionId: sid, cwd: "/work/app", host: .ownedByHud, now: now)
        store.keep(old, true)
        // The CLI's hooks already reported the session under its real id.
        store.apply(ev(.promptSubmitted("Real task"), 1, session: other, host: HostInfo(agentPid: 5)))
        #expect(store.sessions.count == 2)
        let key = store.rekey(old, toSessionId: other)
        #expect(store.order == [key] && store.sessions.count == 1)
        #expect(store.session(key)?.title == "Real task" && store.session(key)?.host.isHud == true)
        #expect(store.kept == [key])
    }
}
