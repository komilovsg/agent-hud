import AgentHudCore
import AppKit
import Combine
import SwiftUI

/// A floating panel without app activation: it doesn't steal focus from the terminal,
/// is visible on all desktops and above full-screen windows.
final class HUDPanel: NSPanel {
    /// Only the card needs the keyboard; token windows never take key focus from the card or another app.
    var allowsKey = true
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI hosting that accepts the first click even without focus.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One small window per visible session (its icon) plus one card window for the selected session.
/// Token windows have a fixed size and move only when their own icon is dragged (or on reset / screen changes);
/// opening and closing the card never touches them.
@MainActor
final class HUDController: NSObject, NSWindowDelegate {
    private final class Token {
        let panel: HUDPanel
        let positionKey: String
        init(panel: HUDPanel, positionKey: String) { self.panel = panel; self.positionKey = positionKey }
    }

    private let model: AppModel
    private let card: HUDPanel
    /// Details of a held session next to its icon (shown on hover).
    private let holdPopover: HUDPanel
    /// Mouse-down monitors that close the card on a click elsewhere; installed only while the card is open.
    private var clickMonitors: [Any] = []
    private var tokens: [String: Token] = [:]        // by session id
    private var settleTasks: [String: Task<Void, Never>] = [:]
    private var settingFrame = false
    private var cancellables = Set<AnyCancellable>()
    private static let positionsKey = "tokenPositions"

    /// Frame changes applied to token windows / the card window (for --uitest and debugging).
    private(set) var tokenFramesApplied = 0
    private(set) var cardFramesApplied = 0

    init(model: AppModel) {
        self.model = model
        card = HUDPanel(contentRect: NSRect(origin: .zero, size: CardMetrics.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        holdPopover = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: HoldPopoverMetrics.width, height: 200),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        Self.configure(card)
        Self.configure(holdPopover)
        holdPopover.allowsKey = false
        holdPopover.contentView = {
            let host = FirstClickHostingView(rootView: HoldPopoverRoot(model: model))
            host.sizingOptions = []
            return host
        }()
        card.contentView = {
            let host = FirstClickHostingView(rootView: CardRoot(model: model))
            host.sizingOptions = []
            return host
        }()

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        // The card was opened by a click - give it keyboard focus (for Esc and the input field).
        model.$selectedKey
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                self.sync()
                if key != nil, self.model.selectedByUser, self.card.isVisible { self.card.makeKey() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    private static func configure(_ p: HUDPanel) {
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovableByWindowBackground = false
        p.becomesKeyOnlyIfNeeded = true
        p.animationBehavior = .none
    }

    var isShown: Bool { tokens.values.contains { $0.panel.isVisible } }

    func updateVisibility() { sync() }

    // MARK: - Sync with the model

    private func orderedSessions() -> [AgentSession] {
        model.visibleSessions.sorted { a, b in a.startedAt != b.startedAt ? a.startedAt < b.startedAt : a.id < b.id }
    }

    private func sync() {
        let s = model.settings
        let sessions = orderedSessions()
        let live = Set(sessions.map(\.id))
        for (id, t) in tokens where !live.contains(id) {
            settleTasks[id]?.cancel()
            settleTasks[id] = nil
            t.panel.orderOut(nil)
            t.panel.close()
            tokens[id] = nil
        }
        for session in sessions where tokens[session.id] == nil { createToken(for: session) }

        // A held session must stay reachable: with the HUD switched off there would be no way to resume it.
        let anyHeld = sessions.contains { $0.hold != nil }
        // The same goes for a look request: without its card the look could only time out.
        let shouldShow = (s.hudVisible || anyHeld || !model.looks.isEmpty) && !sessions.isEmpty
            && (!s.hideWhenNothingWaits || model.hasAttention || model.selectedKey != nil)
        for t in tokens.values {
            if shouldShow, !t.panel.isVisible { t.panel.orderFrontRegardless() }
            else if !shouldShow, t.panel.isVisible { t.panel.orderOut(nil) }
        }
        syncCard(show: shouldShow)
        syncHoldPopover(show: shouldShow)
        syncClickMonitors()
    }

    private func syncHoldPopover(show: Bool) {
        if show, let key = model.holdPopoverKey, let t = tokens[key], let s = model.store.session(key), s.hold != nil {
            let tf = t.panel.frame
            let vf = visibleFrame(containingCenterOf: tf) ?? primaryVisibleFrame
            let frame = TokenLayout.cardFrame(token: tf, cardSize: HoldPopoverMetrics.size(for: s), in: vf)
            if frame != holdPopover.frame { holdPopover.setFrame(frame, display: true) }
            if !holdPopover.isVisible { holdPopover.orderFrontRegardless() }
        } else if holdPopover.isVisible {
            holdPopover.orderOut(nil)
        }
    }

    // MARK: - Click outside closes the card

    private func syncClickMonitors() {
        if card.isVisible, clickMonitors.isEmpty {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
            // Clicks in other apps (and on the desktop) are always outside.
            if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
                Task { @MainActor in self?.closeCard() }
            }) { clickMonitors.append(g) }
            // Clicks in this app's other windows: the control panel, the agent map.
            if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                let window = event.window
                Task { @MainActor in
                    guard let self, !self.belongsToHUD(window) else { return }
                    self.closeCard()
                }
                return event
            }) { clickMonitors.append(l) }
        } else if !card.isVisible, !clickMonitors.isEmpty {
            clickMonitors.forEach(NSEvent.removeMonitor)
            clickMonitors.removeAll()
        }
    }

