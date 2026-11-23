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

        func inputCard(_ preset: ChatInputPreset) -> some View {
            SessionCard(model: model, session: session(.working), preset: chat, inputPreset: preset)
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
