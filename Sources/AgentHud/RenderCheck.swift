import AgentHudCore
import AppKit
import SwiftUI

/// Developer check: `AgentHud --render <dir>` draws the token and card views with sample data to PNG files.
/// No window is shown and no socket is opened.
@MainActor
enum RenderCheck {
    static func run(dir: String) {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        FontLoader.register()
        let model = AppModel(settings: Settings())

        let idle = session(.idle)
        let states: [(String, AgentSession, Bool)] = [
            ("token-idle", idle, false),
            ("token-working", session(.working), false),
            ("token-needs-you", session(.working, pending: true), false),
            ("token-selected", session(.working), true),
            ("token-hung", session(.working, hung: true), false),
            ("token-paused", held(.pause, calls: 1), false),
            ("token-stopped", held(.stop, calls: 0), false),
        ]
        for (name, s, selected) in states {
            for (bgName, bg) in [("grey", AnyView(Color(white: 0.5))), ("photo", AnyView(photo))] {
                let v = ZStack {
                    bg
                    TokenView(model: model, session: s, selected: selected)
                }
                .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
                write(v, size: TokenMetrics.size, to: out.appendingPathComponent("\(name)-\(bgName).png"))
            }
        }

        let cardSize = CardMetrics.size
        func card(_ s: AgentSession, _ items: [ChatItem]?) -> some View {
            SessionCard(model: model, session: s, preset: items)
                .frame(width: cardSize.width, height: cardSize.height)
                .environment(\.solidBackground, true)
                .padding(0)
        }
        write(card(session(.working), chat), size: cardSize, to: out.appendingPathComponent("card-chat.png"))
        write(card(session(.working, pending: true), chat), size: cardSize, to: out.appendingPathComponent("card-permission.png"))
        var fb = session(.working)
        fb.steps = [
            Step(id: "1", toolName: "Read", summary: "Read src/App.tsx", startedAt: Date(), durationMs: 120, status: .ok),
            Step(id: "2", toolName: "Bash", summary: "$ npm test", startedAt: Date(), status: .running),
        ]
        write(card(fb, nil), size: cardSize, to: out.appendingPathComponent("card-fallback.png"))
        write(card(held(.pause, calls: 1), chat), size: cardSize, to: out.appendingPathComponent("card-paused.png"))

        // Questions and plans: sample requests through the normal event path.
        func requestCard(_ name: String, _ s: AgentSession, _ preset: RequestPreset? = nil) {
            let v = SessionCard(model: model, session: s, preset: chat, requestPreset: preset)
                .frame(width: cardSize.width, height: cardSize.height)
                .environment(\.solidBackground, true)
            write(v, size: cardSize, to: out.appendingPathComponent("\(name).png"))
        }
        requestCard("card-question-single", asking([sampleQuestions[0]]))
        var multi = QuestionDraft()
        multi.toggle(0, option: 1, multi: false)
        multi.toggle(1, option: 0, multi: true)
        multi.toggle(1, option: 2, multi: true)
        multi.toggleOther(2, multi: false)
        multi.other[2] = "Behind a feature flag, off by default"
        requestCard("card-question-multi", asking(sampleQuestions), RequestPreset(draft: multi))
        // The same request with one question: "Other…" with its text field is in view.
        var own = QuestionDraft()
        own.toggleOther(0, multi: false)
        own.other[0] = "Behind a feature flag, off by default, and only for signed-in users"
        requestCard("card-question-other", asking([sampleQuestions[2]]), RequestPreset(draft: own))
        requestCard("card-question-paused", asking([sampleQuestions[0]], hold: .pause))
        requestCard("card-question-expired", asking([sampleQuestions[0]], expired: true))
        requestCard("card-plan", planning())
        requestCard("card-plan-sendback", planning(),
                    RequestPreset(sendingBack: true, feedback: "Keep the old endpoint working until the mobile app is updated."))

        // The input bar is shown only for a session run by the app (a fixed object, no process).
        let inputId = "0f8fad5b-d9cb-469f-a165-708677289500", inputCwd = "/Users/dev/acme-web"
        var inputStore = SessionStore()
        let inputKey = inputStore.register(sessionId: inputId, cwd: inputCwd, host: .ownedByHud, now: Date().addingTimeInterval(-420))
        inputStore.apply(AgentEvent(kind: .claude, sessionId: inputId, cwd: inputCwd, time: Date().addingTimeInterval(-400),
                                    body: .sessionStarted(source: nil, model: "claude-sonnet-5-5")))
        model.installPreview(OwnedSession(previewId: inputId, cwd: inputCwd, state: .idle, items: chat, partialText: "",
                                          lastError: nil, stderrTail: "", notice: nil, costUSD: nil))
        func inputCard(_ preset: ChatInputPreset) -> some View {
            SessionCard(model: model, session: inputStore.session(inputKey)!, preset: chat, inputPreset: preset)
                .frame(width: cardSize.width, height: cardSize.height)
                .environment(\.solidBackground, true)
        }
        write(inputCard(ChatInputPreset(text: "/co", commands: sampleCommands, selectedRow: 1)),
              size: cardSize, to: out.appendingPathComponent("card-suggestions.png"))
        write(inputCard(ChatInputPreset(note: ChatInputNote(text: SendPlan.sentNote))),
              size: cardSize, to: out.appendingPathComponent("card-sent-hint.png"))
        write(inputCard(ChatInputPreset(note: ChatInputNote(text: SendPlan.copiedNote))),
              size: cardSize, to: out.appendingPathComponent("card-copy-hint.png"))
        write(inputCard(ChatInputPreset(text: "Run the tests", trusted: false)),
              size: cardSize, to: out.appendingPathComponent("card-helper-copy.png"))
        write(inputCard(ChatInputPreset(text: "Run the tests", note: ChatInputNote(text: PromptSender.lostFocusMessage, isError: true))),
              size: cardSize, to: out.appendingPathComponent("card-send-failed.png"))

        // Sessions run by the app: fixed session objects, no process is started.
        func ownedCard(_ name: String, _ id: String, _ state: OwnedSessionLogic.State, items: [ChatItem], partial: String = "",
                       error: String? = nil, stderr: String = "", notice: String? = nil, cost: Double? = nil, working: Bool = false) {
            let cwd = "/Users/dev/acme-web"
            var store = SessionStore()
            let key = store.register(sessionId: id, cwd: cwd, host: .ownedByHud, now: Date().addingTimeInterval(-420))
            func ev(_ body: AgentEvent.Body, _ t: TimeInterval) -> AgentEvent {
                AgentEvent(kind: .claude, sessionId: id, cwd: cwd, time: Date().addingTimeInterval(t), body: body)
            }
            if case .exited = state {
                _ = store.markEnded(key, now: Date())
            } else {
                store.apply(ev(.sessionStarted(source: nil, model: "claude-sonnet-5-5"), -400))
                store.apply(ev(.promptSubmitted("Fix the checkout form"), -390))
                if !working { store.apply(ev(.stopped(lastMessage: "Done.", failed: false), -5)) }
            }
            model.installPreview(OwnedSession(previewId: id, cwd: cwd, state: state, items: items, partialText: partial,
                                              lastError: error, stderrTail: stderr, notice: notice, costUSD: cost))
            write(card(store.session(key)!, nil), size: cardSize, to: out.appendingPathComponent("\(name).png"))
        }
        let done = Array(chat.dropLast()) + [
            ChatItem(id: "8", time: nil, kind: .tool(name: "Bash", summary: "$ npm test -- checkout", status: .ok)),
            ChatItem(id: "9", time: nil, kind: .assistant("All 42 tests pass now. The coupon is kept in the cart store, so going back a step no longer loses it.")),
        ]
        ownedCard("card-owned-idle", "0f8fad5b-d9cb-469f-a165-708677289501", .idle, items: done, cost: 0.42)
        // A message sent by voice: the marker travels to the Assistant but the card shows the plain text.
        ownedCard("card-owned-voice", "0f8fad5b-d9cb-469f-a165-708677289504", .idle, items: [
            ChatItem(id: "1", time: nil, kind: .user(SpokenStyle.mark("Open the quarterly report and tell me which sheet has the totals"))),
            ChatItem(id: "2", time: nil, kind: .assistant("The totals are on the Summary sheet, in the last column.")),
        ], cost: 0.05)
        ownedCard("card-owned-streaming", "0f8fad5b-d9cb-469f-a165-708677289502", .running,
                  items: Array(chat.prefix(6)),
                  partial: "One test fails: the fixture has no coupon. I'll update the fixture and run the suite again, then check that the",
                  notice: "Retrying the request (attempt 2 of 10): overloaded", cost: 0.31, working: true)
        ownedCard("card-owned-error", "0f8fad5b-d9cb-469f-a165-708677289503", .exited(1), items: [],
                  error: "Claude Code exited before the session started (code 1)",
                  stderr: "Error: Invalid API key · Please run /login\n    at validateAuth (cli.js:4411:19)\n    at async main (cli.js:5120:5)")

        // An ended session of an editor: it can go on in a process of the app.
        do {
            let id = "0f8fad5b-d9cb-469f-a165-708677289504", cwd = "/Users/dev/acme-web"
            let host = HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)
            var store = SessionStore()
            let events: [(AgentEvent.Body, TimeInterval)] = [
                (.sessionStarted(source: nil, model: "claude-sonnet-5-5"), -900), (.promptSubmitted("Fix the checkout form"), -890),
                (.stopped(lastMessage: "Done.", failed: false), -300), (.sessionEnded(reason: nil), -1),
            ]
            for (body, t) in events {
                store.apply(AgentEvent(kind: .claude, sessionId: id, cwd: cwd, host: host, time: Date().addingTimeInterval(t), body: body))
            }
            write(card(store.session("claude:\(id)")!, done), size: cardSize, to: out.appendingPathComponent("card-ended-continue.png"))
        }

