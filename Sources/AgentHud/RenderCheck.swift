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

        renderLooks(model: model, out: out)
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