    private func closeCard() {
        guard model.selectedKey != nil else { return }
        model.select(nil)
    }

    /// The card, the icons, the hold popover, and anything opened from them (menus, popovers) are not "outside".
    private func belongsToHUD(_ window: NSWindow?) -> Bool {
        guard let window else { return true }   // no window to judge by: leave the card alone
        var w: NSWindow? = window
        while let cur = w {
            if cur === card || cur === holdPopover || tokens.values.contains(where: { $0.panel === cur }) { return true }
            w = cur.parent
        }
        // Menus live in their own windows without a parent: recognised by class and level. The control panel is
        // a popover of the status item, so popovers are judged only by the parent chain above.
        let cls = window.className
        if cls.contains("Menu") { return true }
        return window.level.rawValue >= NSWindow.Level.popUpMenu.rawValue && !cls.contains("Popover")
    }

    private func syncCard(show: Bool) {
        #if DEBUG
        let before = tokens.mapValues { $0.panel.frame }
        defer { assert(before.allSatisfy { tokens[$0.key]?.panel.frame == $0.value || tokens[$0.key] == nil },
                       "opening or closing the card moved a token window") }
        #endif
        if show, let key = model.selectedKey, let t = tokens[key] {
            positionCard(for: t)
            if !card.isVisible { card.orderFrontRegardless() }
        } else if card.isVisible {
            card.orderOut(nil)
        }
    }

    // MARK: - Tokens

    private static func positionKey(_ s: AgentSession) -> String { s.cwd.isEmpty ? s.id : s.cwd }

