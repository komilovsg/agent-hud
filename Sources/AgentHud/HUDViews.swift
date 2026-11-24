import AgentHudCore
import SwiftUI

/// Flag for rendering the preview to PNG: materials (blur) are not drawn in ImageRenderer.
private struct SolidBackgroundKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var solidBackground: Bool {
        get { self[SolidBackgroundKey.self] }
        set { self[SolidBackgroundKey.self] = newValue }
    }
}

struct Glass: ViewModifier {
    var radius: CGFloat
    var shadow = true
    @Environment(\.solidBackground) private var solid
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(solid ? AnyShapeStyle(scheme == .dark ? Color(white: 0.16) : Color(white: 0.97))
                                : AnyShapeStyle(.regularMaterial))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(shadow ? 0.18 : 0), radius: 10, y: 4)
    }
}

extension View {
    func glass(_ radius: CGFloat = 14, shadow: Bool = true) -> some View { modifier(Glass(radius: radius, shadow: shadow)) }
}

// MARK: - Fixed sizes

/// The one size of a session icon window. Badges, labels and selection are drawn inside it.
enum TokenMetrics {
    static let size = CGSize(width: 96, height: 108)
}

/// The one size of the session card window.
enum CardMetrics {
    static let size = CGSize(width: 380, height: 560)

    /// On short screens the card is as tall as the visible area minus a margin.
    static func fitted(to visibleFrame: CGRect) -> CGSize {
        visibleFrame.height < 640 ? CGSize(width: size.width, height: max(240, visibleFrame.height - 40)) : size
    }
}

// MARK: - Session icon ("token")

/// Window content of one token: looks the session up by id.
struct TokenRoot: View {
    @ObservedObject var model: AppModel
    let key: String

    var body: some View {
        Group {
            if let s = model.store.session(key) {
                TokenView(model: model, session: s, selected: model.selectedKey == key)
            } else {
                Color.clear
            }
        }
        .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height)
        .tint(Brand.accent)
    }
}

/// A desktop-item look: icon with the project name under it. No plate; everything stays inside the fixed box.
struct TokenView: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    var selected = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 4) {
            icon
            label
        }
        .padding(.top, 8)
        .frame(width: TokenMetrics.size.width, height: TokenMetrics.size.height, alignment: .top)
        .overlay {
            TokenInteraction(tooltip: tooltip,
                             menu: { menuEntries },
                             onClick: { model.select(session.id) },
                             onHover: { hover = $0; model.tokenHover(session.id, $0) })
        }
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.14 : (hover ? 0.08 : 0)))
            AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 56,
                       animated: model.settings.animations, kind: session.kind)
                // Held: the icon steps back and the countdown / stop glyph sits over it.
                .blur(radius: held ? 3 : 0)
                .opacity(held ? 0.5 : 1)
            if let h = session.hold, held { HoldOverlay(hold: h) }
            // The agent's state at a glance (the avatar adds its own pulse and badges for "needs you", done, error).
            Circle().fill(session.state.tint).frame(width: 10, height: 10)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5))
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(4)
        }
        .frame(width: 64, height: 64)
        .overlay(alignment: .topLeading) { HungBadge(session: session).offset(x: -3, y: -3) }
        // An agent wants to look at the screen, or is looking right now.
        // An agent wants to act in an app, or is acting right now: the hand takes the eye's place.
        .overlay(alignment: .topTrailing) {
            if model.isActing(session.id) {
                ActBadge().offset(x: 3, y: -3)
            } else if model.isLooking(session.id) {
                LookBadge().offset(x: 3, y: -3)
            }
        }
    }

    private var held: Bool { session.state == .paused || session.state == .stopped }

    private var label: some View {
        Text(session.projectName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.middle)
            .shadow(color: .black.opacity(0.8), radius: 1.5, x: 0, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 3, x: 0, y: 0)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
            .frame(maxWidth: 90)
            .frame(height: 20)
    }

    private var tooltip: String {
        // A held session shows its own popover on hover; a system tooltip would cover it.
        if session.hold != nil { return "" }
        var parts = ["\(session.projectName) — \(session.stateTitle) · \(session.host.label)"]
        if !session.title.isEmpty { parts.append(session.title) }
        if let step = session.currentStep { parts.append(step.summary) }
        return parts.joined(separator: "\n")
    }

    @MainActor private var menuEntries: [TokenMenuEntry] {
        let model = model, id = session.id, cwd = session.cwd
        // The placeholder entry has no session behind it: it can only be hidden, which refuses its request.
        if session.isUnknownAgent { return [TokenMenuEntry(title: "Hide") { model.hide(id) }] }
        var out = OpenAction.items(for: session, model: model).map { a in
            TokenMenuEntry(title: a.title, enabled: a.enabled, hint: a.hint, run: a.run)
        }
        if !cwd.isEmpty {
            if !out.isEmpty { out.append(.separator) }
            out.append(TokenMenuEntry(title: "New session in this project") {
                // A refusal (hooks not connected, folder gone) is shown in the "New session" window.
                if let refusal = model.startSession(cwd: cwd, firstMessage: nil) { model.onNewSession?(cwd, refusal) }
            })
        }
        let holds = HoldAction.items(for: session, model: model)
        if !holds.isEmpty {
            out.append(.separator)
            out += holds.map { a in
                TokenMenuEntry(title: a.title, symbol: a.symbol, enabled: a.enabled, hint: a.help(for: session), run: a.run)
            }
            if holds.contains(where: { !$0.enabled }) {
                out.append(TokenMenuEntry(title: Hold.unsupportedHint, enabled: false) {})
            }
            out.append(.separator)
        }
        out.append(TokenMenuEntry(title: "Agent map") { model.openMap() })
        out.append(TokenMenuEntry(title: "Hide") { model.hide(id) })
        return out
    }
}

