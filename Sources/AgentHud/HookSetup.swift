import AgentHudCore
import AppKit
import Foundation

/// Connecting AgentHUD to agents: a hook symlink and editing their config
/// (`~/.claude/settings.json`) with a preview of changes and a backup.
@MainActor
enum HookSetup {
    static func isInstalled(_ kind: AgentKind) -> Bool {
        guard let data = try? Data(contentsOf: kind.hooksFile), let v = try? JSONValue.parse(data) else { return false }
        return HookInstaller.isInstalled(in: v)
    }

    /// Connected with an older form of the hooks: Pause and Stop need the PreToolUse entry to be the `gate` one.
    static func needsUpdate(_ kind: AgentKind) -> Bool {
        guard let data = try? Data(contentsOf: kind.hooksFile), let v = try? JSONValue.parse(data) else { return false }
        return HookInstaller.needsUpdate(in: v)
    }

    /// The agent is installed on this machine (its settings folder exists).
    static func agentPresent(_ kind: AgentKind) -> Bool {
        FileManager.default.fileExists(atPath: kind.hooksFile.deletingLastPathComponent().path)
    }

    static func trustNote(_ kind: AgentKind) -> String {
        switch kind {
        case .claude: return "Claude Code sessions that are already open will pick up the hooks on their own."
        }
    }

    // MARK: - No dialogs (CLI)

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

    /// Where the real hook binary lives: inside the .app or next to the app binary (build from source).
    static func bundledHook() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agenthud-hook"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agenthud-hook"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `~/.local/bin/agenthud-hook` -> the binary from the app. The path in settings.json doesn't change across updates.
    static func ensureSymlink() throws -> URL {
        let link = AgentHUDPaths.hookSymlink
        guard let target = bundledHook() else {
            throw NSError(domain: "AgentHUD", code: 1, userInfo: [NSLocalizedDescriptionKey: "agenthud-hook binary not found next to the app."])
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
            guard before != after else { info("Already connected", "Agent HUD hooks are already in \(tilde(file.path))."); return }
            let summary = """
            Agent HUD hooks (one per event) will be added to \(tilde(file.path)). Your own hooks (herdr, Orca, plugins) stay as they are.

            The file will be backed up before writing: \(file.lastPathComponent).agenthud-backup-<date>.

            Time to answer in the HUD: \(timeout / 60) min. After that the request goes to the terminal.

            Pause and Stop: the PreToolUse hook asks Agent HUD before every tool call (one local round trip, at most \(Int(HookTiming.gateAnswerTimeout)) s if the app does not answer) and waits while the session is paused or stopped. Without the app, and when it quits, tool calls go on as usual.

            \(trustNote(kind))

            Hook: \(tilde(link.path))

            What will be added:
            \(installer.plannedEntries().pretty())
            """
            guard confirm("Connect Agent HUD to \(kind.displayName)?", summary, ok: "Connect") else { return }
            let r = try HookInstaller.apply(file: file) { installer.install(into: $0) }
            info("Done", "Hooks connected. \(trustNote(kind))\n\nBackup of the old file: \(r.backup.map { tilde($0.path) } ?? "not needed")")
        } catch {
            info("Couldn't connect", error.localizedDescription, style: .critical)
        }
    }

    static func uninstall(_ kind: AgentKind) {
        let file = kind.hooksFile
        do {
            let (before, after) = try HookInstaller.preview(file: file) { HookInstaller.uninstall(from: $0) }
            guard before != after else { info("Nothing to disconnect", "No Agent HUD hooks in \(tilde(file.path))."); return }
            guard confirm("Disconnect Agent HUD from \(kind.displayName)?", "Only Agent HUD entries will be removed from \(tilde(file.path)). The file will be backed up before writing.", ok: "Disconnect") else { return }
            let r = try disconnect(kind)
            info("Disconnected", "Agent HUD entries removed.\n\nBackup: \(r.backup.map { tilde($0.path) } ?? "—")")
        } catch {
            info("Couldn't disconnect", error.localizedDescription, style: .critical)
        }
    }

    // MARK: - Dialogs

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
        a.addButton(withTitle: "Cancel")
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
