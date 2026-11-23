import AgentHudCore
import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
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
        model.onRequestNeedsAttention = { [weak self] s in self?.notifyIfHidden(s) }
        model.onOpenMap = { [weak self] in self?.map.show() }
        model.onOpenSetup = { [weak self] kind in self?.setup.show(highlight: kind) }
        newSession = NewSessionController(model: model)
        model.onNewSession = { [weak self] folder, message in self?.newSession.show(folder: folder, message: message) }
        hud.updateVisibility()
        if CommandLine.arguments.contains("--map") { map.show() }

        // First launch (also the first launch of an install that predates the setup window): show the setup window once.
        // Not in test mode with its own socket. Opening it requests nothing.
        let testMode = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"] != nil
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
        guard settings.notifications, !hud.isShown, Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            let center = UNUserNotificationCenter.current()
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "\(s.projectName): \(s.state.title.lowercased())"
            c.body = s.title.isEmpty ? "The agent is waiting for a reply" : s.title
            center.add(UNNotificationRequest(identifier: s.activePending?.id ?? UUID().uuidString, content: c, trigger: nil))
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

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
