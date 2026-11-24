import AgentHudCore
import AppKit
import Combine
import SwiftUI

/// Borderless panel that takes the keyboard without activating the app: whatever app was in front stays in
/// front, and gets the keyboard back as soon as the panel closes.
final class BarPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// The command bar: the global hotkey, the panel, and what happens on send.
@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    private let app: AppModel
    private let registry: HotKeyRegistry?
    let model: CommandBarModel
    private let panel: BarPanel
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private var commandCache: [String: [SlashCommand]] = [:]
    private var lastHeight: CGFloat = 80
    private let voice: VoiceController

    /// `registry`: nil leaves the hotkey out (a test instance with its own socket never registers one).
    /// `voiceServices`: the speech engines; nil builds the Apple ones, tests and renders pass fakes.
    init(app: AppModel, registry: HotKeyRegistry?, voiceServices: VoiceServices? = nil) {
        self.app = app
        self.registry = registry
        voice = VoiceController(app: app, services: voiceServices ?? .make())
        model = CommandBarModel(app: app)
        panel = BarPanel(contentRect: NSRect(x: 0, y: 0, width: CommandBarLogic.barWidth, height: 80),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closeRequested() }
        let host = FirstClickHostingView(rootView: CommandBarView(model: model).tint(Brand.accent))
        host.sizingOptions = []
        panel.contentView = host

        voice.attach(self)
        model.onClose = { [weak self] in self?.closeRequested() }
        model.onSetup = { [weak self] kind in
            self?.app.openSetup(kind)
            self?.hide()
        }
        model.onSubmit = { [weak self] interrupt in self?.submit(interrupt: interrupt) }
        model.onHeight = { [weak self] h in self?.heightChanged(h) }
        model.onNewConversation = { [weak self] in self?.newConversation() }
        model.onPicked = { [weak self] t in
            guard let self else { return }
            if t != .newSession { self.app.lastCommandBarTarget = t }
            self.loadCommands()
        }
        // The hotkey follows the setting.
        app.settings.$commandBarHotKey
            .sink { [weak self] id in self?.applyHotKey(id: id) }
            .store(in: &cancellables)
        // Sessions come and go while the bar is open: keep the list and the target valid.
        app.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshEntries() }
            .store(in: &cancellables)
    }

    var isOpen: Bool { panel.isVisible }

    // MARK: - Hotkey

    private func applyHotKey(id: String) {
        guard let registry else { return }
        let option = CommandBarHotKey.option(id: id)
        registry.unregister(id: HotKeyId.commandBar)
        guard let code = option.keyCode, let mods = option.modifiers else {
            app.commandBarHotKeyTaken = false
            return
        }
        // A press toggles the bar (or, with voice on, starts the tap-or-hold decision); the release ends a hold.
        let ok = registry.register(id: HotKeyId.commandBar, keyCode: code, modifiers: mods,
                                   action: { [weak self] in self?.voice.keyDown() },
                                   onRelease: { [weak self] in self?.voice.keyUp() })
        app.commandBarHotKeyTaken = !ok
        if !ok { NSLog("AgentHUD: the command bar hotkey could not be registered") }
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        refreshEntries()
        model.status = nil
        model.menuOpen = false
        app.commandHistory.stopWalking()
        let screen = Self.screenWithPointer()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(CommandBarLogic.barFrame(in: visible, height: lastHeight), display: true)
        panel.invalidateShadow()
        installMonitors()
        panel.makeKeyAndOrderFront(nil)
        model.focusTick += 1
        loadCommands()
    }

    /// Opens the bar for listening, or clears the line of an open one.
    func showForVoice() {
        if panel.isVisible {
            model.status = nil
            model.menuOpen = false
        } else {
            show()
        }
    }

    /// Esc: voice takes it while it is listening or counting down, otherwise the bar closes.
    private func closeRequested() {
        if voice.escapePressed() { return }
        hide()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeMonitors()
        panel.orderOut(nil)
        voice.barHidden()
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        MainActor.assumeIsolated { self.hide() }
    }

    private static func screenWithPointer() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// The content grew or shrank: the top edge stays where it is.
    private func heightChanged(_ h: CGFloat) {
        guard h > 0 else { return }
        lastHeight = h
        guard panel.isVisible else { return }
        let visible = (panel.screen ?? Self.screenWithPointer())?.visibleFrame ?? panel.frame
        let frame = CommandBarLogic.barFrame(in: visible, height: h)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    // MARK: - Click outside

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in other apps and on the desktop.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }) { monitors.append(g) }
        // Clicks in this app's other windows.
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            let window = event.window
            Task { @MainActor in
                guard let self, window !== self.panel else { return }
                self.hide()
            }
            return event
        }) { monitors.append(l) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    // MARK: - Targets and commands

    private func refreshEntries() {
        let entries = app.commandBarEntries()
        if entries != model.entries { model.entries = entries }
        let t = CommandBarLogic.resolve(remembered: panel.isVisible ? model.target : app.lastCommandBarTarget, in: entries)
        if t != model.target { model.target = t; loadCommands() }
    }

    /// Slash commands of the target's project, read off the main thread and kept per folder.
    private func loadCommands() {
        let cwd = model.targetEntry?.cwd
        let key = cwd ?? ""
        if let cached = commandCache[key] { model.commands = cached; return }
        model.commands = []
        Task { @MainActor in
            let list = await Task.detached(priority: .userInitiated) {
                SlashCommands.available(home: FileManager.default.homeDirectoryForCurrentUser,
                                        projectDir: cwd.map { URL(fileURLWithPath: $0, isDirectory: true) })
            }.value
            commandCache[key] = list
            if (model.targetEntry?.cwd ?? "") == key { model.commands = list }
        }
    }

    // MARK: - Actions

    private func newConversation() {
        app.newAssistantConversation()
        model.target = .assistant
        app.lastCommandBarTarget = .assistant
        model.menuOpen = false
        model.status = CommandBarModel.Status(text: "New conversation — the next command starts afresh")
        model.focusTick += 1
        loadCommands()
    }

    /// `byVoice`: the text was spoken; the answer is read aloud when the Assistant gives it.
    func submit(interrupt: Bool, byVoice: Bool = false) {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = model.target
        if target == .newSession {
            // The window takes the keyboard: the bar goes first.
            hide()
            model.text = ""
            app.recordCommand(text)
            _ = app.submitFromBar(target: target, text: text, interrupt: false, byVoice: byVoice)
            return
        }
        switch app.submitFromBar(target: target, text: text, interrupt: interrupt, byVoice: byVoice) {
        case .refused(let message):
            model.status = CommandBarModel.Status(text: message, isError: true)
        case .sent, .queued, .openedNewSession:
            app.recordCommand(text)
            app.lastCommandBarTarget = target
            model.text = ""
            model.status = nil
            hide()
        }
    }
}
