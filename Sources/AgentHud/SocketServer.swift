import AgentHudCore
import Darwin
import Foundation

/// Unix socket that `agenthud-hook` sends events to and `agenthud-mcp` sends look requests to.
/// All descriptor work runs on its own queue; callbacks run on the main thread.
final class SocketServer {
    enum StartError: Error, CustomStringConvertible {
        case alreadyRunning
        case system(String)

        var description: String {
            switch self {
            case .alreadyRunning: return "Agent HUD is already running."
            case .system(let s): return s
            }
        }
    }

    private final class Connection {
        let fd: Int32
        var buffer = [UInt8]()
        var source: DispatchSourceRead?
        var requestId: String?
        var gotMessage = false
        var replied = false
        init(fd: Int32) { self.fd = fd }
    }

    let path: String
    private let queue = DispatchQueue(label: "agenthud.socket")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var byRequest: [String: Connection] = [:]

    /// A message arrived from the hook.
    var onMessage: ((HookMessage) -> Void)?
    /// The hook disconnected without waiting for a reply (answered in the terminal, or timed out).
    var onClosed: ((String) -> Void)?
    /// A look request arrived from `agenthud-mcp`; the second value is the process on the other end of the connection.
    var onLook: ((LookRequest, Int32?) -> Void)?

    init(path: String) { self.path = path }

    func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: path) {
            if let fd = SocketIO.connect(path: path, timeoutMs: 200) {
                close(fd)
                throw StartError.alreadyRunning
            }
            unlink(path)
        }
        guard var addr = SocketIO.makeAddress(path) else { throw StartError.system("Socket path is too long: \(path)") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket(): \(errno)") }
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard rc == 0 else { close(fd); throw StartError.system("bind(): \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { close(fd); throw StartError.system("listen(): \(errno)") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd

        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        acceptSource = src
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            for c in connections.values { c.source?.cancel() }
            connections.removeAll()
            byRequest.removeAll()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            unlink(path)
        }
    }

    /// Reply to the hook and close the connection. Does nothing if the hook has already gone.
    func reply(_ reply: HookReply) {
        queue.async { [weak self] in
            guard let self, let c = self.byRequest[reply.requestId], !c.replied else { return }
            c.replied = true
            SocketIO.writeAll(c.fd, reply.encode())
            self.drop(c)
        }
    }

    /// Answer a look request and close the connection. Does nothing if the helper has already gone.
    func replyLook(_ reply: LookReply) {
        queue.async { [weak self] in
            guard let self, let c = self.byRequest[reply.requestId], !c.replied else { return }
            c.replied = true
            SocketIO.writeAll(c.fd, reply.encode())
            self.drop(c)
        }
    }

    /// Tell a waiting gate hook that its call is held (or that the hold changed). The connection stays open.
    func notifyHeld(_ notice: HoldNotice) {
        queue.async { [weak self] in
            guard let self, let c = self.byRequest[notice.requestId], !c.replied else { return }
            // The hook has gone if the write fails; its close is reported through `onClosed` as usual.
            SocketIO.writeAll(c.fd, notice.encode())
        }
    }

    // MARK: - Internals

    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let c = Connection(fd: fd)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            src.setEventHandler { [weak self, weak c] in
                guard let self, let c else { return }
                self.readable(c)
            }
            src.setCancelHandler { close(fd) }
            c.source = src
            connections[ObjectIdentifier(c)] = c
            src.resume()
        }
    }

    private func readable(_ c: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c.fd, &chunk, chunk.count)
            if n > 0 {
                if !c.gotMessage {
                    c.buffer.append(contentsOf: chunk[0..<n])
                    if c.buffer.count > 8 << 20 { drop(c); return }
                    if let nl = c.buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: c.buffer[0..<nl], as: UTF8.self)
                        c.buffer.removeAll()
                        c.gotMessage = true
                        handleLine(line, c)
                        if c.source == nil { return }
                    }
                }
                continue
            }
            if n == 0 {
                // The hook closed the connection.
                if let rid = c.requestId, !c.replied {
                    DispatchQueue.main.async { [weak self] in self?.onClosed?(rid) }
                }
                drop(c)
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN { return }
            drop(c)
            return
        }
    }

    /// The process that connected, as the kernel reports it - not something the peer can choose.
    private static func peerPid(_ fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, pid > 0 else { return nil }
        return pid
    }

    private func handleLine(_ line: String, _ c: Connection) {
        if let look = LookRequest.decode(line) {
            // An id that is already waiting belongs to another connection; a second one cannot take its reply.
            guard byRequest[look.requestId] == nil else { drop(c); return }
            // Always answered, so the connection stays until the reply (or until the helper leaves).
            c.requestId = look.requestId
            byRequest[look.requestId] = c
            let peer = Self.peerPid(c.fd)
            DispatchQueue.main.async { [weak self] in self?.onLook?(look, peer) }
            return
        }
        guard let msg = HookMessage.decode(line) else { drop(c); return }
        if msg.mode.isSync {
            c.requestId = msg.requestId
            byRequest[msg.requestId] = c
        }
        DispatchQueue.main.async { [weak self] in self?.onMessage?(msg) }
        if !msg.mode.isSync { drop(c) }
    }

    private func drop(_ c: Connection) {
        c.source?.cancel()
        c.source = nil
        connections[ObjectIdentifier(c)] = nil
        if let rid = c.requestId { byRequest[rid] = nil }
    }
}