        renderCommandBar(model: model, out: out, cardSize: cardSize, card: { s in card(s, nil) })

        let recent = ["/Users/dev/acme-web", "/Users/dev/acme-api", "/Users/dev/Developer/client-projects/storefront/mobile",
                      "/Users/dev/tools/release-notes"]
        let sheetSize = CGSize(width: NewSessionMetrics.width, height: NewSessionMetrics.height)
        write(NewSessionView(model: NewSessionModel(folder: recent[0], recent: recent, message: "Find out why the coupon is lost when going back a step"))
                .tint(Brand.accent),
              size: sheetSize, to: out.appendingPathComponent("new-session-sheet.png"))
        write(NewSessionView(model: NewSessionModel(folder: recent[2], recent: recent,
                                                    problem: "Agent HUD is not connected to Claude Code, so the agent's permission requests could not reach you. Connect it in the setup window first.",
                                                    offersSetup: true)).tint(Brand.accent),
              size: sheetSize, to: out.appendingPathComponent("new-session-sheet-refused.png"))

        // The "Continue" tab: synthetic rows, nothing is read from disk.
        let now = Date()
        func past(_ n: Int, _ cwd: String, _ title: String, _ ago: TimeInterval) -> PastSession {
            PastSession(id: "0f8fad5b-d9cb-469f-a165-70867728950\(n)", cwd: cwd, title: title,
                        lastActivity: now.addingTimeInterval(-ago), sizeBytes: 120_000)
        }
        let pastRows = [
            past(1, "/Users/dev/acme-web", "Fix the coupon lost when going back a step in checkout", 5 * 60),
            past(2, "/Users/dev/acme-web", "Add order filters to the admin table", 3 * 3600),
            past(3, "/Users/dev/acme-web", "Untitled session", 26 * 3600),
            past(4, "/Users/dev/Developer/client-projects/storefront/mobile", "Rename the onboarding screens and update the navigation graph so the deep links keep working", 3 * 86400),
            past(5, "/Users/dev/Developer/client-projects/storefront/mobile", "Why does the build fail on CI only", 9 * 86400),
            past(6, "/Users/dev/Developer/client-projects/storefront/mobile", "Bump dependencies", 40 * 86400),
        ]
        func continueModel(rows: [PastSession], search: String = "", selected: String? = nil) -> NewSessionModel {
            NewSessionModel(tab: .continueSession, past: rows, search: search, selectedPast: selected)
        }
        write(NewSessionView(model: continueModel(rows: pastRows, selected: pastRows[1].id)).tint(Brand.accent),
              size: sheetSize, to: out.appendingPathComponent("new-session-continue.png"))
        write(NewSessionView(model: continueModel(rows: [])).tint(Brand.accent),
              size: sheetSize, to: out.appendingPathComponent("new-session-continue-empty.png"))
        write(NewSessionView(model: continueModel(rows: pastRows, search: "mobile", selected: pastRows[3].id)).tint(Brand.accent),
              size: sheetSize, to: out.appendingPathComponent("new-session-continue-search.png"))