    private var primaryVisibleFrame: CGRect {
        (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Visible frame of the screen under the center of `rect`; nil when the point is on no connected screen.
    private func visibleFrame(containingCenterOf rect: CGRect) -> CGRect? {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(c) }?.visibleFrame
    }

    private func savedPositions() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: String] ?? [:]
    }

    private func createToken(for session: AgentSession) {
        let size = TokenMetrics.size
        let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        Self.configure(panel)
        panel.allowsKey = false
        panel.delegate = self
        let host = FirstClickHostingView(rootView: TokenRoot(model: model, key: session.id))
        host.sizingOptions = []
        panel.contentView = host

        let key = Self.positionKey(session)
        let others = tokens.values.map { $0.panel.frame }
        var origin: CGPoint
        if let saved = savedPositions()[key].flatMap(TokenLayout.decode),
           let vf = visibleFrame(containingCenterOf: CGRect(origin: saved, size: size)),
           !others.contains(where: { $0.intersects(CGRect(origin: saved, size: size)) }) {
            origin = TokenLayout.clamp(CGRect(origin: saved, size: size), to: vf).origin
        } else {
            origin = TokenLayout.freeSlot(in: primaryVisibleFrame, tokenSize: size, occupied: others)
        }
        let t = Token(panel: panel, positionKey: key)
        tokens[session.id] = t
        setFrame(t, CGRect(origin: origin, size: size))
    }

    private func setFrame(_ t: Token, _ frame: CGRect) {
        guard frame != t.panel.frame else { return }
        settingFrame = true
        t.panel.setFrame(frame, display: true)
        settingFrame = false
        tokenFramesApplied += 1
    }

    /// "Reset HUD position": forget saved positions and put every token into the default grid.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.positionsKey)
        let size = TokenMetrics.size
        for (i, s) in orderedSessions().enumerated() {
            guard let t = tokens[s.id] else { continue }
            setFrame(t, CGRect(origin: TokenLayout.defaultSlot(index: i, in: primaryVisibleFrame, tokenSize: size), size: size))
        }
        if let k = model.selectedKey, let t = tokens[k], card.isVisible { positionCard(for: t) }
    }

    /// After a display was connected or removed: tokens off every screen go to free slots, the rest are kept on screen.
    private func screensChanged() {
        for (id, t) in tokens.sorted(by: { $0.key < $1.key }) {
            let f = t.panel.frame
            if let vf = visibleFrame(containingCenterOf: f) {
                setFrame(t, TokenLayout.clamp(f, to: vf))
            } else {
                let others = tokens.filter { $0.key != id }.map { $0.value.panel.frame }
                setFrame(t, CGRect(origin: TokenLayout.freeSlot(in: primaryVisibleFrame, tokenSize: TokenMetrics.size, occupied: others),
                                   size: TokenMetrics.size))
            }
        }
        if let k = model.selectedKey, let t = tokens[k], card.isVisible { positionCard(for: t) }
    }

    // MARK: - Card

    private func positionCard(for t: Token) {
        let tf = t.panel.frame
        let vf = visibleFrame(containingCenterOf: tf) ?? primaryVisibleFrame
        let frame = TokenLayout.cardFrame(token: tf, cardSize: CardMetrics.fitted(to: vf), in: vf)
        guard frame != card.frame else { return }
        card.setFrame(frame, display: true)
        cardFramesApplied += 1
    }

    // MARK: - Dragging

    /// While a token is dragged we only move the card along; once released it is kept on screen and its position saved.
    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !self.settingFrame, let w = notification.object as? NSWindow,
                  let (id, t) = self.tokens.first(where: { $0.value.panel === w }) else { return }
            if self.model.selectedKey == id, self.card.isVisible { self.positionCard(for: t) }
            self.settleTasks[id]?.cancel()
            self.settleTasks[id] = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.settle(id)
            }
        }
    }

    private func settle(_ id: String) {
        guard let t = tokens[id] else { return }
        let f = t.panel.frame
        let vf = visibleFrame(containingCenterOf: f)
            ?? NSScreen.screens.first { $0.frame.intersects(f) }?.visibleFrame ?? primaryVisibleFrame
        let clamped = TokenLayout.clamp(f, to: vf)
        setFrame(t, clamped)
        var all = savedPositions()
        all[t.positionKey] = TokenLayout.encode(clamped.origin)
        UserDefaults.standard.set(all, forKey: Self.positionsKey)
        if model.selectedKey == id, card.isVisible { positionCard(for: t) }
        syncHoldPopover(show: holdPopover.isVisible)
    }
}
