import AgentHudCore
import Darwin
import Foundation

// agenthud-hook <agent> <event|permission|gate|question> [--timeout N]
//
// Rule: the hook never breaks the agent's session. Any problem -> exit code 0 and empty stdout,
// and the agent behaves as if AgentHUD were not there.

signal(SIGPIPE, SIG_IGN)

func passthrough() -> Never { exit(0) }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2,
      let kind = AgentKind(rawValue: args[0]),
      let mode = HookMode(rawValue: args[1]) else {
    FileHandle.standardError.write(Data("usage: agenthud-hook <claude> <event|permission|gate|question> [--timeout N]\n".utf8))
    passthrough()
}

var timeout = HookTiming.defaultTimeout
if let i = args.firstIndex(of: "--timeout"), i + 1 < args.count, let t = Int(args[i + 1]), t > 0 {
    timeout = t
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let payload = try? JSONValue.parse(input), payload.objectValue != nil else { passthrough() }

let adapter = Adapters.adapter(for: kind)
guard adapter.shouldForward(mode: mode, payload: payload) else { passthrough() }

let started = Date()
let deadline = mode.isSync ? HookTiming.deadline(now: started, hookTimeout: timeout) : nil
let host = HostProbe.current()
guard HostProbe.isInteractive(kind: kind, host: host, env: ProcessInfo.processInfo.environment) else {
    passthrough()   // automation (SDK, script, service request) - the HUD does not interfere
}
let message = HookMessage(
    agent: kind, mode: mode,
    requestId: UUID().uuidString.lowercased(),
    deadline: deadline,
    host: host,
    payload: payload
)

guard let fd = SocketIO.connect(path: AgentHUDPaths.socketPath, timeoutMs: HookTiming.connectTimeoutMs) else {
    passthrough()   // the app is not running
}
guard SocketIO.writeAll(fd, message.encode()) else { close(fd); passthrough() }

guard mode.isSync, let deadline else {
    close(fd)
    passthrough()
}

if mode == .gate {
    // The app answers at once ("proceed") or says the session is held and replies on release.
    // Whatever goes wrong - no answer in time, a closed connection, an unreadable line - the tool call proceeds:
    // the only output of this mode is none. Every wait is bounded by `limit`, which never passes `deadline`.
    let sent = Date()
    var reader = SocketIO.LineReader(fd: fd)
    var limit = HookTiming.gateWaitLimit(started: sent, deadline: deadline, notice: nil)
    while let line = reader.next(until: limit) {
        // Anything but a hold notice ends the wait: a reply, or a line this hook does not understand.
        guard let notice = HoldNotice.decode(line), notice.requestId == message.requestId else { break }
        limit = HookTiming.gateWaitLimit(started: sent, deadline: deadline, notice: notice)
    }
    close(fd)
    passthrough()
}

// Permission, plan or question: wait for the user's decision, never past `deadline`. If the agent kills the hook
// itself (answered in the terminal), the connection closes and the app removes the popup.
// No reply in time, a closed connection or a line that is not a reply to this request -> no output,
// and Claude Code shows its own prompt or question.
guard let line = SocketIO.readLine(fd, until: deadline),
      let reply = HookReply.decode(line),
      reply.requestId == message.requestId else {
    close(fd)
    passthrough()   // expired or the app closed
}
close(fd)

if let out = adapter.hookOutput(for: reply.decision, mode: mode, payload: payload) {
    FileHandle.standardOutput.write(Data((out + "\n").utf8))
}
exit(0)
