import AgentHudCore
import Darwin
import Foundation

// agenthud-hook <agent> <event|permission|question> [--timeout N]
//
// Правило: хук никогда не ломает сессию агента. Любая проблема → код 0 и пустой stdout,
// и агент ведёт себя так, будто AgentHUD нет.

signal(SIGPIPE, SIG_IGN)

func passthrough() -> Never { exit(0) }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2,
      let kind = AgentKind(rawValue: args[0]),
      let mode = HookMode(rawValue: args[1]) else {
    FileHandle.standardError.write(Data("usage: agenthud-hook <claude> <event|permission|question> [--timeout N]\n".utf8))
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
    passthrough()   // автоматизация (SDK, скрипт, служебный запрос) — HUD не вмешивается
}
let message = HookMessage(
    agent: kind, mode: mode,
    requestId: UUID().uuidString.lowercased(),
    deadline: deadline,
    host: host,
    payload: payload
)

guard let fd = SocketIO.connect(path: AgentHUDPaths.socketPath, timeoutMs: HookTiming.connectTimeoutMs) else {
    passthrough()   // приложение не запущено
}
guard SocketIO.writeAll(fd, message.encode()) else { close(fd); passthrough() }

guard mode.isSync, let deadline else {
    close(fd)
    passthrough()
}

// Ждём решения пользователя. Если агент сам убьёт хук (ответили в терминале),
// соединение закроется, и приложение снимет окошко.
guard let line = SocketIO.readLine(fd, until: deadline),
      let reply = HookReply.decode(line),
      reply.requestId == message.requestId else {
    close(fd)
    passthrough()   // просрочено или приложение закрылось
}
close(fd)

if let out = adapter.hookOutput(for: reply.decision, mode: mode, payload: payload) {
    FileHandle.standardOutput.write(Data((out + "\n").utf8))
}
exit(0)
