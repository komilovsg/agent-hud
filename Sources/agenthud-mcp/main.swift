import AgentHudCore
import Darwin
import Foundation

// agenthud-mcp: an MCP server on stdin/stdout (one JSON-RPC message per line) with three read-only tools.
//
// It looks at nothing itself and holds no macOS permission. Every tool call becomes one request to the
// Agent HUD app over its socket; the app asks the person, does the looking and answers. Without the app,
// without consent or without an answer in time the call ends as a normal tool result marked as an error.
// Every wait has a deadline, and closing stdin ends the process.

signal(SIGPIPE, SIG_IGN)

let socketPath = AgentHUDPaths.socketPath
/// Only a hint for the app; it identifies the caller from the connection itself.
let claimedSession = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"].flatMap { $0.isEmpty ? nil : $0 }

/// Standard output is shared by the reader thread and the call threads: one whole line at a time.
final class Output: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBytes { Darwin.write(STDOUT_FILENO, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                exit(0)   // the client has gone
            }
            off += n
        }
    }
}

/// Tool calls in flight, by request id, so that a cancellation or the end of stdin can end their wait.
final class Calls: @unchecked Sendable {
    private let lock = NSCondition()
    private var sockets: [String: Int32] = [:]
    private var cancelled = Set<String>()
    private var running = 0

    func started() {
        lock.lock()
        running += 1
        lock.unlock()
    }

    /// The call's answer has been written (or dropped).
    func ended() {
        lock.lock()
        running -= 1
        lock.broadcast()
        lock.unlock()
    }

    /// Waits until no call is running, at most `seconds`.
    func waitUntilIdle(seconds: TimeInterval) {
        let limit = Date().addingTimeInterval(seconds)
        lock.lock()
        while running > 0, lock.wait(until: limit) {}
        lock.unlock()
    }

    func connected(_ key: String, _ fd: Int32) {
        lock.lock()
        defer { lock.unlock() }
        sockets[key] = fd
        // Cancelled before the connection was made.
        if cancelled.contains(key) { shutdown(fd, SHUT_RDWR) }
    }

    /// Returns true when the call was cancelled: no response is written for it.
    func finished(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        sockets[key] = nil
        return cancelled.remove(key) != nil
    }

    func cancel(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let fd = sockets[key] else { return }
        cancelled.insert(key)
        shutdown(fd, SHUT_RDWR)
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        for fd in sockets.values { shutdown(fd, SHUT_RDWR) }
    }
}

let output = Output()
let calls = Calls()

func handle(_ line: String) {
    switch MCPServer.step(line: line) {
    case .ignore:
        break
    case .reply(let v):
        output.write(v.compact())
    case .cancel(let id):
        calls.cancel(id.compact())
    case .call(let id, let call, let modern):
        let key = id.compact()
        calls.started()
        // On its own thread: the person may take two minutes to answer, and other messages keep coming.
        Thread.detachNewThread {
            defer { calls.ended() }
            let request = LookRequest(requestId: UUID().uuidString.lowercased(), call: call, sessionId: claimedSession,
                                      deadline: Date().addingTimeInterval(LookTiming.helperTimeout))
            let outcome = LookClient.perform(request, socketPath: socketPath) { fd in calls.connected(key, fd) }
            if calls.finished(key) { return }
            output.write(MCPServer.callResult(id: id, outcome: outcome, modern: modern).compact())
        }
    }
}

/// A message longer than this is not one of ours: it is skipped up to its newline and answered with a parse error.
let maxLine = 1 << 20
var buffer = [UInt8]()
var skipping = false
var chunk = [UInt8](repeating: 0, count: 65536)

while true {
    let n = read(STDIN_FILENO, &chunk, chunk.count)
    if n < 0 {
        if errno == EINTR { continue }
        break
    }
    if n == 0 { break }
    buffer.append(contentsOf: chunk[0..<n])
    while let nl = buffer.firstIndex(of: 0x0A) {
        let line = String(decoding: buffer[0..<nl], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeSubrange(0...nl)
        if skipping { skipping = false; continue }
        if !line.isEmpty { handle(line) }
    }
    if buffer.count > maxLine {
        buffer.removeAll()
        if !skipping { output.write(MCPServer.step(line: "").replyText ?? "") }
        skipping = true
    }
}

// Standard input is closed: the client is done. A call that is about to answer (the app is not running, a
// refusal that needs no click) still gets its line out; calls waiting for the person are dropped - the app
// sees their connections close and takes the request cards away.
calls.waitUntilIdle(seconds: 1.5)
calls.cancelAll()
exit(0)

extension MCPServer.Step {
    var replyText: String? {
        if case .reply(let v) = self { return v.compact() }
        return nil
    }
}
