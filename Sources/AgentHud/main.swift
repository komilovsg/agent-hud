import AgentHudCore
import AppKit
@preconcurrency import UserNotifications

// AgentHUD — HUD для ИИ-агентов: VS Code, терминал, приложение Claude.
//
//   AgentHUD                      обычный запуск (строка меню + плавающая панель)
//   AgentHUD --summary [ГГГГ-ММ-ДД]  сводка агентов за день в Markdown (по умолчанию — сегодня)
//   AgentHUD --report <от> [<до>]    отчёт за период в Markdown

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = Settings()
    lazy var model = AppModel(settings: settings)
    var hud: HUDController!
    var menu: StatusMenu!
    var map: AgentMapController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        FontLoader.register()
        do {
            try model.start()
        } catch {
            if case SocketServer.StartError.alreadyRunning = error {
                NSLog("AgentHUD уже запущен — выходим")
                NSApp.terminate(nil)
                return
            }
            HookSetup.info("Agent HUD не запустился", "\(error)", style: .critical)
            NSApp.terminate(nil)
            return
        }
        hud = HUDController(model: model)
        menu = StatusMenu(model: model, hud: hud)
        map = AgentMapController(model: model)
        model.onRequestNeedsAttention = { [weak self] s in self?.notifyIfHidden(s) }
        model.onOpenMap = { [weak self] in self?.map.show() }
        hud.updateVisibility()
        if CommandLine.arguments.contains("--map") { map.show() }

        // Первый запуск: предложить подключиться (не в тестовом режиме со своим сокетом).
        let testMode = ProcessInfo.processInfo.environment["AGENTHUD_SOCKET"] != nil
        if !testMode, !UserDefaults.standard.bool(forKey: "askedInstall") {
            UserDefaults.standard.set(true, forKey: "askedInstall")
            for kind in AgentKind.allCases where HookSetup.agentPresent(kind) && !HookSetup.isInstalled(kind) {
                HookSetup.install(kind, timeout: settings.hookTimeout)
            }
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
            c.body = s.title.isEmpty ? "Агент ждёт ответа" : s.title
            center.add(UNNotificationRequest(identifier: s.activePending?.id ?? UUID().uuidString, content: c, trigger: nil))
        }
    }
}

// Подключение без диалогов: AgentHUD --connect claude|all [--timeout N], --disconnect …, --status
if let i = CommandLine.arguments.firstIndex(where: { $0 == "--connect" || $0 == "--disconnect" || $0 == "--status" }) {
    let args = CommandLine.arguments
    let verb = args[i]
    let target = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "all"
    // «all» — только агенты, которые есть на машине: не создаём ~/.claude без Claude Code.
    let kinds: [AgentKind] = MainActor.assumeIsolated {
        guard target == "all" else { return AgentKind(rawValue: target).map { [$0] } ?? [] }
        return AgentKind.allCases.filter { verb == "--connect" ? HookSetup.agentPresent($0) : true }
    }
    var timeout = HookTiming.defaultTimeout
    if let t = args.firstIndex(of: "--timeout"), t + 1 < args.count, let v = Int(args[t + 1]) { timeout = v }
    let code: Int32 = MainActor.assumeIsolated {
        guard !kinds.isEmpty else { print("Неизвестный агент: \(target). Варианты: claude, all"); return 2 }
        var failed = false
        for kind in kinds {
            let file = HookSetup.tilde(kind.hooksFile.path)
            do {
                switch verb {
                case "--connect":
                    let r = try HookSetup.connect(kind, timeout: timeout)
                    print("\(kind.displayName): подключено → \(file)" + (r.backup.map { " (копия: \(HookSetup.tilde($0.path)))" } ?? " (без изменений)"))
                case "--disconnect":
                    let r = try HookSetup.disconnect(kind)
                    print("\(kind.displayName): отключено → \(file)" + (r.backup.map { " (копия: \(HookSetup.tilde($0.path)))" } ?? " (не было подключено)"))
                default:
                    print("\(kind.displayName): \(HookSetup.isInstalled(kind) ? "подключено" : "не подключено") (\(file))")
                }
            } catch {
                print("\(kind.displayName): ошибка — \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
    exit(code)
}

// Сводка за день: AgentHUD --summary [ГГГГ-ММ-ДД] — Markdown в stdout (для стендапа).
if let i = CommandLine.arguments.firstIndex(of: "--summary") {
    var day = Date()
    if i + 1 < CommandLine.arguments.count {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: CommandLine.arguments[i + 1]) else {
            print("Дата в формате ГГГГ-ММ-ДД, например 2026-11-20")
            exit(2)
        }
        day = d
    }
    print(DailySummary.markdown(DailySummary.build(ActivityLog.read(day: day)), day: day), terminator: "")
    exit(0)
}

// Отчёт за период: AgentHUD --report <от> [<до>] — Markdown в stdout. Время: ISO 8601 или «ГГГГ-ММ-ДД ЧЧ:мм» (местное).
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
        FileHandle.standardError.write(Data("Использование: AgentHUD --report <от> [<до>]  (ISO 8601 или \"ГГГГ-ММ-ДД ЧЧ:мм\", до по умолчанию — сейчас)\n".utf8))
        exit(2)
    }
    print(PeriodReport.markdown(PeriodReport.load(from: from, to: to), from: from, to: to), terminator: "")
    exit(0)
}

// Автозапуск: AgentHUD --login-item on|off|status
if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
    let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
    do {
        switch arg {
        case "on": try LoginItem.set(true)
        case "off": try LoginItem.set(false)
        default: break
        }
        print("Автозапуск: \(LoginItem.statusText)")
        exit(0)
    } catch {
        print("Автозапуск: ошибка — \(error.localizedDescription). Сейчас: \(LoginItem.statusText)")
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
