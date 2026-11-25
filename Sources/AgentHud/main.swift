import AgentHudCore
import AppKit
import Carbon.HIToolbox
@preconcurrency import UserNotifications

// AgentHUD - a HUD for AI agents: VS Code, terminal, the Claude app.
//
//   AgentHUD                      normal launch (menu bar + floating panel)
//   AgentHUD --summary [YYYY-MM-DD]  daily agent summary in Markdown (default - today)
//   AgentHUD --report <from> [<to>]    period report in Markdown

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var model = AppModel(settings: settings)
    var hud: HUDController!
    var menu: StatusMenu!
    var map: AgentMapController!
    var setup: SetupController!
    var newSession: NewSessionController!
    var hotKeys: HotKeyRegistry?
    var commandBar: CommandBarController!
    var routineEditor: RoutineEditorController!

    /// The app shows no menu bar, but Command-V, C, X, A and Z reach a text field only through menu items.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        let main = NSMenu()
        main.addItem(item)
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        installEditMenu()
        // Before the start: routines that are due at launch may need to tell the person right away.
        model.routines.postNotice = { [weak self] title, body, id in self?.postNotification(title: title, body: body, id: id) }
        do {
            try model.start()
        } catch {
            if case SocketServer.StartError.alreadyRunning = error {
                NSLog("AgentHUD is already running - exiting")
                NSApp.terminate(nil)
                return
            }
            HookSetup.info("Agent HUD failed to start", "\(error)", style: .critical)
            NSApp.terminate(nil)
            return
        }
        hud = HUDController(model: model)
        menu = StatusMenu(model: model, hud: hud)
        map = AgentMapController(model: model)
        setup = SetupController(settings: settings)
        setup.permissionsInUse = { [weak self] in self?.model.permissionsInUse ?? [] }
        model.onRequestNeedsAttention = { [weak self] s in self?.notifyIfHidden(s) }
        model.onOpenMap = { [weak self] in self?.map.show() }
        model.onOpenSetup = { [weak self] kind in self?.setup.show(highlight: kind) }
        newSession = NewSessionController(model: model)
        model.onNewSession = { [weak self] folder, message in self?.newSession.show(folder: folder, message: message) }
        model.onContinueSession = { [weak self] in self?.newSession.show(tab: .continueSession) }
        model.onNewSessionWithText = { [weak self] text in self?.newSession.show(text: text) }
        routineEditor = RoutineEditorController(app: model)
        model.onEditRoutine = { [weak self] routine in self?.routineEditor.show(editing: routine) }
        hud.updateVisibility()
        if CommandLine.arguments.contains("--map") { map.show() }

        // First launch (also the first launch of an install that predates the setup window): show the setup window once.
        // Not in test mode with its own socket. Opening it requests nothing.
        let testMode = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"] != nil
        // Global hotkeys: stop agent actions, and the command bar. A test instance with its own socket leaves them to the real one.
        let registry: HotKeyRegistry? = testMode ? nil : HotKeyRegistry()
        hotKeys = registry
        if let registry,
           !registry.register(id: HotKeyId.stopActions, keyCode: UInt32(kVK_ANSI_Period),
                              modifiers: UInt32(controlKey | optionKey | cmdKey), action: { [weak self] in self?.model.stopAgentActions() }) {
            NSLog("AgentHUD: the stop hotkey could not be registered")
        }
        commandBar = CommandBarController(app: model, registry: registry)
        model.onOpenCommandBar = { [weak self] in self?.commandBar.show() }
        let defaults = UserDefaults.standard
        if CommandLine.arguments.contains("--setup") {
            setup.show()
        } else if !testMode, !defaults.bool(forKey: "setupShown") {
            defaults.set(true, forKey: "setupShown")
            defaults.set(true, forKey: "askedInstall")
            setup.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func notifyIfHidden(_ s: AgentSession) {
        guard !hud.isShown else { return }
        postNotification(title: "\(s.projectName): \(s.stateTitle.lowercased())",
                         body: s.title.isEmpty ? "The agent is waiting for a reply" : s.title,
                         id: s.activePending?.id ?? UUID().uuidString)
    }

    /// The one place that shows a system notification (requests and routines): honours the notifications setting
    /// and asks the system for permission the first time.
    private func postNotification(title: String, body: String, id: String) {
        guard settings.notifications, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            let center = UNUserNotificationCenter.current()
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            center.add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
        }
    }
}

