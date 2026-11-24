import AgentHudCore
import AppKit
import Foundation

/// Whether Claude Code knows the screen tools server, as the setup window shows it.
struct ScreenToolsState: Equatable {
    var status: ScreenTools.Status = .unknown
    var detail: String? = nil
    var busy = false
}

/// Registering `agenthud-mcp` in Claude Code's user configuration for sessions this app does not start.
/// Claude Code's own `claude mcp` commands do the work; this app never edits that configuration itself.
/// Running them talks to no model and costs nothing.
@MainActor
enum ScreenToolsSetup {
    /// Where the helper binary lives: inside the .app or next to the app binary (build from source).
    static func bundledHelper() -> URL? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agenthud-mcp"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("agenthud-mcp"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// `~/.local/bin/agenthud-mcp` -> the binary from the app, so the registered path survives app updates.
    static func ensureSymlink() throws -> URL {
        let link = AgentHUDPaths.mcpSymlink
        guard let target = bundledHelper() else {
            throw NSError(domain: "AgentHUD", code: 1, userInfo: [NSLocalizedDescriptionKey: "agenthud-mcp binary not found next to the app."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), existing == target.path { return link }
        if (try? fm.attributesOfItem(atPath: link.path)) != nil { try fm.removeItem(at: link) }
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        return link
    }

    /// The same discovery as for sessions started here.
    static func claude() -> String? {
        OwnedSessionLogic.findExecutable(
            override: ProcessInfo.processInfo.environment["AGENTHUD_CLAUDE_BIN"],
            home: FileManager.default.homeDirectoryForCurrentUser.path,
            isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Asks Claude Code whether the server is configured (`claude mcp get agenthud`). Changes nothing.
    static func status() async -> ScreenToolsState {
        guard let cli = claude() else { return ScreenToolsState(status: .unknown, detail: "Claude Code not found") }
        guard let r = await run(cli, ScreenTools.statusArguments) else {
            return ScreenToolsState(status: .unknown, detail: "Claude Code did not answer")
        }
        return ScreenToolsState(status: ScreenTools.status(exitCode: r.code, output: r.output))
    }

    /// Shows the exact command, and runs it only after the person agrees. Returns a problem to show, if any.
    static func connect() async -> String? {
        guard let cli = claude() else { return "Claude Code was not found on this Mac." }
        let link: URL
        do { link = try ensureSymlink() } catch { return error.localizedDescription }
        guard let args = ScreenTools.addArguments(helperPath: link.path) else { return "The helper's path cannot be used: \(link.path)" }
        let text = """
        Agent HUD will run this command:

        \(ScreenTools.display(program: cli, arguments: args))

        It adds one entry named "\(ScreenTools.serverName)" to Claude Code's user configuration, so every Claude Code session gets three read-only tools: list_windows, screenshot and read_window_text. Sessions that are already open pick them up after a restart.

        Nothing is allowed in advance: Claude Code still asks before a tool runs, and every look then asks you in Agent HUD.
        """
        guard HookSetup.confirm("Connect the screen tools to Claude Code?", text, ok: "Connect") else { return nil }
        guard let r = await run(cli, args) else { return "Claude Code did not answer." }
        return r.code == 0 ? nil : "Claude Code refused the command (code \(r.code)).\n\n\(r.output.suffix(600))"
    }

    static func disconnect() async -> String? {
        guard let cli = claude() else { return "Claude Code was not found on this Mac." }
        let args = ScreenTools.removeArguments
        let text = """
        Agent HUD will run this command:

        \(ScreenTools.display(program: cli, arguments: args))

        It removes the "\(ScreenTools.serverName)" entry from Claude Code's user configuration. Sessions started in Agent HUD keep their screen tools.
        """
        guard HookSetup.confirm("Disconnect the screen tools from Claude Code?", text, ok: "Disconnect") else { return nil }
        guard let r = await run(cli, args) else { return "Claude Code did not answer." }
        return r.code == 0 ? nil : "Claude Code refused the command (code \(r.code)).\n\n\(r.output.suffix(600))"
    }

    /// The shell only replaces itself with the program given as arguments; nothing is spliced into this string.
    private static let shellScript = "exec \"$0\" \"$@\""

    /// Runs the CLI with an argument list (through the login shell only for its PATH) and collects what it prints.
    /// nil when it could not be started or did not finish in time.
    private static func run(_ cli: String, _ arguments: [String], timeout: TimeInterval = 30) async -> (code: Int32, output: String)? {
        let env = OwnedSession.Config.childEnvironment(ProcessInfo.processInfo.environment)
        let script = shellScript
        return await Task.detached(priority: .userInitiated) { () -> (code: Int32, output: String)? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", script, cli] + arguments
            p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            p.environment = env
            let pipe = Pipe()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return nil }
            // A watchdog ends a command that hangs; reading to the end of the pipe below then returns.
            let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            watchdog.cancel()
            guard p.terminationReason == .exit else { return nil }
            return (p.terminationStatus, String(decoding: data.suffix(8000), as: UTF8.self))
        }.value
    }
}