struct TokenMenuEntry {
    let title: String
    var symbol: String? = nil
    var enabled = true
    var hint: String? = nil
    var isSeparator = false
    let run: @MainActor () -> Void

    static let separator = TokenMenuEntry(title: "", isSeparator: true) {}
}

/// Transparent AppKit layer over the whole token. Click and drag are told apart right here in `mouseDown`
/// (a tracking loop and a fixed threshold), so they do not depend on SwiftUI gesture timing. It also owns
/// the context menu (`menu(for:)`; ctrl-click is routed to the same menu), the hover state and the tooltip.
struct TokenInteraction: NSViewRepresentable {
    var tooltip: String
    var menu: @MainActor () -> [TokenMenuEntry]
    var onClick: () -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TokenHitView { TokenHitView() }

    func updateNSView(_ v: TokenHitView, context: Context) {
        v.toolTip = tooltip
        v.menuProvider = menu
        v.onClick = onClick
        v.onHover = onHover
    }
}

final class TokenHitView: NSView {
    var menuProvider: @MainActor () -> [TokenMenuEntry] = { [] }
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func mouseDown(with down: NSEvent) {
        if down.modifierFlags.contains(.control) {
            if let m = menu(for: down) { NSMenu.popUpContextMenu(m, with: down, for: self) }
            return
        }
        guard let win = window else { return }
        while let e = win.nextEvent(matching: [.leftMouseDragged, .leftMouseUp], until: .distantFuture,
                                    inMode: .eventTracking, dequeue: true) {
            if e.type == .leftMouseUp {
                onClick()
                return
            }
            if TokenLayout.isDrag(from: down.locationInWindow, to: e.locationInWindow) {
                win.performDrag(with: down)
                return
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = MainActor.assumeIsolated { menuProvider() }
        let m = NSMenu()
        m.autoenablesItems = false
        for e in entries {
            if e.isSeparator { m.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: e.title, run: e.run)
            item.isEnabled = e.enabled
            item.toolTip = e.hint
            if let s = e.symbol { item.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            m.addItem(item)
        }
        return m
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void
    init(title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { MainActor.assumeIsolated { run() } }
}

// MARK: - Session card (mini chat)

/// The card window's content: the selected session's card filling the (fixed-size) window.
struct CardRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let key = model.selectedKey, let s = model.store.session(key) {
                SessionCard(model: model, session: s).id(key)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(Brand.accent)
    }
}

struct SessionCard: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @StateObject private var loader: ChatLoader
    private let inputPreset: ChatInputPreset?
    private let requestPreset: RequestPreset?

    init(model: AppModel, session: AgentSession, preset: [ChatItem]? = nil, inputPreset: ChatInputPreset? = nil,
         requestPreset: RequestPreset? = nil) {
        self.model = model
        self.session = session
        self.inputPreset = inputPreset
        self.requestPreset = requestPreset
        _loader = StateObject(wrappedValue: ChatLoader(preset: preset))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let h = session.hold { HoldBanner(model: model, session: session, hold: h) }
            if let act = model.act(for: session.id) {
                // An action request keeps its full height too: what will be done and the buttons stay in view.
                ActRequestView(model: model, act: act)
                    .id(act.id)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(3)
            } else if model.actBlocked.contains(session.id) {
                ActBlockedNotice(model: model, sessionKey: session.id)
            }
            if let look = model.look(for: session.id) {
                // A look request comes first and keeps its full height: its buttons must never leave the card.
                LookRequestView(model: model, look: look)
                    .id(look.id)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(2)
            } else if let kind = model.lookBlocked[session.id] {
                LookBlockedNotice(model: model, sessionKey: session.id, kind: kind)
            }
            if let p = session.activePending {
                // A request is laid out first; the chat gets the rest.
                switch p.kind {
                case .permission(let tool, let input):
                    PermissionView(model: model, session: session, request: p, tool: tool, input: input)
                        .id(p.id)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                // Questions and a plan can be longer than the card: no fixed height, their long part scrolls.
                case .question(let questions, _):
                    QuestionView(model: model, session: session, request: p, questions: questions, preset: requestPreset)
                        .id(p.id)
                        .layoutPriority(1)
                case .plan(let text, _):
                    PlanView(model: model, session: session, request: p, text: text, preset: requestPreset)
                        .id(p.id)
                        .layoutPriority(1)
                }
            } else if let p = session.expiredPending {
                ExpiredView(model: model, session: session, request: p)
            } else if session.state.needsUser {
                Notice(icon: session.host.placeSymbol, color: .orange,
                       text: "The agent is waiting for a reply \(session.host.placeIn).",
                       actions: [("Open", { model.open(session.id) })])
            }
            if !session.backgroundTasks.isEmpty { BackgroundList(tasks: session.backgroundTasks) }
            if let owned { OwnedNotices(owned: owned, hooksSilent: model.hooksSilent(owned)) }
            if model.isHandOverUnconfirmed(session) {
                Notice(icon: "arrow.up.forward.app", color: .orange,
                       text: "Moved to \(session.host.label), but it has not picked the session up yet. Open it there, or continue here.")
            }
            if let notes = model.lookNotes[session.id], !notes.isEmpty { LookNotes(notes: notes) }
            chat.frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.activePending == nil, !session.isUnknownAgent {
                if let owned, owned.isLive {
                    ChatInput(model: model, session: session, owned: owned.state, preset: inputPreset)
                } else {
                    if model.canContinueHere(session) { continueRow }
                    // An ended session of ours has nowhere else to reply.
                    if !session.host.isHud { ChatInput(model: model, session: session, preset: inputPreset) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glass(14, shadow: false)
        .onAppear { loader.bind(key: session.id, path: session.transcriptPath) }
        .onChange(of: session.transcriptPath) { _, p in loader.bind(key: session.id, path: p) }
        .onChange(of: session.lastEventAt) { _, _ in loader.reload(force: true) }
        .onDisappear { loader.stop() }
    }

    /// The session's process when this app runs (or ran) it.
    private var owned: OwnedSession? { model.owned[session.sessionId] }

    private var continueRow: some View {
        let restart = owned.map { !$0.initialized } ?? false
        return HStack(spacing: 8) {
            Image(systemName: "play.circle").foregroundStyle(.secondary)
            Text(restart ? "The session did not start." : "This session has ended.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(restart ? "Start again" : "Continue in Agent HUD") { model.continueHere(session.id) }
                .controlSize(.small)
                .fixedSize()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    @ViewBuilder private var chat: some View {
        if session.isUnknownAgent {
            UnknownAgentNote()
        } else if let owned {
            OwnedChat(owned: owned)
        } else if !loader.items.isEmpty {
            ChatView(items: loader.items)
        } else {
            // No readable transcript: the steps feed, so a live session is never an empty card.
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let msg = session.lastMessage, session.state == .done || session.state == .error {
                        LastMessageView(text: msg, failed: session.state == .error)
                    }
                    StepsList(session: session)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        // The subtitle sits under the row, so it can run below the buttons instead of being cut by them.
        VStack(alignment: .leading, spacing: 2) {
            headerRow
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(subtitle(now: ctx.date)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.leading, 40)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(seed: session.avatarSeed, state: session.state, style: model.settings.avatarStyle, size: 30, animated: false,
                       kind: session.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    ProjectDot(cwd: session.cwd)
                    Text(session.projectName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(session.stateTitle)
                        .font(.system(size: 10, weight: .semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(session.state.tint.opacity(0.16)))
                        .foregroundStyle(session.state.tint)
                        .fixedSize()
                    if !session.title.isEmpty {
                        Text(session.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                if !session.isUnknownAgent {
                    ForEach(HoldAction.items(for: session, model: model)) { a in
                        IconButton(symbol: a.symbol, help: a.help(for: session), action: a.run)
                            .disabled(!a.enabled)
                            .opacity(a.enabled ? 1 : 0.35)
                    }
                    OpenMenuButton(model: model, session: session)
                }
                IconButton(symbol: "map", help: "Agent map: all sessions and what they are doing") { model.openMap() }
                IconButton(symbol: "eye.slash", help: "Hide") { model.hide(session.id) }
                IconButton(symbol: "xmark", help: "Close") { model.select(nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func subtitle(now: Date) -> String {
        if session.isUnknownAgent { return "Not one of the listed sessions" }
        var parts = [session.kind.displayName, session.host.label]
        if let tty = session.host.tty { parts.append((tty as NSString).lastPathComponent) }
        parts.append(Fmt.elapsed(from: session.startedAt, to: session.finishedAt ?? now))
        if let m = session.model { parts.append(m.replacingOccurrences(of: "claude-", with: "")) }
        if let cost = owned?.costUSD { parts.append(String(format: "$%.2f", cost)) }
        return parts.joined(separator: " · ")
    }
}

/// The "open" button: one action opens directly, several (installed editors) go into a menu.
struct OpenMenuButton: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        let items = OpenAction.items(for: session, model: model)
        if session.host.isHud {
            // Nothing opens by a plain click here: moving a session to an editor is always an explicit menu choice.
            if !items.isEmpty { menu(items, help: "Move or continue") }
        } else if items.count <= 1 {
            IconButton(symbol: "arrow.up.forward.app", help: items.first?.title ?? session.host.openTitle) {
                if let a = items.first { a.run() } else { model.open(session.id) }
            }
        } else {
            menu(items, help: "Open")
        }
    }

    private func menu(_ items: [OpenAction], help: String) -> some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, a in
                Button(a.title) { a.run() }.disabled(!a.enabled)
            }
            // A disabled item says why right in the menu (menu items show no tooltip while disabled).
            if let hint = items.first(where: { !$0.enabled })?.hint {
                Divider()
                Text(hint)
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help(help)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hover ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct Notice: View {
    let icon: String
    let color: Color
    let text: String
    var actions: [(String, () -> Void)] = []

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            ForEach(Array(actions.enumerated()), id: \.offset) { _, a in
                Button(a.0, action: a.1).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.1)))
    }
}

struct LastMessageView: View {
    let text: String
    let failed: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if expanded {
                ScrollView {
                    Text(verbatim: text.count > 6000 ? String(text.prefix(6000)) + "…" : text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
            } else {
                Text(verbatim: String(text.prefix(600)))
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if text.count > 160 || text.filter({ $0 == "\n" }).count > 2 {
                Button(expanded ? "Collapse" : "Show all") { expanded.toggle() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill((failed ? Color.red : Color.green).opacity(0.08)))
    }
}

// MARK: - Steps feed

struct StepsList: View {
    let session: AgentSession

    var body: some View {
        let steps = Array(session.steps.suffix(60))
        if steps.isEmpty {
            Text(session.state == .idle || session.state == .starting ? "Idle" : "No steps yet")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(steps) { st in
                            StepRow(step: st).id(st.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: min(CGFloat(steps.count) * 21 + 6, 230))
                .onAppear { proxy.scrollTo(steps.last?.id, anchor: .bottom) }
                .onChange(of: steps.last?.id) { _, id in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

/// A red dot on the session icon if there are stuck background tasks.
struct HungBadge: View {
    let session: AgentSession

    var body: some View {
        if !session.backgroundTasks.isEmpty {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                if session.hungCount(at: ctx.date) > 0 {
                    Circle().fill(Color.red).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1))
                        .help("Background tasks running for over an hour")
                }
            }
        }
    }
}

/// Background commands and subagents of the session with their age; stuck ones in red.
struct BackgroundList: View {
    // The name is qualified: newer macOS versions of Foundation have their own BackgroundTask.
    let tasks: [AgentHudCore.BackgroundTask]

    var body: some View {
        // Age updates every 30 seconds: a background task may produce no events for hours.
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            VStack(alignment: .leading, spacing: 3) {
                Text("Background").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(tasks.suffix(8)) { t in
                    let hung = t.isHung(at: ctx.date)
                    HStack(spacing: 6) {
                        Image(systemName: hung ? "exclamationmark.triangle.fill" : (t.kind == .shell ? "terminal" : "person.2"))
                            .font(.system(size: 10)).frame(width: 14)
                            .foregroundStyle(hung ? Color.red : Color.secondary)
                        Text(t.title)
                            .font(.system(size: 11, design: t.kind == .shell ? .monospaced : .default))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(hung ? Color.red : Color.primary)
                        Spacer(minLength: 4)
                        Text(DailySummary.duration(Int(t.age(at: ctx.date))))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(hung ? Color.red : Color.secondary)
                    }
                    .frame(height: 18)
                }
                if tasks.count > 8 {
                    Text("and \(tasks.count - 8) more").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

struct StepRow: View {
    let step: Step

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: Fmt.icon(for: step.toolName))
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(.secondary)
            Text(step.summary)
                .font(.system(size: 11, design: step.toolName == "Bash" ? .monospaced : .default))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(step.status == .failed ? Color.red : Color.primary)
            Spacer(minLength: 4)
            if let ms = step.durationMs {
                Text(Fmt.duration(ms)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            statusIcon
        }
        .padding(.leading, step.agentId != nil ? 16 : 0)
        .frame(height: 18)
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.status {
        case .running: ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        case .ok: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green).frame(width: 12)
        case .failed: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red).frame(width: 12)
        }
    }
}

enum Fmt {
    static func duration(_ ms: Int) -> String {
        if ms < 1000 { return "\(ms) ms" }
        let s = Double(ms) / 1000
        if s < 60 { return String(format: "%.1f s", s) }
        return "\(Int(s) / 60) min \(Int(s) % 60) s"
    }

    static func elapsed(from a: Date, to b: Date) -> String {
        let s = max(0, Int(b.timeIntervalSince(a)))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }

    static func icon(for tool: String) -> String {
        switch tool {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Write": return "doc.badge.plus"
        case "Edit", "MultiEdit", "NotebookEdit": return "pencil"
        case "Grep", "Glob": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent", "Subagent": return "person.2"
        case "TodoWrite": return "checklist"
        case "AskUserQuestion": return "questionmark.bubble"
        case "ExitPlanMode": return "list.bullet.clipboard"
        case "Skill": return "sparkles"
        default: return tool.hasPrefix("mcp__") ? "puzzlepiece.extension" : "wrench.and.screwdriver"
        }
    }
}
