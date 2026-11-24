import Darwin
import Foundation

/// The read-only "look" tools an agent can call through `agenthud-mcp`. Names are part of the tool interface.
public enum LookTool: String, CaseIterable, Sendable {
    case listWindows = "list_windows"
    case screenshot
    case readWindowText = "read_window_text"
}

/// What a look is aimed at. A window is named by the opaque id that `list_windows` printed ("w1234").
public enum LookTarget: Equatable, Sendable {
    case none
    case screen
    case window(UInt32)

    public static let screenWord = "screen"

    public static func windowId(_ number: UInt32) -> String { "w\(number)" }

    /// "w1234" -> 1234. Anything else is not a window id.
    public static func parseWindowId(_ text: String) -> UInt32? {
        guard text.hasPrefix("w"), text.count <= 11 else { return nil }
        let digits = text.dropFirst()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt32(digits)
    }

    var wire: String? {
        switch self {
        case .none: return nil
        case .screen: return Self.screenWord
        case .window(let n): return Self.windowId(n)
        }
    }

    init?(wire: String?) {
        guard let wire else { self = .none; return }
        if wire == Self.screenWord { self = .screen; return }
        guard let n = Self.parseWindowId(wire) else { return nil }
        self = .window(n)
    }
}

/// One validated tool call.
public struct LookCall: Equatable, Sendable {
    public var tool: LookTool
    public var target: LookTarget
    /// Longer side of a screenshot in pixels, already clamped (see `LookImage.maxSide`).
    public var maxSide: Int

    public init(tool: LookTool, target: LookTarget = .none, maxSide: Int = LookImage.defaultMaxSide) {
        self.tool = tool
        self.target = target
        self.maxSide = maxSide
    }
}

/// Message from `agenthud-mcp` to the app: one JSON line on the app's socket, answered by one `LookReply` line.
/// `sessionId` is only what the helper found in its environment - a claim. The app works out the calling process
/// itself from the socket's peer.
public struct LookRequest: Equatable, Sendable {
    public static let version = 1

    public var requestId: String
    public var call: LookCall
    public var sessionId: String?
    public var deadline: Date

    public init(requestId: String, call: LookCall, sessionId: String?, deadline: Date) {
        self.requestId = requestId
        self.call = call
        self.sessionId = sessionId
        self.deadline = deadline
    }

    public func encode() -> String {
        var o = JSONObject()
        o["v"] = .int(Self.version)
        o["look"] = .string(call.tool.rawValue)
        o["request_id"] = .string(requestId)
        if let t = call.target.wire { o["target"] = .string(t) }
        o["max_side"] = .int(call.maxSide)
        if let s = sessionId { o["session_id"] = .string(s) }
        o["deadline"] = .double(deadline.timeIntervalSince1970.rounded())
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> LookRequest? {
        guard let v = try? JSONValue.parse(line),
              let tool = v["look"]?.stringValue.flatMap(LookTool.init(rawValue:)),
              let rid = v["request_id"]?.stringValue, !rid.isEmpty,
              let deadline = v["deadline"]?.doubleValue else { return nil }
        let targetText = v["target"]?.stringValue
        if v["target"] != nil, targetText == nil { return nil }
        guard let target = LookTarget(wire: targetText) else { return nil }
        // The helper has validated the arguments; a request that still does not fit its tool is dropped.
        switch (tool, target) {
        case (.listWindows, .none), (.screenshot, .screen), (.screenshot, .window), (.readWindowText, .window): break
        default: return nil
        }
        let session = v["session_id"]?.stringValue.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 }
        return LookRequest(requestId: rid,
                           call: LookCall(tool: tool, target: target, maxSide: LookImage.maxSide(v["max_side"]?.intValue)),
                           sessionId: session, deadline: Date(timeIntervalSince1970: deadline))
    }
}

