import AgentHudCore
import AppKit
import Combine
import SwiftUI

/// Menu bar icon with a counter of waiting requests and the control panel (a SwiftUI popover).
@MainActor
final class StatusMenu: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let model: AppModel
    private let hud: HUDController
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel, hud: HUDController) {
        self.model = model
        self.hud = hud
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        if let b = item.button {
            b.target = self
            b.action = #selector(toggle(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateButton()
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)
    }

    private var shownWaiting = -1
    private var permissions: Permissions.Summary?

    private func updateButton() {
        guard let b = item.button else { return }
        let waiting = model.visibleSessions.filter { $0.state.needsUser }.count + model.looks.count
        // Redraw the menu bar icon only when the number of waiting requests changes, not on every event.
        guard waiting != shownWaiting else { return }
        shownWaiting = waiting
        let img = NSImage(systemSymbolName: waiting > 0 ? "circle.hexagongrid.fill" : "circle.hexagongrid",
                          accessibilityDescription: "Agent HUD")
        img?.isTemplate = true
        b.image = img
        b.imagePosition = .imageLeading
        b.title = waiting > 0 ? " \(waiting)" : ""
        b.toolTip = waiting > 0 ? "Agent HUD: \(waiting) waiting for you" : "Agent HUD"
    }

    // MARK: - Popover

    var isShown: Bool { popover.isShown }
    var shownSize: CGSize { popover.contentViewController?.view.fittingSize ?? .zero }
    func close() { closePopover() }
    var windowVisible: Bool { popover.contentViewController?.view.window?.isVisible ?? false }

    /// Close without animation: the animated close of an NSPopover sometimes doesn't work
    /// while the show animation is running.
    private func closePopover() {
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    @objc private func toggle(_ sender: Any?) {
        if popover.isShown { closePopover(); return }
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        show()
    }

    /// Right click: the short menu. The item's own `menu` stays unset, otherwise a left click would open it too.
    private func showMenu() {
        guard let b = item.button else { return }
        let m = NSMenu()
        m.addItem(ClosureMenuItem(title: "New session…") { [weak self] in self?.model.newSession() })
        m.addItem(ClosureMenuItem(title: "Continue a session…") { [weak self] in self?.model.continueSessionWindow() })
        m.addItem(ClosureMenuItem(title: "Control panel") { [weak self] in self?.show() })
        m.addItem(ClosureMenuItem(title: "Agent map") { [weak self] in self?.model.openMap() })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem(title: "Quit Agent HUD") { NSApp.terminate(nil) })
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    func show() {
        guard let b = item.button else { return }
        popover.contentViewController = NSHostingController(rootView: panel())
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        Task { @MainActor [weak self] in
            let states = await PermissionProbe.states()
            self?.permissions = Permissions.summary(states.mapValues(\.status))
            self?.refresh()
        }
    }

    /// Config and launch-at-login statuses are read on every open (and after actions).
    private func panel() -> ControlPanelView {
        var installed: [AgentKind: Bool] = [:]
        var present: [AgentKind: Bool] = [:]
        for k in AgentKind.allCases {
            installed[k] = HookSetup.isInstalled(k)
            present[k] = HookSetup.agentPresent(k)
        }
        return ControlPanelView(model: model, settings: model.settings, actions: actions(),
                                installed: installed, present: present,
                                loginItem: LoginItem.isEnabled, permissions: permissions)
    }

    private func refresh() {
        guard popover.isShown, let host = popover.contentViewController as? NSHostingController<ControlPanelView> else { return }
        host.rootView = panel()
    }

    /// Dialogs (NSAlert) are shown after the popover closes, otherwise it covers them.
    private func afterClose(_ body: @escaping @MainActor () -> Void) {
        closePopover()
        Task { @MainActor in body() }
    }

    private func actions() -> PanelActions {
        var a = PanelActions()
        a.openSession = { [weak self] key in
            guard let self else { return }
            self.model.settings.hudVisible = true
            self.model.selectedKey = key
            self.model.selectedByUser = true
            self.closePopover()
        }
        a.focusSession = { [weak self] key in
            self?.closePopover()
            self?.model.open(key)
        }
        a.connect = { [weak self] kind in
            guard let self else { return }
            let timeout = self.model.settings.hookTimeout
            self.afterClose { HookSetup.install(kind, timeout: timeout) }
        }
        a.disconnect = { [weak self] kind in
            self?.afterClose { HookSetup.uninstall(kind) }
        }
        a.setTimeout = { [weak self] seconds in
            guard let self, seconds != self.model.settings.hookTimeout else { return }
            self.model.settings.hookTimeout = seconds
            let kinds = AgentKind.allCases.filter { HookSetup.isInstalled($0) }
            guard !kinds.isEmpty else { self.refresh(); return }
            // The time is baked into the hook command - reinstall with confirmation.
            self.afterClose { for k in kinds { HookSetup.install(k, timeout: seconds) } }
        }
        a.setLoginItem = { [weak self] on in
            do { try LoginItem.set(on) } catch {
                self?.afterClose { HookSetup.info("Couldn't change launch at login", error.localizedDescription, style: .warning) }
                return
            }
            self?.refresh()
        }
        a.resetPosition = { [weak self] in
            self?.hud.resetPosition()
            self?.closePopover()
        }
        a.openLog = { [weak self] in
            self?.closePopover()
            let url = AgentHUDPaths.decisionsLog
            if !FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: url)
            }
            NSWorkspace.shared.open(url)
        }
        a.openMap = { [weak self] in
            self?.closePopover()
            self?.model.openMap()
        }
        a.newSession = { [weak self] in
            self?.closePopover()
            self?.model.newSession()
        }
        a.continueSession = { [weak self] in
            self?.closePopover()
            self?.model.continueSessionWindow()
        }
        a.openSetup = { [weak self] in
            self?.closePopover()
            self?.model.openSetup()
        }
        a.openSummary = { [weak self] in
            guard let self else { return }
            self.closePopover()
            NSWorkspace.shared.open(self.model.writeSummary())
        }
        a.openReport = { [weak self] in
            self?.closePopover()
            self?.model.openReportTab()
        }
        a.quickReport = { [weak self] in
            guard let self else { return }
            self.closePopover()
            let r = ReportPreset.since15Yesterday.range(now: Date(), calendar: .current)
            NSWorkspace.shared.open(self.model.writeReport(from: r.from, to: r.to))
        }
        a.quit = { NSApp.terminate(nil) }
        return a
    }
}
