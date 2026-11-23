import AgentHudCore
import AppKit
import Foundation

/// Подключение AgentHUD к агентам: симлинк хука и правка их конфига
/// (`~/.claude/settings.json`) с показом изменений и бэкапом.
@MainActor
enum HookSetup {
    static func isInstalled(_ kind: AgentKind) -> Bool {
        guard let data = try? Data(contentsOf: kind.hooksFile), let v = try? JSONValue.parse(data) else { return false }
        return HookInstaller.isInstalled(in: v)
    }

    /// Агент установлен на машине (есть его папка настроек).
    static func agentPresent(_ kind: AgentKind) -> Bool {
        FileManager.default.fileExists(atPath: kind.hooksFile.deletingLastPathComponent().path)
    }

    static func trustNote(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "Уже открытые сессии Claude Code подхватят хуки сами."
        }
    }

    // MARK: - Без диалогов (CLI)

    @discardableResult
    static func connect(_ kind: AgentKind, timeout: Int) throws -> HookInstaller.FileResult {
        let link = try ensureSymlink()
        let installer = HookInstaller(agent: kind, hookPath: link.path, timeout: timeout)
        return try HookInstaller.apply(file: kind.hooksFile) { installer.install(into: $0) }
    }

    @discardableResult
    static func disconnect(_ kind: AgentKind) throws -> HookInstaller.FileResult {
        try HookInstaller.apply(file: kind.hooksFile) { HookInstaller.uninstall(from: $0) }
    }

    /// Где лежит настоящий бинарник хука: внутри .app или рядом с бинарником приложения (сборка из исходников).
    static func bundledHook() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agenthud-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agenthud-hook"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `~/.local/bin/agenthud-hook` → бинарник из приложения. Путь в settings.json не меняется при обновлениях.
    static func ensureSymlink() throws -> URL {
        let link = AgentHUDPaths.hookSymlink
        guard let target = bundledHook() else {
            throw NSError(domain: "AgentHUD", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден бинарник agenthud-hook рядом с приложением."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), existing == target.path { return link }
        if (try? fm.attributesOfItem(atPath: link.path)) != nil { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    static func install(_ kind: AgentKind, timeout: Int) {
        let file = kind.hooksFile
        do {
            let link = try ensureSymlink()
            let installer = HookInstaller(agent: kind, hookPath: link.path, timeout: timeout)
            let (before, after) = try HookInstaller.preview(file: file) { installer.install(into: $0) }
            guard before != after else { info("Уже подключено", "Хуки Agent HUD в \(tilde(file.path)) уже на месте."); return }
            let summary = """
            В \(tilde(file.path)) добавятся хуки Agent HUD (по одному на событие). Ваши хуки (herdr, Orca, плагины) останутся как есть.

            Перед записью будет сделана копия файла: \(file.lastPathComponent).agenthud-backup-<дата>.

            Время на ответ в HUD: \(timeout / 60) мин. Потом запрос уходит в терминал.

            \(trustNote(kind))

            Хук: \(tilde(link.path))

            Что добавится:
            \(installer.plannedEntries().pretty())
            """
            guard confirm("Подключить Agent HUD к \(kind.displayName)?", summary, ok: "Подключить") else { return }
            let r = try HookInstaller.apply(file: file) { installer.install(into: $0) }
            info("Готово", "Хуки подключены. \(trustNote(kind))\n\nКопия старого файла: \(r.backup.map { tilde($0.path) } ?? "не понадобилась")")
        } catch {
            info("Не получилось подключить", error.localizedDescription, style: .critical)
        }
    }

    static func uninstall(_ kind: AgentKind) {
        let file = kind.hooksFile
        do {
            let (before, after) = try HookInstaller.preview(file: file) { HookInstaller.uninstall(from: $0) }
            guard before != after else { info("Нечего отключать", "Хуков Agent HUD в \(tilde(file.path)) нет."); return }
            guard confirm("Отключить Agent HUD от \(kind.displayName)?", "Из \(tilde(file.path)) будут удалены только записи Agent HUD. Перед записью будет сделана копия файла.", ok: "Отключить") else { return }
            let r = try disconnect(kind)
            info("Отключено", "Записи Agent HUD удалены.\n\nКопия: \(r.backup.map { tilde($0.path) } ?? "—")")
        } catch {
            info("Не получилось отключить", error.localizedDescription, style: .critical)
        }
    }

    // MARK: - Диалоги

    static func confirm(_ title: String, _ text: String, ok: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = ""
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        tv.string = text
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 300))
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.borderType = .bezelBorder
        a.accessoryView = sv
        a.addButton(withTitle: ok)
        a.addButton(withTitle: "Отмена")
        return a.runModal() == .alertFirstButtonReturn
    }

    static func info(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    static func tilde(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}