/// The app's answer to a look.
public struct LookReply: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case text(String)
        /// `data` is base64; `caption` says what was captured and its size.
        case image(data: String, mimeType: String, caption: String)
        /// Nothing was looked at; the sentence is shown to the agent as the tool's error.
        case refused(String)
    }

    public var requestId: String
    public var outcome: Outcome

    public init(requestId: String, outcome: Outcome) {
        self.requestId = requestId
        self.outcome = outcome
    }

    public func encode() -> String {
        var o = JSONObject()
        o["request_id"] = .string(requestId)
        switch outcome {
        case .text(let t):
            o["look_reply"] = "text"
            o["text"] = .string(t)
        case .image(let data, let mime, let caption):
            o["look_reply"] = "image"
            o["data"] = .string(data)
            o["mime"] = .string(mime)
            o["text"] = .string(caption)
        case .refused(let why):
            o["look_reply"] = "refused"
            o["text"] = .string(why)
        }
        return JSONValue.object(o).compact()
    }

    public static func decode(_ line: String) -> LookReply? {
        guard let v = try? JSONValue.parse(line),
              let rid = v["request_id"]?.stringValue,
              let kind = v["look_reply"]?.stringValue,
              let text = v["text"]?.stringValue else { return nil }
        switch kind {
        case "text": return LookReply(requestId: rid, outcome: .text(text))
        case "refused": return LookReply(requestId: rid, outcome: .refused(text))
        case "image":
            guard let data = v["data"]?.stringValue, !data.isEmpty, let mime = v["mime"]?.stringValue,
                  LookImage.mimeTypes.contains(mime) else { return nil }
            return LookReply(requestId: rid, outcome: .image(data: data, mimeType: mime, caption: text))
        default: return nil
        }
    }
}

public enum LookTiming {
    /// How long a request card waits for a click before the look is refused.
    public static let consentTimeout: TimeInterval = 120
    /// Time for the look itself after consent (a capture, a walk over a large window).
    public static let workAllowance: TimeInterval = 20
    /// The helper stops waiting this long after it sent the request.
    public static var helperTimeout: TimeInterval { consentTimeout + workAllowance }
    public static let connectTimeoutMs: Int32 = 300
    /// Largest reply line the helper accepts (a 2000 px image in base64 is far below this).
    public static let maxReplyBytes = 12 << 20
}

/// The helper's side of one look: send the request, wait for one reply line. Never throws and never waits
/// past the request's deadline; every failure is a `refused` outcome with a plain sentence.
public enum LookClient {
    public static let notRunning = "Agent HUD is not running"
    public static let timedOut = "Timed out waiting for an answer"
    public static let noAnswer = "Agent HUD closed the connection without an answer"
    public static let tooLarge = "The answer from Agent HUD was too large"
    public static let unreadable = "The answer from Agent HUD could not be read"

    /// `onConnected` receives the socket, so that another thread can shut it down to end the wait early.
    public static func perform(_ request: LookRequest, socketPath: String,
                               connectTimeoutMs: Int32 = LookTiming.connectTimeoutMs,
                               maxReplyBytes: Int = LookTiming.maxReplyBytes,
                               onConnected: (Int32) -> Void = { _ in }) -> LookReply.Outcome {
        exchange(line: request.encode(), requestId: request.requestId, deadline: request.deadline, socketPath: socketPath,
                 connectTimeoutMs: connectTimeoutMs, maxReplyBytes: maxReplyBytes, onConnected: onConnected)
    }

    /// One request line out, one reply line back. Shared by the look tools and the act tools.
    static func exchange(line: String, requestId: String, deadline: Date, socketPath: String, connectTimeoutMs: Int32,
                         maxReplyBytes: Int, onConnected: (Int32) -> Void) -> LookReply.Outcome {
        guard let fd = SocketIO.connect(path: socketPath, timeoutMs: connectTimeoutMs) else { return .refused(notRunning) }
        defer { close(fd) }
        onConnected(fd)
        guard SocketIO.writeAll(fd, line) else { return .refused(notRunning) }
        switch readLine(fd, until: deadline, maxBytes: maxReplyBytes) {
        case .timeout: return .refused(timedOut)
        case .closed: return .refused(noAnswer)
        case .tooLarge: return .refused(tooLarge)
        case .line(let line):
            guard let reply = LookReply.decode(line), reply.requestId == requestId else { return .refused(unreadable) }
            return reply.outcome
        }
    }

    enum Line: Equatable { case line(String), timeout, closed, tooLarge }

    static func readLine(_ fd: Int32, until deadline: Date, maxBytes: Int) -> Line {
        var buf = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, max(Int32(min(remaining * 1000, 60_000)), 1))
            if r < 0 { if errno == EINTR { continue } else { return .closed } }
            if r == 0 { continue }
            let n = read(fd, &chunk, chunk.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue } else { return .closed } }
            if n == 0 { return .closed }
            buf.append(contentsOf: chunk[0..<n])
            if let nl = buf.firstIndex(of: 0x0A) {
                return nl > maxBytes ? .tooLarge : .line(String(decoding: buf[0..<nl], as: UTF8.self))
            }
            if buf.count > maxBytes { return .tooLarge }
        }
    }
}
