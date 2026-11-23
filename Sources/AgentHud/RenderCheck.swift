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
    }

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