// Connecting without dialogs: AgentHUD --connect claude|all [--timeout N], --disconnect ..., --status
if let i = CommandLine.arguments.firstIndex(where: { $0 == "--connect" || $0 == "--disconnect" || $0 == "--status" }) {
    let args = CommandLine.arguments
    let verb = args[i]
    let target = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "all"
    // "all" - only agents present on this machine: don't create ~/.claude without Claude Code.
    let kinds: [AgentKind] = MainActor.assumeIsolated {
        guard target == "all" else { return AgentKind(rawValue: target).map { [$0] } ?? [] }
        return AgentKind.allCases.filter { verb == "--connect" ? HookSetup.agentPresent($0) : true }
    }
    var timeout = HookTiming.defaultTimeout
    if let t = args.firstIndex(of: "--timeout"), t + 1 < args.count, let v = Int(args[t + 1]) { timeout = v }
    let code: Int32 = MainActor.assumeIsolated {
        guard !kinds.isEmpty else { print("Unknown agent: \(target). Options: claude, all"); return 2 }
        var failed = false
        for kind in kinds {
            let file = HookSetup.tilde(kind.hooksFile.path)
            do {
                switch verb {
                case "--connect":
                    let r = try HookSetup.connect(kind, timeout: timeout)
                    print("\(kind.displayName): connected -> \(file)" + (r.backup.map { " (backup: \(HookSetup.tilde($0.path)))" } ?? " (no changes)"))
                case "--disconnect":
                    let r = try HookSetup.disconnect(kind)
                    print("\(kind.displayName): disconnected -> \(file)" + (r.backup.map { " (backup: \(HookSetup.tilde($0.path)))" } ?? " (was not connected)"))
                default:
                    print("\(kind.displayName): \(HookSetup.isInstalled(kind) ? "connected" : "not connected") (\(file))")
                }
            } catch {
                print("\(kind.displayName): error - \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
    exit(code)
}

// Daily summary: AgentHUD --summary [YYYY-MM-DD] - Markdown to stdout (for standup).
if let i = CommandLine.arguments.firstIndex(of: "--summary") {
    var day = Date()
    if i + 1 < CommandLine.arguments.count {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: CommandLine.arguments[i + 1]) else {
            print("Date format is YYYY-MM-DD, e.g. 2026-11-20")
            exit(2)
        }
        day = d
    }
    print(DailySummary.markdown(DailySummary.build(ActivityLog.read(day: day)), day: day), terminator: "")
    exit(0)
}

// Period report: AgentHUD --report <from> [<to>] - Markdown to stdout. Time: ISO 8601 or "YYYY-MM-DD HH:mm" (local).
if let i = CommandLine.arguments.firstIndex(of: "--report") {
    func parse(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        if let d = f.date(from: s) { return d }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s)
    }
    let rest = Array(CommandLine.arguments.dropFirst(i + 1))
    guard (1...2).contains(rest.count), let from = parse(rest[0]), let to = rest.count == 2 ? parse(rest[1]) : Date(), from <= to else {
        FileHandle.standardError.write(Data("Usage: AgentHUD --report <from> [<to>]  (ISO 8601 or \"YYYY-MM-DD HH:mm\", <to> defaults to now)\n".utf8))
        exit(2)
    }
    print(PeriodReport.markdown(PeriodReport.load(from: from, to: to), from: from, to: to), terminator: "")
    exit(0)
}

// Launch at login: AgentHUD --login-item on|off|status
if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    do {
        switch arg {
        case "on": try LoginItem.set(true)
        case "off": try LoginItem.set(false)
        default: break
        }
        print("Launch at login: \(LoginItem.statusText)")
        exit(0)
    } catch {
        print("Launch at login: error - \(error.localizedDescription). Now: \(LoginItem.statusText)")
        exit(1)
    }
}

// Developer check: AgentHud --render <dir> draws the views to PNG files and exits.
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        RenderCheck.run(dir: dir)
    }
    exit(0)
}

// Developer check: AgentHud --routines-check <dir> runs routines against a fake CLI with an injected clock and exits.
if let i = CommandLine.arguments.firstIndex(of: "--routines-check"), i + 1 < CommandLine.arguments.count {
    let dir = CommandLine.arguments[i + 1]
    let code: Int32 = MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return RoutinesCheck.run(dir: dir)
    }
    exit(code)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
