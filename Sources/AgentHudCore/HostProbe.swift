import Darwin
import Foundation

/// Detects where the agent is running: a terminal (TTY, herdr) or the Claude desktop app.
/// Works through sysctl - without launching external processes, so the hook stays fast.
public enum HostProbe {
    public struct ProcInfo: Equatable {
        public let pid: Int32
        public let ppid: Int32
        public let tty: String?
        public let name: String
    }

    public static func info(pid: Int32) -> ProcInfo? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let ppid = kp.kp_eproc.e_ppid
        let dev = kp.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, dev != 0, let name = devname(dev, S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        let name = withUnsafePointer(to: kp.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
        return ProcInfo(pid: pid, ppid: ppid, tty: tty, name: name)
    }

    /// Process chain from `start` up to launchd.
    public static func chain(from start: Int32, limit: Int = 16) -> [ProcInfo] {
        var out: [ProcInfo] = []
        var pid = start
        while pid > 1, out.count < limit, let i = info(pid: pid) {
            out.append(i)
            pid = i.ppid
        }
        return out
    }

    /// Build HostInfo for the current hook process.
    public static func current(env: [String: String] = ProcessInfo.processInfo.environment) -> HostInfo {
        let chain = chain(from: getppid())
        let agent = agentProcess(in: chain)
        let tty = agent?.tty ?? chain.first(where: { $0.tty != nil })?.tty
        let inHerdr = env["HERDR_ENV"] == "1" && env["HERDR_PANE_ID"] != nil
        let app = hostApp(in: chain)
        return HostInfo(
            termProgram: env["TERM_PROGRAM"],
            tty: tty,
            agentPid: agent?.pid,
            herdrPaneId: inHerdr ? env["HERDR_PANE_ID"] : nil,
            herdrSocket: inHerdr ? env["HERDR_SOCKET_PATH"] : nil,
            processChain: chain.prefix(8).map(\.name),
            appBundleId: app?.bundleId,
            appName: app?.name,
            hostSessionId: env["CLAUDE_CODE_HOST_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 },
            entrypoint: env["CLAUDE_CODE_ENTRYPOINT"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Full path of the process executable.
    public static func executablePath(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// The .app bundle from an executable path: "/Applications/Claude.app/Contents/MacOS/Claude" -> "/Applications/Claude.app".
    public static func bundlePath(forExecutable path: String) -> String? {
        guard let r = path.range(of: ".app/Contents/MacOS/", options: .backwards) else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The outermost GUI app in the chain (Terminal, Claude...).
    /// Outermost, because Claude Code itself also sits in a `claude.app` bundle inside the app's data.
    static func hostApp(in chain: [ProcInfo]) -> (bundleId: String, name: String)? {
        for p in chain.reversed() {
            guard let exe = executablePath(pid: p.pid), let bundle = bundlePath(forExecutable: exe),
                  let info = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist"),
                  let id = info["CFBundleIdentifier"] as? String else { continue }
            let name = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String)
                ?? ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (id, name)
        }
        return nil
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "-zsh", "-bash", "login"]

    /// The agent runs the hook directly, but sometimes through a shell. The Claude Code process
    /// may then be named after a version number ("2.1.322"), so we do not search by name:
    /// we take the first ancestor that is not a shell.
    public static func agentProcess(in chain: [ProcInfo]) -> ProcInfo? {
        chain.first { !shells.contains($0.name) } ?? chain.first
    }

    /// The HUD shows sessions with a human behind them: terminal, VS Code and the Claude desktop app.
    /// The SDK, `claude -p` from scripts and apps' service requests bypass it - otherwise
    /// the synchronous hook would hang automation until a reply in the HUD. `AGENTHUD_ANY_HOST=1` removes the filter (for tests).
    public static func isInteractive(kind: AgentKind, host: HostInfo, env: [String: String]) -> Bool {
        if env["AGENTHUD_ANY_HOST"] == "1" { return true }
        switch kind {
        case .claude:
            switch env["CLAUDE_CODE_ENTRYPOINT"] {
            case "claude-desktop":
                // A real app session has its own id (local_...); service requests do not.
                return env["CLAUDE_CODE_HOST_SESSION_ID"]?.isEmpty == false
            case HostInfo.vscodeEntrypoint:
                // Chat panel of the Claude Code extension. No TTY; a GUI app in the process chain means a person is there.
                // Any editor built on VS Code counts, not only the ones known by bundle id.
                return host.appBundleId != nil
            case nil, "cli":
                return host.tty != nil
            default:
                return false   // sdk-*, other editors
            }
        }
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
