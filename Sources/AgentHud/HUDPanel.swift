import AppKit
import Combine
import SwiftUI

/// A floating panel without app activation: it doesn't steal focus from the terminal,
/// is visible on all desktops and above full-screen windows.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI hosting that accepts the first click even without focus.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class HUDController: NSObject, NSWindowDelegate {
    let panel: HUDPanel
    private let model: AppModel
    private var size = CGSize(width: 80, height: 60)
    private var settingFrame = false
    private var cancellables = Set<AnyCancellable>()
    private var settleTask: Task<Void, Never>?
    /// How many times the window actually changed its frame (for --uitest: at rest and when a window opens - a handful, not dozens).
    private(set) var framesApplied = 0
    /// Transparent margins around the content for the shadow (padding in HUDRootView).
    static let shadowPad: CGFloat = 14

    init(model: AppModel) {
        self.model = model
        panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 80, height: 60),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.delegate = self

        let root = HUDRootView(model: model) { [weak self] s in
            Task { @MainActor in self?.contentSizeChanged(s) }
        }
        let host = FirstClickHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateVisibility() }
            .store(in: &cancellables)
        // The card was opened by a click - give the panel keyboard focus (for ⌘↩, Esc and the reply field).
        model.$selectedKey
            .receive(on: RunLoop.main)
            .sink { [weak self] key in
                guard let self else { return }
                if key != nil, self.model.selectedByUser { self.panel.makeKey() }
            }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.placeWindow() }
        }
    }

    var isShown: Bool { panel.isVisible }

    func updateVisibility() {
        let s = model.settings
        let any = !model.visibleSessions.isEmpty
        let shouldShow = s.hudVisible && any && (!s.hideWhenNothingWaits || model.hasAttention || model.selectedKey != nil)
        if shouldShow, !panel.isVisible {
            placeWindow()
            panel.orderFrontRegardless()
        } else if !shouldShow, panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Reposition the window per current settings (after an anchor change from code, for --uitest).
    func refreshPlacement() { placeWindow() }

    func resetPosition() {
        model.settings.anchor = nil
        model.settings.anchorLeft = false
        placeWindow()
    }

    private func contentSizeChanged(_ s: CGSize) {
        // Whole points: fractional sizes (animation tails) must not jerk the window.
        let r = CGSize(width: ceil(s.width), height: ceil(s.height))
        guard r.width > 0, r.height > 0, r != size else { return }
        size = r
        placeWindow()
    }

    /// The anchor corner is kept at one point: at the right edge - top-right (the window grows left and down),
    /// at the left - top-left (grows right and down). The frame is pinned to the visible part of the screen:
    /// content doesn't go past the edges or under the menu bar; the shadow may extend past the edge.
    private func placeWindow() {
        let left = model.settings.anchorLeft
        // By default - the main screen (with the menu bar), not NSScreen.main: that one means "the screen with focus",
        // and with two monitors the HUD jumped to the other screen on every size change.
        guard let defaultScreen = NSScreen.screens.first ?? NSScreen.main else { return }
        var anchor = model.settings.anchor ?? Self.defaultAnchor(defaultScreen.visibleFrame, left: left)
        // Anchor outside all screens (a monitor was disconnected) - to the default corner.
        if !NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) }) {
            anchor = Self.defaultAnchor(defaultScreen.visibleFrame, left: left)
        }
        let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -4, dy: -4).contains(anchor) }) ?? defaultScreen
        let raw = NSRect(x: left ? anchor.x : anchor.x - size.width, y: anchor.y - size.height,
                         width: size.width, height: size.height)
        let frame = Self.clamp(raw, to: screen.visibleFrame, pad: Self.shadowPad)
        guard frame != panel.frame else { return }
        settingFrame = true
        panel.setFrame(frame, display: true)
        settingFrame = false
        framesApplied += 1
    }

    static func defaultAnchor(_ vf: NSRect, left: Bool) -> CGPoint {
        CGPoint(x: left ? vf.minX + 2 : vf.maxX - 2, y: vf.maxY + 2)
    }

    /// Frame inside the visible part of the screen with a tolerance for the transparent shadow margins.
    /// If the window is taller than the screen, the top wins: the icon row and request buttons matter more than the feed tail.
    static func clamp(_ f: NSRect, to vf: NSRect, pad: CGFloat) -> NSRect {
        var r = f
        let area = vf.insetBy(dx: -pad, dy: -pad)
        if r.maxX > area.maxX { r.origin.x = area.maxX - r.width }
        if r.minX < area.minX { r.origin.x = area.minX }
        if r.minY < area.minY { r.origin.y = area.minY }
        if r.maxY > area.maxY { r.origin.y = area.maxY - r.height }
        return r
    }

    /// While the HUD is being dragged we touch nothing; once released we decide which edge it is now at,
    /// remember the anchor corner and bring the frame back within the screen (not past the edge or onto the menu bar).
    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard !self.settingFrame else { return }
            self.settleTask?.cancel()
            self.settleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                self.settleAfterDrag()
            }
        }
    }

    private func settleAfterDrag() {
        let f = panel.frame
        let probe = NSPoint(x: f.midX, y: f.maxY - Self.shadowPad - 20)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let left = f.midX < vf.midX
        if model.settings.anchorLeft != left { model.settings.anchorLeft = left }
        // The anchor corner itself is within the screen: the icon row doesn't stay on the menu bar or past the edge.
        let area = vf.insetBy(dx: -Self.shadowPad, dy: -Self.shadowPad)
        let x = left ? max(area.minX, min(f.minX, area.maxX - 80)) : min(area.maxX, max(f.maxX, area.minX + 80))
        let y = min(area.maxY, max(f.maxY, area.minY + 80))
        model.settings.anchor = CGPoint(x: x, y: y)
        placeWindow()
    }
}
