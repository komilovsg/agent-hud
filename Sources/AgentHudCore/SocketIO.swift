import Darwin
import Foundation

/// Низкоуровневые операции с unix-сокетом: общие для хука и приложения.
public enum SocketIO {
    public static func makeAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    /// Подключиться с таймаутом. nil — приложение не запущено.
    public static func connect(path: String, timeoutMs: Int32) -> Int32? {
        guard var addr = makeAddress(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { close(fd); return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, timeoutMs) == 1 else { close(fd); return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); return nil }
        }
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        return fd
    }

    /// Записать всё. false — соединение порвано.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ text: String) -> Bool {
        var data = Array(text.utf8)
        if data.last != 0x0A { data.append(0x0A) }
        var off = 0
        while off < data.count {
            let n = data[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pfd, 1, 1000)
                    continue
                }
                return false
            }
            off += n
        }
        return true
    }

    /// Прочитать одну строку до `deadline`. nil — таймаут или соединение закрыто.
    public static func readLine(_ fd: Int32, until deadline: Date, maxBytes: Int = 4 << 20) -> String? {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ms = Int32(min(remaining * 1000, 60_000))
            let r = poll(&pfd, 1, max(ms, 1))
            if r < 0 { if errno == EINTR { continue } else { return nil } }
            if r == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue } else { return nil } }
            if n == 0 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            if let nl = buf.firstIndex(of: 0x0A) {
                return String(decoding: buf[0..<nl], as: UTF8.self)
            }
            if buf.count > maxBytes { return nil }
        }
    }
}