        // Fake statuses only: the render check never calls the real probes.
        func fake(_ s: PermissionStatus) -> [PermissionKind: PermissionState] {
            Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState(status: s)) })
        }
        var mixed = fake(.notGranted)
        mixed[.hooks] = PermissionState(status: .notGranted, detail: "Needs an update")
        mixed[.accessibility] = PermissionState(status: .granted)
        mixed[.automation] = PermissionState(status: .unknown, detail: "Only for sessions in Terminal or iTerm. Allow… opens Terminal and asks.")
        let setups: [(String, [PermissionKind: PermissionState], Bool)] = [
            ("setup-all-granted", fake(.granted), false),
            ("setup-nothing-granted", fake(.notGranted), true),
            ("setup-mixed", mixed, true),
        ]
        for (name, st, source) in setups {
            let v = SetupView(model: SetupModel(states: st, showsSourceBuildNote: source)).tint(Brand.accent)
            write(v, size: CGSize(width: SetupMetrics.width, height: SetupMetrics.height), to: out.appendingPathComponent("\(name).png"))
        }
        // The two voice rows, with voice switched on, in a window tall enough to show every row.
        var voiceStates = fake(.granted)
        voiceStates[.microphone] = PermissionState(status: .notGranted)
        voiceStates[.speechRecognition] = PermissionState(status: .notGranted)
        let voiceSetup = SetupModel(states: voiceStates)
        voiceSetup.inUse = VoicePermissions.inUse(voiceEnabled: true)
        write(SetupView(model: voiceSetup, height: 960).tint(Brand.accent),
              size: CGSize(width: SetupMetrics.width, height: 960), to: out.appendingPathComponent("setup-voice-rows.png"))
        let highlighted = SetupModel(states: mixed)
        highlighted.highlight = .accessibility
        write(SetupView(model: highlighted).tint(Brand.accent),
              size: CGSize(width: SetupMetrics.width, height: SetupMetrics.height), to: out.appendingPathComponent("setup-highlight.png"))

        for (name, st) in [("settings-permissions-ok", fake(.granted)), ("control-panel-limited", mixed)] {
            let panel = ControlPanelView(model: model, settings: model.settings,
                                         permissions: Permissions.summary(st.mapValues(\.status)), tab: 1)
                .tint(Brand.accent)
            let size = NSHostingView(rootView: panel).fittingSize
            write(panel, size: size, to: out.appendingPathComponent("\(name).png"))
        }

        do {
            let panel = ControlPanelView(model: model, settings: model.settings, tab: 0).tint(Brand.accent)
            write(panel, size: NSHostingView(rootView: panel).fittingSize, to: out.appendingPathComponent("control-panel-sessions.png"))
        }

        for (name, s) in [("hold-popover-paused", held(.pause, calls: 5)), ("hold-popover-stopped", held(.stop, calls: 0))] {
            guard let hold = s.hold else { continue }
            let size = HoldPopoverMetrics.size(for: s)
            let v = HoldPopover(session: s, hold: hold, resume: {})
                .frame(width: size.width, height: size.height)
                .environment(\.solidBackground, true)
                .tint(Brand.accent)
            write(v, size: size, to: out.appendingPathComponent("\(name).png"))
        }

        renderAvatars(model: model, out: out)
        renderLooks(model: model, out: out)
        renderActs(model: model, out: out)
        renderRoutines(model: model, out: out)
    }

    /// The animated avatar styles: every state at 96 pt on a dark and a light strip (fixed time), and the appearance section.
    private static func renderAvatars(model: AppModel, out: URL) {
        let states: [AgentState] = [.idle, .working, .waitingPermission, .paused, .stopped, .done, .error]
        // Seeds with chosen hue (low 10 bits) and body variant (bits from 12).
        let seeds: [UInt64] = [530, 893 | (1 << 12), 111 | (2 << 12)]
        func strip(_ style: AvatarStyle, seed: UInt64, dark: Bool, time: Double) -> some View {
            HStack(spacing: 6) {
                ForEach(states, id: \.rawValue) { st in
                    AvatarView(seed: seed, state: st, style: style, size: 96, animated: false, stillTime: time)
                        .frame(width: 100, height: 100)
                }
            }
            .padding(10)
            .background(dark ? AnyView(LinearGradient(colors: [Color(red: 0.23, green: 0.19, blue: 0.44), Color(red: 0.04, green: 0.05, blue: 0.1)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                             : AnyView(LinearGradient(colors: [Color(red: 0.96, green: 0.87, blue: 0.8), Color(red: 0.83, green: 0.89, blue: 0.96)],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing)))
        }
        let size = CGSize(width: 7 * 106 + 14, height: 3 * 120 + 12)
        for style in AvatarStyle.allCases where style.isExtra {
            for (name, time) in [("", 2.2), ("-t2", 3.1)] {
                let v = VStack(spacing: 0) {
                    strip(style, seed: seeds[0], dark: true, time: time)
                    strip(style, seed: seeds[1], dark: false, time: time + 0.7)
                    strip(style, seed: seeds[2], dark: true, time: time + 1.3)
                }
                .frame(width: size.width, height: size.height)
                write(v, size: size, to: out.appendingPathComponent("avatars-new-\(style.rawValue)\(name).png"))
            }
        }
        let panel = ControlPanelView(model: model, settings: model.settings, tab: 1).tint(Brand.accent)
        write(panel, size: NSHostingView(rootView: panel).fittingSize, to: out.appendingPathComponent("control-panel-appearance.png"))
    }

    /// Routines: the tab (empty, and with four routines in mixed states), the editor and a labelled token.
    /// Sample values only - the file and the log are not read, and no session is started.
    private static func renderRoutines(model: AppModel, out: URL) {
        let settings = model.settings
        let had = settings.routinesEnabled
        settings.routinesEnabled = true
        defer { settings.routinesEnabled = had }
        let now = Date()
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        func rec(_ id: String, _ o: RoutineLogRecord.Outcome, _ s: TimeInterval) -> RoutineHistory {
            let r = RoutineLogRecord(time: ago(s), routine: id, outcome: o)
            return RoutineHistory(lastRun: o == .started || o == .finished || o == .failed ? r.time : nil, lastAttempt: r.time, last: r)
        }

        func tab(_ name: String, _ routines: RoutineController) {
            // A tall limit: the real tab scrolls on a short screen, the picture should show every row.
            let panel = ControlPanelView(model: model, settings: settings, tab: 3, screenTabLimit: 1400).tint(Brand.accent)
            write(panel, size: NSHostingView(rootView: panel).fittingSize, to: out.appendingPathComponent("\(name).png"))
        }
        model.routines.installPreview(set: RoutineSet(), history: [:])
        tab("routines-tab-empty", model.routines)

        let list = [
            Routine(id: "morning-report", name: "Morning report", prompt: "Summarise the open pull requests", folder: "/Users/dev/acme-web",
                    schedule: .daily(hour: 9, minute: 0, weekdays: Set(1...5))),
            Routine(id: "dependency-check", name: "Dependency check and audit of the whole monorepo", prompt: "Check the dependencies",
                    folder: "/Users/dev/storefront/mobile", schedule: .every(hours: 4)),
            Routine(id: "release-notes", name: "Release notes", prompt: "Draft the release notes", folder: "/Users/dev/gone",
                    schedule: .daily(hour: 18, minute: 30, weekdays: [5])),
            Routine(id: "archive", name: "Archive old logs", prompt: "Archive logs", enabled: false, schedule: .manual),
        ]
        var broken = RoutineSet(routines: list, problems: [
            "Routine nightly: unknown schedule kind \"weekly\" - skipped",
            "Routine #6: a prompt is required - skipped",
        ])
        broken.routines = list
        model.routines.installPreview(
            set: broken,
            history: [
                "morning-report": rec("morning-report", .finished, 2 * 3600),
                "dependency-check": rec("dependency-check", .started, 600),
                "release-notes": rec("release-notes", .skipped("folder missing"), 7200),
                "archive": rec("archive", .failed, 3 * 86400),
            ],
            running: ["dependency-check"])
        tab("routines-tab-mixed", model.routines)

        model.routines.installPreview(set: RoutineSet(routines: [list[0], list[1]]), history: [
            "morning-report": rec("morning-report", .skipped("still running"), 300),
            "dependency-check": rec("dependency-check", .needsYou, 900),
        ], queued: ["morning-report"])
        tab("routines-tab-waiting", model.routines)
        model.routines.installPreview(set: RoutineSet(routines: [list[1]]), history: [
            "dependency-check": rec("dependency-check", .expired, 1800),
        ])
        tab("routines-tab-expired", model.routines)
        model.routines.installPreview(set: RoutineSet(), history: [:])

        func editor(_ name: String, _ m: RoutineEditorModel) {
            // Taller than the real window, which scrolls: every section is in the picture.
            write(RoutineEditorView(model: m, height: 1080).tint(Brand.accent), size: CGSize(width: RoutineEditorMetrics.width, height: 1080),
                  to: out.appendingPathComponent("\(name).png"))
        }
        let recent = ["/Users/dev/acme-web", "/Users/dev/storefront/mobile", "/Users/dev/acme-api"]
        editor("routine-editor-daily", RoutineEditorModel(routine: list[0], recent: recent))
        var everyEdit = list[1]
        everyEdit.name = ""
        let invalid = RoutineEditorModel(routine: everyEdit, recent: recent)
        invalid.prompt = String(repeating: "Check everything. ", count: 240)
        invalid.showProblems = true
        editor("routine-editor-every-invalid", invalid)
        let fresh = RoutineEditorModel(routine: nil, recent: recent)
        editor("routine-editor-new", fresh)

        // A token of a run started by a routine carries the routine's name instead of the project.
        let id = "0f8fad5b-d9cb-469f-a165-708677289521", cwd = "/Users/dev/acme-web"
        var store = SessionStore()
        let key = store.register(sessionId: id, cwd: cwd, host: .ownedByHud, now: now.addingTimeInterval(-60))
        store.apply(AgentEvent(kind: .claude, sessionId: id, cwd: cwd, time: now.addingTimeInterval(-50),
                               body: .sessionStarted(source: nil, model: "claude-sonnet-5-5")))
        let o = OwnedSession(previewId: id, cwd: cwd, state: .running, items: [])
        o.routineLabel = "Morning report"
        model.installPreview(o)
        for (bgName, bg) in [("grey", AnyView(Color(white: 0.5))), ("photo", AnyView(photo))] {
            let v = ZStack { bg; TokenView(model: model, session: store.session(key)!, selected: false) }
                .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
            write(v, size: TokenMetrics.size, to: out.appendingPathComponent("token-routine-\(bgName).png"))
        }
    }

    /// Agents acting in other apps: request cards, the hand on the icon and the settings.
    /// Sample values only - no window is listed, nothing is pressed, clicked or typed, and no setting is written.
    private static func renderActs(model: AppModel, out: URL) {
        let now = Date()
        let cardSize = CardMetrics.size
        let demo = session(.working)
        let mail = ActSubject(app: "Mail", bundleId: "com.apple.mail", windowTitle: "Re: Invoice 2041 — Inbox",
                              elementRole: "AXButton", elementLabel: "Send")
        let notes = ActSubject(app: "Notes", bundleId: "com.apple.Notes", windowTitle: "Release checklist")
        let safari = ActSubject(app: "Safari", bundleId: "com.apple.Safari", windowTitle: "Checkout — Acme Store — Private Browsing")
        func pending(_ body: ActCall.Body, _ subject: ActSubject, offers: Bool = false, risky: Bool = false) -> ActPending {
            ActPending(id: "act1", sessionKey: demo.id, call: ActCall(window: 4021, body: body), subject: subject,
                       createdAt: now, deadline: now.addingTimeInterval(97), offersApp: offers, risky: risky)
        }
        func card(_ name: String, _ s: AgentSession) {
            let v = SessionCard(model: model, session: s, preset: chat)
                .frame(width: cardSize.width, height: cardSize.height)
                .environment(\.solidBackground, true)
            write(v, size: cardSize, to: out.appendingPathComponent("\(name).png"))
        }

        model.installActPreview(pending: [pending(.pressElement(element: 12), mail, offers: true)])
        card("card-act-press", demo)
        for (bgName, bg) in [("grey", AnyView(Color(white: 0.5))), ("photo", AnyView(photo))] {
            let v = ZStack {
                bg
                TokenView(model: model, session: demo, selected: false)
            }
            .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
            write(v, size: TokenMetrics.size, to: out.appendingPathComponent("token-acting-\(bgName).png"))
        }

        // A long text with newlines: all of it is on the card, inside a box that scrolls.
        let typedText = """
        Release checklist
        1. Run the test suite on Linux
        2. Bump the version to 0.2.2
        3. Update the changelog:\tfixes for the coupon field, the order filters and the admin table
        4. Tag the release
        5. Tell the support team that the old endpoint stays until the mobile app is updated

        Notes: the staging database was refreshed on Monday, so the order ids start again from 1000.
        """
        model.installActPreview(pending: [pending(.typeText(typedText), notes, offers: true)])
        card("card-act-type", demo)
        model.installActPreview(pending: [pending(.typeText("npm test"), notes)])
        card("card-act-type-short", demo)

        model.installActPreview(pending: [pending(.pressKeys(KeyCombo(modifiers: [.cmd, .shift], key: "w")), safari, risky: true)])
        card("card-act-keys-risky", demo)
        model.installActPreview(pending: [pending(.pressKeys(KeyCombo(modifiers: .cmd, key: "s")), notes, offers: true)])
        card("card-act-keys", demo)
        model.installActPreview(pending: [pending(.clickAt(x: 412, y: 236, button: .left, count: 2), safari)])
        card("card-act-click", demo)
        model.installActPreview(pending: [pending(.scroll(dx: 0, dy: 12), safari, offers: true)])
        card("card-act-scroll", demo)
        model.installActPreview(pending: [ActPending(id: "act1", sessionKey: demo.id, call: ActCall(window: nil, body: .openApp(.name("Notes"))),
                                                     subject: ActSubject(app: "Notes", bundleId: "com.apple.Notes"),
                                                     createdAt: now, deadline: now.addingTimeInterval(97), offersApp: true)])
        card("card-act-open-app", demo)
        // The same request together with a held session's banner.
        model.installActPreview(pending: [pending(.focusWindow, safari)])
        card("card-act-focus-paused", held(.pause, calls: 1))

        // After an action, and a refusal for the missing permission.
        model.installActPreview()
        model.installLookPreview(notes: [demo.id: [
            LookNote(time: now.addingTimeInterval(-95), text: "Looked at: text of Mail — Re: Invoice 2041 — Inbox"),
            LookNote(time: now.addingTimeInterval(-20), text: ActLabels.didRow(ActCall(window: 4021, body: .pressElement(element: 12)), mail),
                     symbol: "hand.point.up.left"),
        ]])
        card("card-act-notes", demo)
        model.installLookPreview()
        model.installActPreview(blocked: [demo.id])
        card("card-act-no-permission", demo)
        model.installActPreview()
        // The Assistant's memory: a save with its Undo button, and a removal.
        model.installMemoryPreview(notes: [demo.id: [
            MemoryNote(time: now.addingTimeInterval(-40), text: "Forgot: I prefer tea to coffee"),
            MemoryNote(time: now.addingTimeInterval(-5), text: "Remembered: I like short answers", entryId: "a1b2c3"),
        ]])
        card("card-memory-notice", demo)
        model.installMemoryPreview()
        // While the action runs there is no card, only the hand on the icon.
        model.installActPreview(acting: [demo.id])
        let running = ZStack {
            Color(white: 0.5)
            TokenView(model: model, session: demo, selected: false)
        }
        .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
        write(running, size: TokenMetrics.size, to: out.appendingPathComponent("token-acting-running.png"))
        model.installActPreview()

        // Settings: fixed names and values, so the picture does not depend on this Mac or on the stored settings.
        let names = ["com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password 7",
                     "com.apple.keychainaccess": "Keychain Access", "com.apple.Passwords": "Passwords",
                     "com.apple.systempreferences": "System Settings"]
        let stopped = Calendar.current.date(bySettingHour: 14, minute: 32, second: 0, of: now) ?? now
        let states: [(String, HandsAccessMode, Date?)] = [
            ("control-panel-hands-off", .off, nil), ("control-panel-hands-ask", .ask, nil),
            ("control-panel-hands-per-app", .perApp, nil), ("control-panel-hands-stopped", .off, stopped),
        ]
        for (name, mode, stoppedAt) in states {
            let v = HandsAccessSection(index: 2, mode: .constant(mode), stoppedAt: stoppedAt,
                                       alwaysExcluded: ActExclusions.always(ownBundleId: HostInfo.agentHud), appName: { names[$0] })
                .padding(16)
                .frame(width: ControlPanelView.width)
                .background(Brand.bg)
                .tint(Brand.accent)
            write(v, size: NSHostingView(rootView: v).fittingSize, to: out.appendingPathComponent("\(name).png"))
        }
    }

    /// Agents looking at the screen: request cards, the eye on the icon, the settings and the setup row.
    /// Sample values only - no window is listed, nothing is captured and no command is run.
    private static func renderLooks(model: AppModel, out: URL) {
        let now = Date()
        let cardSize = CardMetrics.size
        let demo = session(.working)
        let safari = WindowInfo(number: 4021, app: "Safari", bundleId: "com.apple.Safari", pid: 0,
                                title: "Checkout — Acme Store — Private Browsing", width: 1440, height: 900, frontmost: true)
        func pending(_ key: String, _ call: LookCall, window: WindowInfo? = nil, front: String? = nil, offers: Bool = true) -> LookPending {
            LookPending(id: "look1", sessionKey: key, call: call, window: window, frontApp: front,
                        createdAt: now, deadline: now.addingTimeInterval(97), offersSession: offers)
        }
        func card(_ name: String, _ s: AgentSession) {
            let v = SessionCard(model: model, session: s, preset: chat)
                .frame(width: cardSize.width, height: cardSize.height)
                .environment(\.solidBackground, true)
            write(v, size: cardSize, to: out.appendingPathComponent("\(name).png"))
        }

        model.installLookPreview(pending: [pending(demo.id, LookCall(tool: .screenshot, target: .window(4021)), window: safari)])
        card("card-look-screenshot", demo)
        for (bgName, bg) in [("grey", AnyView(Color(white: 0.5))), ("photo", AnyView(photo))] {
            let v = ZStack {
                bg
                TokenView(model: model, session: demo, selected: false)
            }
            .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
            write(v, size: TokenMetrics.size, to: out.appendingPathComponent("token-looking-\(bgName).png"))
        }
        model.installLookPreview(pending: [pending(demo.id, LookCall(tool: .screenshot, target: .screen), front: "Safari")])
        card("card-look-screen", demo)
        model.installLookPreview(pending: [pending(demo.id, LookCall(tool: .readWindowText, target: .window(4021)), window: safari)])
        card("card-look-text", demo)
        // The same request together with a held session: the hold banner and the look card share the card.
        model.installLookPreview(pending: [pending(demo.id, LookCall(tool: .listWindows))])
        card("card-look-list-paused", held(.pause, calls: 1))

        // A caller that matched no session: the neutral entry, and no "for this session" answer.
        var unknownStore = SessionStore()
        let unknownKey = unknownStore.register(sessionId: LookLabels.unknownSessionId, cwd: "", host: HostInfo(), now: now)
        unknownStore.apply(AgentEvent(kind: .claude, sessionId: LookLabels.unknownSessionId, cwd: "", time: now,
                                      body: .sessionStarted(source: nil, model: nil)))
        if let unknown = unknownStore.session(unknownKey) {
            model.installLookPreview(pending: [pending(unknownKey, LookCall(tool: .screenshot, target: .screen), front: "Safari", offers: false)])
            card("card-look-unknown-session", unknown)
            let v = ZStack {
                Color(white: 0.5)
                TokenView(model: model, session: unknown, selected: false)
            }
            .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
            write(v, size: TokenMetrics.size, to: out.appendingPathComponent("token-looking-unknown.png"))
        }

        // After the looks: what the card keeps, and a refusal for a missing permission.
        model.installLookPreview(notes: [demo.id: [
            LookNote(time: now.addingTimeInterval(-95), text: "Looked at: the list of open windows"),
            LookNote(time: now.addingTimeInterval(-20), text: "Looked at: Safari — Checkout — Acme Store — Private Browsing"),
        ]])
        card("card-look-notes", demo)
        model.installLookPreview(blocked: [demo.id: .screenRecording])
        card("card-look-no-permission", demo)
        model.installLookPreview()

        // Settings: fixed names, so the picture does not depend on what is installed on this Mac.
        let names = ["com.1password.1password": "1Password", "com.apple.keychainaccess": "Keychain Access",
                     "com.apple.Passwords": "Passwords", "com.apple.systempreferences": "System Settings",
                     "com.tinyspeck.slackmacgap": "Slack"]
        for (name, mode, apps) in [("control-panel-screen-access", ScreenAccessMode.ask, LookExclusions.defaults),
                                   ("control-panel-screen-access-session", .session, LookExclusions.defaults + ["com.tinyspeck.slackmacgap"]),
                                   ("control-panel-screen-access-off", .off, [])] {
            let v = ScreenAccessSection(index: 1, mode: .constant(mode), excluded: .constant(apps), appName: { names[$0] })
                .padding(16)
                .frame(width: ControlPanelView.width)
                .background(Brand.bg)
                .tint(Brand.accent)
            write(v, size: NSHostingView(rootView: v).fittingSize, to: out.appendingPathComponent("\(name).png"))
        }

        // The whole panel on its "Screen" tab, with the stored settings (read only; nothing is written).
        do {
            let panel = ControlPanelView(model: model, settings: model.settings, tab: 2).tint(Brand.accent)
            write(panel, size: NSHostingView(rootView: panel).fittingSize, to: out.appendingPathComponent("control-panel-screen-tab.png"))
            // On a short screen the two sections scroll and the footer stays in view.
            let short = ControlPanelView(model: model, settings: model.settings, tab: 2, screenTabLimit: 420).tint(Brand.accent)
            write(short, size: NSHostingView(rootView: short).fittingSize, to: out.appendingPathComponent("control-panel-screen-tab-short.png"))
        }

        let granted = Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, PermissionState(status: .granted)) })
        var partly = granted
        partly[.screenRecording] = PermissionState(status: .notGranted)
        partly[.accessibility] = PermissionState(status: .notGranted)
        let setups: [(String, [PermissionKind: PermissionState], ScreenToolsState)] = [
            ("setup-screen-tools-connected", granted, ScreenToolsState(status: .registered)),
            ("setup-screen-tools-not-connected", partly, ScreenToolsState(status: .notRegistered)),
            ("setup-screen-tools-unknown", partly, ScreenToolsState(status: .unknown, detail: "Claude Code not found")),
        ]
        for (name, states, tools) in setups {
            let v = SetupView(model: SetupModel(states: states, showsSourceBuildNote: false, screenTools: tools)).tint(Brand.accent)
            write(v, size: CGSize(width: SetupMetrics.width, height: SetupMetrics.height), to: out.appendingPathComponent("\(name).png"))
        }
    }

    /// A held session: paused with 12:41 left, or stopped 8 minutes ago, with `calls` tool calls waiting.
    /// Command bar views with fixed state, a card with a queued message, and the hotkey row of the control panel.
    private static func renderCommandBar<C: View>(model: AppModel, out: URL, cardSize: CGSize, card: (AgentSession) -> C) {
        let live = [CommandBarLiveSession(sessionId: "0f8fad5b-d9cb-469f-a165-708677289511", projectName: "acme-web", cwd: "/Users/dev/acme-web"),
                    CommandBarLiveSession(sessionId: "0f8fad5b-d9cb-469f-a165-708677289512", projectName: "storefront/mobile", cwd: "/Users/dev/storefront/mobile")]
        let entries = CommandBarLogic.entries(live: live, assistantSessionId: nil)
        func bar(_ name: String, _ m: CommandBarModel) {
            let view = ZStack(alignment: .top) { Color(white: 0.55); CommandBarView(model: m).tint(Brand.accent) }
            let fit = NSHostingView(rootView: CommandBarView(model: m).frame(width: CommandBarLogic.barWidth).fixedSize(horizontal: false, vertical: true))
            let h = ceil(fit.fittingSize.height)
            write(view.frame(width: CommandBarLogic.barWidth, height: h), size: CGSize(width: CommandBarLogic.barWidth, height: h),
                  to: out.appendingPathComponent("\(name).png"))
        }
        bar("command-bar-empty", CommandBarModel(previewText: "", entries: entries))
        bar("command-bar-typed", CommandBarModel(previewText: "Open the quarterly report in Numbers\nand tell me which sheet has the totals",
                                                 entries: entries))
        bar("command-bar-suggestions", CommandBarModel(previewText: "/co", entries: entries, target: .session(live[0].sessionId),
                                                       commands: sampleCommands, row: 1))
        bar("command-bar-busy", CommandBarModel(previewText: "Now do the same for the March file", entries: entries, busy: true))
        bar("command-bar-refused", CommandBarModel(previewText: "Open Mail", entries: entries,
                                                   status: CommandBarModel.Status(text: "Agent HUD is not connected to Claude Code, so the agent's permission requests could not reach you. Connect it in the setup window first.", isError: true)))
        // Voice: fixed states only, no engine is built.
        bar("command-bar-listening", CommandBarModel(previewText: "", entries: entries,
                                                     voice: .listening(level: 0.55, partial: "Open the quarterly report in Numbers and tell me which sheet has the totals")))
        bar("command-bar-listening-start", CommandBarModel(previewText: "", entries: entries, voice: .listening(level: 0, partial: "")))
        bar("command-bar-countdown", CommandBarModel(previewText: "Open the quarterly report in Numbers and tell me which sheet has the totals",
                                                     entries: entries, voice: .countdown))
        bar("command-bar-no-mic-permission", CommandBarModel(previewText: "", entries: entries, voice: .missing([.microphone])))
        bar("command-bar-no-permissions", CommandBarModel(previewText: "", entries: entries, voice: .missing([.microphone, .speechRecognition])))
        let russian = VoiceLanguages.info(code: "ru-RU")
        if case .unavailable(let message) = VoiceAvailability.decide(recognizerAvailable: true, supportsOnDevice: false, allowServer: false,
                                                                    languageLabel: russian.label) {
            bar("command-bar-not-on-device", CommandBarModel(previewText: "", entries: entries,
                                                             status: CommandBarModel.Status(text: message, isError: true)))
        }
        bar("command-bar-didnt-catch", CommandBarModel(previewText: "", entries: entries,
                                                       status: CommandBarModel.Status(text: VoiceText.didntCatch)))
        bar("command-bar-target-menu-open", CommandBarModel(previewText: "", entries: entries, target: .session(live[0].sessionId), menuOpen: true))
        let menu = ZStack { Brand.bg; TargetMenuList(entries: entries, selected: .assistant).padding(12) }
            .frame(width: 300).fixedSize(horizontal: false, vertical: true)
        let menuSize = NSHostingView(rootView: menu).fittingSize
        write(menu, size: CGSize(width: 300, height: ceil(menuSize.height)), to: out.appendingPathComponent("command-bar-target-menu.png"))

        // A card with a queued message: the row sits between the conversation and the input.
        let id = "0f8fad5b-d9cb-469f-a165-708677289521", cwd = "/Users/dev/acme-web"
        var store = SessionStore()
        let key = store.register(sessionId: id, cwd: cwd, host: .ownedByHud, now: Date().addingTimeInterval(-420))
        store.apply(AgentEvent(kind: .claude, sessionId: id, cwd: cwd, time: Date().addingTimeInterval(-400),
                               body: .sessionStarted(source: nil, model: "claude-sonnet-5-5")))
        store.apply(AgentEvent(kind: .claude, sessionId: id, cwd: cwd, time: Date().addingTimeInterval(-390), body: .promptSubmitted("Fix the checkout form")))
        model.installPreview(OwnedSession(previewId: id, cwd: cwd, state: .running, items: chat, partialText: "Checking the fixture"))
        model.installQueuePreview(sessionId: id, text: "Then run the linter and fix what it reports in the checkout folder")
        write(card(store.session(key)!).frame(width: cardSize.width, height: cardSize.height).environment(\.solidBackground, true),
              size: cardSize, to: out.appendingPathComponent("card-queued.png"))

        // Control panel: the hotkey row, free and taken.
        let settings = model.settings
        let saved = settings.commandBarHotKey
        settings.commandBarHotKey = "optSpace"
        for (name, taken) in [("control-panel-hotkey", false), ("control-panel-hotkey-taken", true)] {
            let v = CommandBarSettingsSection(index: 3, settings: settings, taken: taken, clear: {})
                .padding(16).frame(width: ControlPanelView.width).background(Brand.bg)
            let s = NSHostingView(rootView: v.fixedSize(horizontal: false, vertical: true)).fittingSize
            write(v.tint(Brand.accent), size: CGSize(width: ControlPanelView.width, height: ceil(s.height)),
                  to: out.appendingPathComponent("\(name).png"))
        }
        settings.commandBarHotKey = saved

        // Control panel: the Voice section, off and on (plain bindings: the saved settings stay as they are).
        // Fake voice lists only. "choice": a voice picked for English; Russian stays on automatic.
        let fakeVoices = Self.fakeVoices
        let ava = fakeVoices[0].id
        for (name, on, server, english, voices) in [("control-panel-voice-off", false, false, "", fakeVoices),
                                                    ("control-panel-voice-on", true, false, "", fakeVoices),
                                                    ("control-panel-voice-on-server", true, true, "", fakeVoices),
                                                    ("control-panel-voice-choice", true, false, ava, fakeVoices),
                                                    ("control-panel-voice-none-installed", true, false, "", [VoiceInfo]())] {
            let v = VoiceSettingsSection(index: 4, enabled: .constant(on), language: .constant("en-US"), sendAfterSpeaking: .constant(true),
                                         speakReplies: .constant(true), allowServer: .constant(server), voices: voices,
                                         voiceIdEnglish: .constant(english), voiceIdRussian: .constant(""), voiceRate: .constant(1.0),
                                         engine: .constant(.system), neuralSpeakerEnglish: .constant(0), neuralSpeakerRussian: .constant(3))
                .padding(16).frame(width: ControlPanelView.width).background(Brand.bg)
            let s = NSHostingView(rootView: v.fixedSize(horizontal: false, vertical: true)).fittingSize
            write(v.tint(Brand.accent), size: CGSize(width: ControlPanelView.width, height: ceil(s.height)),
                  to: out.appendingPathComponent("\(name).png"))
        }
        // The engine row: neural installed with System selected, neural installed and selected, and neural not installed
        // (a stored Neural choice then shows as System).
        for (name, engine, installed) in [("control-panel-voice-engine-system", VoiceEngine.system, true),
                                          ("control-panel-voice-engine-neural", VoiceEngine.neural, true),
                                          ("control-panel-voice-engine-missing", VoiceEngine.neural, false)] {
            let v = VoiceSettingsSection(index: 4, enabled: .constant(true), language: .constant("en-US"), sendAfterSpeaking: .constant(true),
                                         speakReplies: .constant(true), allowServer: .constant(false), voices: fakeVoices,
                                         voiceIdEnglish: .constant(""), voiceIdRussian: .constant(""), voiceRate: .constant(1.0),
                                         engine: .constant(engine), neuralInstalled: installed,
                                         neuralSpeakerEnglish: .constant(0), neuralSpeakerRussian: .constant(3))
                .padding(16).frame(width: ControlPanelView.width).background(Brand.bg)
            let s = NSHostingView(rootView: v.fixedSize(horizontal: false, vertical: true)).fittingSize
            write(v.tint(Brand.accent), size: CGSize(width: ControlPanelView.width, height: ceil(s.height)),
                  to: out.appendingPathComponent("\(name).png"))
        }
        // Control panel: the Memory section - off and empty, on with three notes, and a broken file.
        let sample = [MemoryEntry(id: "a1b2c3", text: "I like short answers", created: "2026-11-20T09:00:00Z"),
                      MemoryEntry(id: "d4e5f6", text: "I live in Dushanbe and work from home", created: "2026-11-21T10:30:00Z"),
                      MemoryEntry(id: "0a9b8c", text: "Call me Sam", created: "2026-11-24T18:05:00Z")]
        for (name, on, entries, broken) in [("control-panel-memory-off", false, [MemoryEntry](), false),
                                            ("control-panel-memory-on", true, sample, false),
                                            ("control-panel-memory-broken", true, [MemoryEntry](), true)] {
            let v = MemorySettingsSection(index: 5, enabled: .constant(on), entries: entries, broken: broken)
                .padding(16).frame(width: ControlPanelView.width).background(Brand.bg)
            let s = NSHostingView(rootView: v.fixedSize(horizontal: false, vertical: true)).fittingSize
            write(v.tint(Brand.accent), size: CGSize(width: ControlPanelView.width, height: ceil(s.height)),
                  to: out.appendingPathComponent("\(name).png"))
        }
        // The speed slider at its two ends.
        for (name, rate) in [("control-panel-voice-slow", 0.8), ("control-panel-voice-fast", 1.3)] {
            let v = VoiceSettingsSection(index: 4, enabled: .constant(true), language: .constant("ru-RU"), sendAfterSpeaking: .constant(true),
                                         speakReplies: .constant(true), allowServer: .constant(false), voices: fakeVoices,
                                         voiceIdEnglish: .constant(""), voiceIdRussian: .constant(fakeVoices[3].id), voiceRate: .constant(rate),
                                         engine: .constant(.system), neuralSpeakerEnglish: .constant(0), neuralSpeakerRussian: .constant(3))
                .padding(16).frame(width: ControlPanelView.width).background(Brand.bg)
            let s = NSHostingView(rootView: v.fixedSize(horizontal: false, vertical: true)).fittingSize
            write(v.tint(Brand.accent), size: CGSize(width: ControlPanelView.width, height: ceil(s.height)),
                  to: out.appendingPathComponent("\(name).png"))
        }
    }

    /// Made-up installed voices: premium, enhanced and standard ones, a novelty voice and another English region.
    private static let fakeVoices: [VoiceInfo] = [
        VoiceInfo(id: "fake.premium.en-US.Ava", name: "Ava", language: "en-US", quality: .premium),
        VoiceInfo(id: "fake.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard),
        VoiceInfo(id: "fake.enhanced.en-GB.Serena", name: "Serena", language: "en-GB", quality: .enhanced),
        VoiceInfo(id: "fake.enhanced.ru-RU.Milena", name: "Milena", language: "ru-RU", quality: .enhanced),
        VoiceInfo(id: "fake.compact.ru-RU.Yuri", name: "Yuri", language: "ru-RU", quality: .standard),
        VoiceInfo(id: "fake.novelty.en-US.Zarvox", name: "Zarvox", language: "en-US", quality: .standard, isNovelty: true),
    ]

    private static func held(_ kind: Hold.Kind, calls: Int) -> AgentSession {
        var s = session(.working)
        let now = Date()
        s.supportsHold = true
        s.hold = Hold(kind: kind, since: now.addingTimeInterval(kind == .pause ? -139 : -8 * 60))
        let samples = ["$ npm test -- checkout", "Edit src/cart/store.ts", "Read src/components/checkout/CheckoutForm.tsx",
                       "Grep \"coupon\"", "$ git status"]
        s.heldCalls = samples.prefix(calls).enumerated().map { i, t in
            HeldCall(id: "h\(i)", summary: t, since: now, agentId: i > 1 ? "ag1" : nil, deadline: now.addingTimeInterval(3600))
        }
        return s
    }

    private static let sampleQuestions: [Question] = [
        Question(question: "Where should the coupon be stored between checkout steps?", header: "Storage", options: [
            QuestionOption(label: "Cart store", description: "Keeps it with the other cart data; survives going back a step"),
            QuestionOption(label: "URL query", description: "Shareable link, but visible in the address bar"),
            QuestionOption(label: "Session storage", description: "Survives a reload, cleared when the tab closes"),
        ]),
        Question(question: "Which checks should run before the change is done?", header: "Checks", options: [
            QuestionOption(label: "Unit tests", description: "npm test -- checkout"),
            QuestionOption(label: "Type check", description: "tsc --noEmit"),
            QuestionOption(label: "End-to-end", description: "The checkout flow in a headless browser; takes about four minutes"),
        ], multiSelect: true),
        Question(question: "How should the change be rolled out?", header: "Rollout", options: [
            QuestionOption(label: "All users at once", description: nil),
            QuestionOption(label: "Ten percent first", description: "Watch the error rate for a day"),
        ]),
    ]

    private static let samplePlan = """
    # Keep the coupon between checkout steps

    The coupon is held in the form state and is lost when the step unmounts. Move it to the **cart store** and read it from there.

    ## Steps

    1. Add `coupon` and `setCoupon` to `src/cart/store.ts`.
    2. Read the coupon from the store in `CheckoutForm.tsx`; remove the local state.
    3. Send the coupon with the order in `submitOrder`.
    4. Add a regression test: apply a coupon, go back a step, return, expect the discount.
       - cover the empty coupon
       - cover an expired coupon

    ## Checks

    ```
    npm test -- checkout
    npx tsc --noEmit
    ```

    ## Risks

    - The mobile app reads the coupon from the old endpoint. It keeps working: the response shape does not change.
    - A stale coupon may stay in the store after the order is placed, so the store is cleared on success.
    - Server rendering: the store is created per request, nothing leaks between users.

    ## Out of scope

    - Redesign of the coupon field.
    - Coupons for subscriptions.
    """

    /// A session whose agent asks `questions`.
    private static func asking(_ questions: [Question], hold: Hold.Kind? = nil, expired: Bool = false) -> AgentSession {
        let now = Date()
        var store = SessionStore()
        for e in baseEvents(now: now) { _ = store.apply(e) }
        if let hold { store.hold(sessionKey: "claude:demo", kind: hold, now: now.addingTimeInterval(-139)) }
        let deadline = expired ? now.addingTimeInterval(-30) : now.addingTimeInterval(412)
        _ = store.apply(demoEvent(.questionAsked(requestId: "q1", questions: questions, rawInput: [:], deadline: deadline), now: now))
        if expired { _ = store.tick(now: now, autoHideDoneAfter: nil) }
        return store.session("claude:demo")!
    }

    /// A session whose agent waits for the plan to be approved.
    private static func planning() -> AgentSession {
        let now = Date()
        var store = SessionStore()
        for e in baseEvents(now: now) { _ = store.apply(e) }
        _ = store.apply(demoEvent(.permissionRequested(requestId: "plan1", toolName: ClaudeCodeAdapter.planTool,
                                                       input: ["plan": .string(samplePlan)],
                                                       deadline: now.addingTimeInterval(540), suggestions: []), now: now))
        return store.session("claude:demo")!
    }

    private static func demoEvent(_ body: AgentEvent.Body, now: Date, _ t: TimeInterval = 0) -> AgentEvent {
        AgentEvent(kind: .claude, sessionId: "demo", cwd: "/Users/dev/acme-web",
                   host: HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint),
                   time: now.addingTimeInterval(t), body: body)
    }

    private static func baseEvents(now: Date) -> [AgentEvent] {
        [demoEvent(.sessionStarted(source: nil, model: "claude-sonnet-5-5"), now: now, -600),
         demoEvent(.promptSubmitted("Fix the checkout form"), now: now, -590)]
    }

    private static let sampleCommands: [SlashCommand] = SlashCommands.builtin + [
        SlashCommand(name: "commit-push", description: "Commit the staged changes with a short message and push the branch", argumentHint: "[message]", source: .user),
        SlashCommand(name: "release-notes", description: "Draft release notes from merged pull requests", source: .project),
        SlashCommand(name: "seo:content", description: "Content quality and E-E-A-T analysis", source: .plugin),
    ]

    private static var photo: some View {
        LinearGradient(colors: [Color(red: 0.95, green: 0.85, blue: 0.6), Color(red: 0.85, green: 0.5, blue: 0.3),
                                Color(red: 0.2, green: 0.3, blue: 0.5)], startPoint: .top, endPoint: .bottom)
    }

    /// Builds a session through the normal event path, so the sample data has the same shape as real data.
    private static func session(_ state: AgentState, pending: Bool = false, hung: Bool = false) -> AgentSession {
        let now = Date()
        let cwd = "/Users/dev/acme-web"
        let host = HostInfo(appBundleId: HostInfo.vscode, entrypoint: HostInfo.vscodeEntrypoint)
        func ev(_ body: AgentEvent.Body, _ t: TimeInterval = 0) -> AgentEvent {
            AgentEvent(kind: .claude, sessionId: "demo", cwd: cwd, host: host, time: now.addingTimeInterval(t), body: body)
        }
        var events = [ev(.sessionStarted(source: nil, model: "claude-sonnet-5-5"), -600), ev(.promptSubmitted("Fix the checkout form"), -590)]
        if hung {
            events.append(ev(.toolFinished(toolName: "Bash", input: ["command": "npm run dev", "run_in_background": true],
                                           toolUseId: "bg1", durationMs: 10, failed: false, backgroundId: "bg1"), -7200))
        }
        switch state {
        case .idle, .done: events.append(ev(.stopped(lastMessage: "Done.", failed: false), -5))
        case .error: events.append(ev(.stopped(lastMessage: "Failed.", failed: true), -5))
        default: break
        }
        if pending {
            events.append(ev(.permissionRequested(requestId: "r1", toolName: "Bash", input: ["command": "npm install zod"],
                                                  deadline: now.addingTimeInterval(120), suggestions: [])))
        }
        var store = SessionStore()
        for e in events { _ = store.apply(e) }
        var s = store.session("claude:demo")!
        if state == .idle { s.baseState = .idle }
        return s
    }

    private static let chat: [ChatItem] = [
        ChatItem(id: "1", time: nil, kind: .user("The checkout form loses the coupon when I go back a step. Can you fix it?")),
        ChatItem(id: "2", time: nil, kind: .assistant("I'll look at **CheckoutForm.tsx** first. The coupon lives in `useCart`, so the state is probably reset on unmount.\n\nPlan:\n- keep the coupon in the cart store\n- add a regression test")),
        ChatItem(id: "3", time: nil, kind: .tool(name: "Read", summary: "Read src/CheckoutForm.tsx", status: .ok)),
        ChatItem(id: "4", time: nil, kind: .tool(name: "Grep", summary: "Grep coupon in src", status: .ok)),
        ChatItem(id: "5", time: nil, kind: .tool(name: "Edit", summary: "Edit src/cart/store.ts", status: .ok)),
        ChatItem(id: "6", time: nil, kind: .tool(name: "Bash", summary: "$ npm test -- checkout", status: .failed)),
        ChatItem(id: "7", time: nil, kind: .assistant("One test fails: the fixture has no coupon. I'll update it and run the suite again.")),
        ChatItem(id: "8", time: nil, kind: .tool(name: "Bash", summary: "$ npm test -- checkout", status: .running)),
    ]

    private static func write<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = host            // never ordered front: the window only gives the view a drawing context
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
