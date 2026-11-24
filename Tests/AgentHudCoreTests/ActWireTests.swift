import Darwin
import Foundation
import Testing
@testable import AgentHudCore

// The act tools on the wire: their MCP schemas, argument validation, the request line to the app, and the
// helper's exchange with the app.

private func step(_ params: String) -> MCPServer.Step {
    MCPServer.step(line: #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":\#(params)}"#)
}

private func act(_ params: String) -> ActCall? {
    if case .act(_, let call, _) = step(params) { return call }
    return nil
}

private func problem(_ params: String) -> (code: Int?, message: String?) {
    guard case .reply(let v) = step(params) else { return (nil, nil) }
    return (v["error"]?["code"]?.intValue, v["error"]?["message"]?.stringValue)
}

@Suite struct ActToolSchemaTests {
    @Test func tenToolsInAFixedOrder() throws {
        guard case .reply(let r) = MCPServer.step(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#) else {
            Issue.record("no reply")
            return
        }
        let tools = try #require(r["result"]?["tools"]?.arrayValue)
        #expect(tools.compactMap { $0["name"]?.stringValue } == [
            "list_windows", "screenshot", "read_window_text",
            "press_element", "click_at", "type_text", "press_keys", "scroll", "focus_window", "open_app",
        ])
        #expect(MCPServer.actTools.count == ActKind.allCases.count && MCPServer.actTools.count == 7)
        #expect(MCPServer.actTools.compactMap { $0["name"]?.stringValue } == ActKind.allCases.map(\.rawValue))
    }

    @Test func everyActToolHasAClosedSchema() throws {
        for t in MCPServer.actTools {
            let name = try #require(t["name"]?.stringValue)
            let kind = try #require(ActKind(rawValue: name))
            #expect(t["title"]?.stringValue?.isEmpty == false)
            let description = try #require(t["description"]?.stringValue)
            #expect(description.count < 700, "\(name)")
            // Every description says that it works only when switched on and that the person is asked.
            #expect(description.contains("turned agent actions on") && description.contains("asks them first"), "\(name)")
            let schema = try #require(t["inputSchema"])
            #expect(schema["type"]?.stringValue == "object")
            #expect(schema["additionalProperties"] == .bool(false))
            // The schema names exactly the arguments the parser accepts.
            let properties = try #require(schema["properties"]?.objectValue)
            #expect(Set(properties.keys) == ActCall.argumentNames[kind], "\(name)")
            for required in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(properties.keys.contains(required), "\(name).\(required)")
            }
            // None of them is read-only.
            #expect(t["annotations"]?["readOnlyHint"] == .bool(false))
        }
    }

    @Test func schemasOfTheSevenTools() {
        func schema(_ kind: ActKind) -> JSONValue? {
            MCPServer.actTools.first { $0["name"]?.stringValue == kind.rawValue }?["inputSchema"]
        }
        #expect(schema(.pressElement)?["required"] == ["window", "element"])
        #expect(schema(.clickAt)?["required"] == ["window", "x", "y"])
        #expect(schema(.clickAt)?["properties"]?["button"]?["enum"] == ["left", "right"])
        #expect(schema(.clickAt)?["properties"]?["count"]?["enum"] == [1, 2])
        #expect(schema(.clickAt)?["properties"]?["x"]?["type"]?.stringValue == "number")
        #expect(schema(.typeText)?["required"] == ["window", "text"])
        #expect(schema(.typeText)?["properties"]?["text"]?["maxLength"]?.intValue == 2000)
        #expect(schema(.pressKeys)?["required"] == ["window", "keys"])
        #expect(schema(.scroll)?["required"] == ["window"])
        #expect(schema(.scroll)?["properties"]?["dy"]?["minimum"]?.intValue == -50)
        #expect(schema(.scroll)?["properties"]?["dy"]?["maximum"]?.intValue == 50)
        #expect(schema(.scroll)?["properties"]?["dx"]?["type"]?.stringValue == "integer")
        #expect(schema(.focusWindow)?["required"] == ["window"])
        // open_app takes one of two arguments, so neither is required by the schema.
        #expect(schema(.openApp)?["required"] == nil)
        #expect(schema(.openApp)?["properties"]?["bundle_id"] != nil && schema(.openApp)?["properties"]?["name"] != nil)
    }

    @Test func descriptionsSayWhatMatters() {
        func description(_ kind: ActKind) -> String {
            MCPServer.actTools.first { $0["name"]?.stringValue == kind.rawValue }?["description"]?.stringValue ?? ""
        }
        #expect(description(.pressElement).contains("read_window_text"))
        #expect(description(.clickAt).contains("top-left"))
        #expect(description(.typeText).contains("2000") && description(.typeText).contains("Return") && description(.typeText).contains("password"))
        // The key names are documented where the agent reads them.
        #expect(description(.pressKeys).contains(KeyCombo.keyNamesHelp) && description(.pressKeys).contains("cmd, shift, option, control"))
        #expect(description(.scroll).contains("50"))
        // The tools that can change or send something are marked; the three that cannot are not.
        func destructive(_ kind: ActKind) -> JSONValue? {
            MCPServer.actTools.first { $0["name"]?.stringValue == kind.rawValue }?["annotations"]?["destructiveHint"]
        }
        for kind in [ActKind.pressElement, .clickAt, .typeText, .pressKeys] { #expect(destructive(kind) == .bool(true)) }
        for kind in [ActKind.scroll, .focusWindow, .openApp] { #expect(destructive(kind) == .bool(false)) }
        // Nothing beyond the seven: no drag, no files, no shell.
        let names = Set(MCPServer.tools.compactMap { $0["name"]?.stringValue })
        for absent in ["drag", "move_file", "delete_file", "run_command", "shell", "write_file"] { #expect(!names.contains(absent)) }
        #expect(MCPServer.instructions.contains("consent"))
    }
}

@Suite struct ActArgumentTests {
    @Test func validCalls() {
        #expect(act(#"{"name":"press_element","arguments":{"window":"w11","element":"e12"}}"#)
                == ActCall(window: 11, body: .pressElement(element: 12)))
        #expect(act(#"{"name":"click_at","arguments":{"window":"w11","x":120,"y":48.5}}"#)
                == ActCall(window: 11, body: .clickAt(x: 120, y: 48.5, button: .left, count: 1)))
        #expect(act(#"{"name":"click_at","arguments":{"window":"w11","x":0,"y":0,"button":"right","count":2}}"#)
                == ActCall(window: 11, body: .clickAt(x: 0, y: 0, button: .right, count: 2)))
        #expect(act(#"{"name":"click_at","arguments":{"window":"w11","x":1,"y":2,"button":null,"count":null}}"#)
                == ActCall(window: 11, body: .clickAt(x: 1, y: 2, button: .left, count: 1)))
        #expect(act(#"{"name":"type_text","arguments":{"window":"w11","text":"milk\neggs\tx2"}}"#)
                == ActCall(window: 11, body: .typeText("milk\neggs\tx2")))
        #expect(act(#"{"name":"type_text","arguments":{"window":"w11","text":"a\r\nb"}}"#) == ActCall(window: 11, body: .typeText("a\nb")))
        #expect(act(#"{"name":"press_keys","arguments":{"window":"w11","keys":"Cmd+S"}}"#)
                == ActCall(window: 11, body: .pressKeys(KeyCombo(modifiers: .cmd, key: "s"))))
        #expect(act(#"{"name":"scroll","arguments":{"window":"w11","dy":5}}"#) == ActCall(window: 11, body: .scroll(dx: 0, dy: 5)))
        #expect(act(#"{"name":"scroll","arguments":{"window":"w11","dx":-3,"dy":0}}"#) == ActCall(window: 11, body: .scroll(dx: -3, dy: 0)))
        #expect(act(#"{"name":"focus_window","arguments":{"window":"w11"}}"#) == ActCall(window: 11, body: .focusWindow))
        #expect(act(#"{"name":"open_app","arguments":{"bundle_id":"com.apple.Notes"}}"#)
                == ActCall(window: nil, body: .openApp(.bundleId("com.apple.Notes"))))
        #expect(act(#"{"name":"open_app","arguments":{"name":"Visual Studio Code"}}"#)
                == ActCall(window: nil, body: .openApp(.name("Visual Studio Code"))))
    }

    @Test func scrollIsCapped() {
        #expect(act(#"{"name":"scroll","arguments":{"window":"w1","dy":500}}"#) == ActCall(window: 1, body: .scroll(dx: 0, dy: 50)))
        #expect(act(#"{"name":"scroll","arguments":{"window":"w1","dx":-999,"dy":51}}"#) == ActCall(window: 1, body: .scroll(dx: -50, dy: 50)))
        #expect(act(#"{"name":"scroll","arguments":{"window":"w1","dy":-50}}"#) == ActCall(window: 1, body: .scroll(dx: 0, dy: -50)))
        #expect(ActCall.scrollCap == 50)
    }

    @Test func theKindOfACall() {
        #expect(ActCall(window: 1, body: .pressElement(element: 1)).kind == .pressElement)
        #expect(ActCall(window: 1, body: .typeText("x")).kind == .typeText)
        #expect(ActCall(window: nil, body: .openApp(.name("Notes"))).kind == .openApp)
        #expect(ActKind.allCases.map(\.rawValue) == ["press_element", "click_at", "type_text", "press_keys", "scroll", "focus_window", "open_app"])
    }

    @Test func malformedArgumentsAreProtocolErrors() {
        let bad = [
            // The window
            #"{"name":"press_element"}"#, #"{"name":"press_element","arguments":{}}"#,
            #"{"name":"press_element","arguments":{"window":"screen","element":"e1"}}"#,
            #"{"name":"press_element","arguments":{"window":12,"element":"e1"}}"#,
            #"{"name":"focus_window","arguments":{"window":"w"}}"#, #"{"name":"focus_window","arguments":{"window":null}}"#,
            #"{"name":"focus_window","arguments":[]}"#, #"{"name":"focus_window","arguments":"w1"}"#,
            // The element
            #"{"name":"press_element","arguments":{"window":"w1"}}"#, #"{"name":"press_element","arguments":{"window":"w1","element":"12"}}"#,
            #"{"name":"press_element","arguments":{"window":"w1","element":12}}"#, #"{"name":"press_element","arguments":{"window":"w1","element":"e0"}}"#,
            #"{"name":"press_element","arguments":{"window":"w1","element":"Send"}}"#,
            // The point
            #"{"name":"click_at","arguments":{"window":"w1"}}"#, #"{"name":"click_at","arguments":{"window":"w1","x":5}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":"5","y":5}}"#, #"{"name":"click_at","arguments":{"window":"w1","x":-1,"y":5}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":1e9}}"#, #"{"name":"click_at","arguments":{"window":"w1","x":true,"y":5}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"button":"middle"}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"button":1}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"count":3}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"count":0}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"count":1.5}}"#,
            #"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"count":"2"}}"#,
            // The text
            #"{"name":"type_text","arguments":{"window":"w1"}}"#, #"{"name":"type_text","arguments":{"window":"w1","text":""}}"#,
            #"{"name":"type_text","arguments":{"window":"w1","text":7}}"#, #"{"name":"type_text","arguments":{"window":"w1","text":"a\u001bb"}}"#,
            #"{"name":"type_text","arguments":{"window":"w1","text":"a\u0000b"}}"#, #"{"name":"type_text","arguments":{"text":"hello"}}"#,
            "{\"name\":\"type_text\",\"arguments\":{\"window\":\"w1\",\"text\":\"\(String(repeating: "x", count: 2001))\"}}",
            // The keys
            #"{"name":"press_keys","arguments":{"window":"w1"}}"#, #"{"name":"press_keys","arguments":{"window":"w1","keys":""}}"#,
            #"{"name":"press_keys","arguments":{"window":"w1","keys":"cmd"}}"#, #"{"name":"press_keys","arguments":{"window":"w1","keys":"cmd+enter"}}"#,
            #"{"name":"press_keys","arguments":{"window":"w1","keys":"cmd+cmd+s"}}"#, #"{"name":"press_keys","arguments":{"window":"w1","keys":"a+b"}}"#,
            #"{"name":"press_keys","arguments":{"window":"w1","keys":["cmd","s"]}}"#,
            // The scroll
            #"{"name":"scroll","arguments":{"window":"w1"}}"#, #"{"name":"scroll","arguments":{"window":"w1","dx":0,"dy":0}}"#,
            #"{"name":"scroll","arguments":{"window":"w1","dy":1.5}}"#, #"{"name":"scroll","arguments":{"window":"w1","dy":"3"}}"#,
            #"{"name":"scroll","arguments":{"dy":3}}"#,
            // The app
            #"{"name":"open_app"}"#, #"{"name":"open_app","arguments":{}}"#,
            #"{"name":"open_app","arguments":{"bundle_id":"com.apple.Notes","name":"Notes"}}"#,
            #"{"name":"open_app","arguments":{"bundle_id":"Notes"}}"#, #"{"name":"open_app","arguments":{"bundle_id":"../evil.app"}}"#,
            #"{"name":"open_app","arguments":{"bundle_id":7}}"#, #"{"name":"open_app","arguments":{"name":""}}"#,
            #"{"name":"open_app","arguments":{"name":"/Applications/Notes.app"}}"#, #"{"name":"open_app","arguments":{"name":"../Notes"}}"#,
            #"{"name":"open_app","arguments":{"name":".hidden"}}"#, #"{"name":"open_app","arguments":{"name":" Notes "}}"#,
            #"{"name":"open_app","arguments":{"name":"a\nb"}}"#, #"{"name":"open_app","arguments":{"window":"w1"}}"#,
            // Arguments the tool does not have
            #"{"name":"focus_window","arguments":{"window":"w1","raise":true}}"#,
            #"{"name":"type_text","arguments":{"window":"w1","text":"x","submit":true}}"#,
            #"{"name":"press_element","arguments":{"window":"w1","element":"e1","x":4}}"#,
            #"{"name":"open_app","arguments":{"name":"Notes","args":["--evil"]}}"#,
        ]
        for params in bad {
            let (code, message) = problem(params)
            #expect(code == -32602, "\(params.prefix(120))")
            #expect(message?.isEmpty == false)
            #expect(act(params) == nil)
        }
    }

    @Test func errorsSayWhatIsWrong() {
        #expect(problem(#"{"name":"type_text","arguments":{"text":"hello"}}"#).message == "type_text needs window: a window id from list_windows")
        #expect(problem(#"{"name":"press_element","arguments":{"window":"w1","element":"Send"}}"#).message?.contains("read_window_text") == true)
        #expect(problem(#"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"count":3}}"#).message == "count must be 1 or 2")
        #expect(problem(#"{"name":"click_at","arguments":{"window":"w1","x":5,"y":5,"button":"middle"}}"#).message == "button must be \"left\" or \"right\"")
        #expect(problem(#"{"name":"open_app","arguments":{}}"#).message == "open_app needs exactly one of bundle_id and name")
        #expect(problem(#"{"name":"focus_window","arguments":{"window":"w1","raise":true}}"#).message == "focus_window has no argument \"raise\"")
        #expect(problem(#"{"name":"press_keys","arguments":{"window":"w1","keys":"cmd+enter"}}"#).message?.hasPrefix("Unknown key") == true)
        #expect(problem(#"{"name":"scroll","arguments":{"window":"w1"}}"#).message?.contains("not zero") == true)
        // A tool that does not exist stays unknown.
        #expect(problem(#"{"name":"drag","arguments":{}}"#).message == "Unknown tool: drag")
        #expect(problem(#"{"name":"Type_Text","arguments":{"window":"w1","text":"x"}}"#).message == "Unknown tool: Type_Text")
    }

    @Test func aNotificationIsNotACall() {
        // Without an id nothing is performed.
        #expect(MCPServer.step(line: #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"type_text","arguments":{"window":"w1","text":"x"}}}"#) == .ignore)
    }
}

@Suite struct ActWireTests {
    let deadline = Date(timeIntervalSince1970: 1_800_000_140)

    private var samples: [ActCall] {
        [
            ActCall(window: 11, body: .pressElement(element: 12)),
            ActCall(window: 11, body: .clickAt(x: 120, y: 48.5, button: .right, count: 2)),
            ActCall(window: 11, body: .typeText("milk\neggs\tx2 — \"quoted\" \\ 👍🏽")),
            ActCall(window: 11, body: .pressKeys(KeyCombo(modifiers: [.cmd, .shift], key: "z"))),
            ActCall(window: 11, body: .pressKeys(KeyCombo(key: "\\"))),
            ActCall(window: 11, body: .scroll(dx: -3, dy: 50)),
            ActCall(window: 4_294_967_295, body: .focusWindow),
            ActCall(window: nil, body: .openApp(.bundleId("com.apple.Notes"))),
            ActCall(window: nil, body: .openApp(.name("Visual Studio Code"))),
        ]
    }

    @Test func requestRoundTrip() {
        for (i, call) in samples.enumerated() {
            let request = ActRequest(requestId: "r\(i)", call: call, sessionId: i % 2 == 0 ? "0f8fad5b" : nil, deadline: deadline)
            let line = request.encode()
            #expect(!line.contains("\n"))
            #expect(ActRequest.decode(line) == request, "\(call)")
            // An action is not a look and not a hook message, and the other way round.
            #expect(LookRequest.decode(line) == nil)
            #expect(HookMessage.decode(line) == nil)
        }
        let look = LookRequest(requestId: "r", call: LookCall(tool: .readWindowText, target: .window(5)), sessionId: nil, deadline: deadline).encode()
        #expect(ActRequest.decode(look) == nil)
    }

    @Test func theAppValidatesAgain() {
        func line(_ kind: String, _ args: String) -> String {
            "{\"v\":1,\"act\":\"\(kind)\",\"request_id\":\"r\",\"args\":\(args),\"deadline\":1800000140}"
        }
        #expect(ActRequest.decode(line("focus_window", #"{"window":"w7"}"#))?.call == ActCall(window: 7, body: .focusWindow))
        // What the helper should have refused is dropped by the app as well.
        let bad = [
            line("focus_window", "{}"), line("focus_window", #"{"window":"screen"}"#), line("drag", #"{"window":"w7"}"#),
            line("type_text", #"{"window":"w7","text":"a\u001bb"}"#), line("type_text", #"{"window":"w7","text":""}"#),
            line("type_text", "{\"window\":\"w7\",\"text\":\"\(String(repeating: "x", count: 2001))\"}"),
            line("press_keys", #"{"window":"w7","keys":"cmd+enter"}"#), line("press_element", #"{"window":"w7","element":"e0"}"#),
            line("click_at", #"{"window":"w7","x":-5,"y":1}"#), line("open_app", #"{"name":"../x"}"#),
            line("open_app", #"{"bundle_id":"com.apple.Notes","name":"Notes"}"#), line("focus_window", #"{"window":"w7","extra":1}"#),
            line("focus_window", #""w7""#),
        ]
        for l in bad { #expect(ActRequest.decode(l) == nil, "\(l.prefix(100))") }
        // The scroll amount is capped again on arrival.
        #expect(ActRequest.decode(line("scroll", #"{"window":"w7","dy":900}"#))?.call == ActCall(window: 7, body: .scroll(dx: 0, dy: 50)))
        #expect(ActRequest.decode(#"{"act":"focus_window","request_id":"","args":{"window":"w7"},"deadline":1}"#) == nil)
        #expect(ActRequest.decode(#"{"act":"focus_window","request_id":"r","args":{"window":"w7"}}"#) == nil)
        #expect(ActRequest.decode(#"{"act":"focus_window","request_id":"r","deadline":1}"#) == nil)
        #expect(ActRequest.decode("not json") == nil)
    }

    @Test func argumentsReadBackToTheSameCall() {
        for call in samples {
            guard case .success(let back) = ActCall.parse(kind: call.kind, arguments: call.arguments) else {
                Issue.record("\(call)")
                continue
            }
            #expect(back == call)
        }
    }
}

/// A stand-in for the app: listens on a socket, reads one request line and answers what the test says.
private final class FakeActApp: @unchecked Sendable {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ line: String) { lock.lock(); list.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// Set before the listener is woken, so its thread never calls `accept` on a descriptor number that was
    /// closed here and handed to another socket meanwhile (tests run in parallel).
    private final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        func set() { lock.lock(); on = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return on }
    }
    private let stop = Stop()

    let path: String
    private let listenFD: Int32
    private let seen = Seen()

    var lines: [String] { seen.all }

    init(respond: @escaping @Sendable (ActRequest) -> [String]) throws {
        path = NSTemporaryDirectory() + "aha-\(UUID().uuidString.prefix(8)).sock"
        var addr = try #require(SocketIO.makeAddress(path))
        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0 && listen(listenFD, 4) == 0)
        let fd = listenFD, seen = seen, stop = stop, socketPath = path
        // The thread ends when deinit sets the flag and wakes it; it holds no reference to this object.
        Thread.detachNewThread {
            // The thread owns the listening socket and is the only one that closes it.
            defer { close(fd); unlink(socketPath) }
            while !stop.isSet {
                let c = accept(fd, nil, nil)
                if c < 0 { return }
                if stop.isSet { close(c); return }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if let line = SocketIO.readLine(c, until: Date().addingTimeInterval(5)) {
                    seen.add(line)
                    if let request = ActRequest.decode(line) {
                        for l in respond(request) { SocketIO.writeAll(c, l) }
                    }
                }
                close(c)
            }
        }
    }

    deinit {
        // Wake the listener with one last connection; it sees the flag, closes the socket and removes the file.
        stop.set()
        if let wake = SocketIO.connect(path: path, timeoutMs: 200) { close(wake) }
    }
}

@Suite struct ActClientTests {
    private let typing = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"type_text","arguments":{"window":"w42","text":"hello\nworld"}}}"#

    /// One line through the MCP layer and the socket, as the helper does it.
    private func call(_ line: String, socketPath: String) throws -> JSONValue {
        let out = try #require(MCPServer.handle(line: line, call: { _ in .refused("not a look") }, act: { call in
            ActClient.perform(ActRequest(requestId: UUID().uuidString.lowercased(), call: call, sessionId: "0f8fad5b",
                                         deadline: Date().addingTimeInterval(5)), socketPath: socketPath)
        }))
        #expect(!out.contains("\n"))
        return try JSONValue.parse(out)
    }

    @Test func allowed() throws {
        let done = "Typed 11 characters into Notes — Shopping"
        let app = try FakeActApp { r in [LookReply(requestId: r.requestId, outcome: .text(done)).encode()] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        let v = try call(typing, socketPath: app.path)
        #expect(v["error"] == nil && v["id"] == .number("1"))
        #expect(v["result"]?["isError"] == .bool(false))
        #expect(v["result"]?["content"] == [["type": "text", "text": .string(done)]])
        // The app got exactly this call, with the session the helper claims.
        #expect(app.lines.count == 1)
        let seen = try #require(app.lines.first.flatMap(ActRequest.decode))
        #expect(seen.call == ActCall(window: 42, body: .typeText("hello\nworld")))
        #expect(seen.sessionId == "0f8fad5b")
    }

    @Test func denied() throws {
        let app = try FakeActApp { r in [LookReply(requestId: r.requestId, outcome: .refused(ActGate.Refusal.denied.message)).encode()] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        let v = try call(typing, socketPath: app.path)
        #expect(v["error"] == nil)
        #expect(v["result"]?["isError"] == .bool(true))
        #expect(v["result"]?["content"]?[0]?["text"]?.stringValue == "The person did not allow this")
    }

    @Test func appAbsent() throws {
        let missing = NSTemporaryDirectory() + "aha-none-\(UUID().uuidString.prefix(8)).sock"
        let started = Date()
        let v = try call(typing, socketPath: missing)
        #expect(Date().timeIntervalSince(started) < 2)
        // A normal result marked as an error, not a protocol error.
        #expect(v["error"] == nil)
        #expect(v["result"]?["isError"] == .bool(true))
        #expect(v["result"]?["content"]?[0]?["text"]?.stringValue == "Agent HUD is not running")
        let request = ActRequest(requestId: "r", call: ActCall(window: 1, body: .focusWindow), sessionId: nil, deadline: Date().addingTimeInterval(2))
        #expect(ActClient.perform(request, socketPath: "/dev/null") == .refused(LookClient.notRunning))
    }

    @Test func answersThatAreNotForThisCall() throws {
        let request = { ActRequest(requestId: UUID().uuidString.lowercased(), call: ActCall(window: 1, body: .focusWindow), sessionId: nil,
                                   deadline: Date().addingTimeInterval(5)) }
        let closing = try FakeActApp { _ in [] }
        defer { withExtendedLifetime(closing) {} }   // the listener closes when the fake is released
        #expect(ActClient.perform(request(), socketPath: closing.path) == .refused(LookClient.noAnswer))
        let other = try FakeActApp { _ in [LookReply(requestId: "someone-else", outcome: .text("Pressed")).encode()] }
        defer { withExtendedLifetime(other) {} }   // the listener closes when the fake is released
        #expect(ActClient.perform(request(), socketPath: other.path) == .refused(LookClient.unreadable))
        // A hook's "allow" is not an answer to an action, and neither is a picture.
        let hook = try FakeActApp { r in [HookReply(requestId: r.requestId, decision: .allow).encode()] }
        defer { withExtendedLifetime(hook) {} }   // the listener closes when the fake is released
        #expect(ActClient.perform(request(), socketPath: hook.path) == .refused(LookClient.unreadable))
        let picture = try FakeActApp { r in [LookReply(requestId: r.requestId, outcome: .image(data: "QUJD", mimeType: "image/png", caption: "x")).encode()] }
        defer { withExtendedLifetime(picture) {} }   // the listener closes when the fake is released
        #expect(ActClient.perform(request(), socketPath: picture.path) == .refused(LookClient.unreadable))
    }

    @Test func aCallThatIsNotAnswered() throws {
        let app = try FakeActApp { _ in [] }
        defer { withExtendedLifetime(app) {} }   // the listener closes when the fake is released
        // A deadline that has already passed returns at once.
        let late = ActRequest(requestId: "r", call: ActCall(window: 1, body: .focusWindow), sessionId: nil, deadline: Date().addingTimeInterval(-1))
        let started = Date()
        #expect(ActClient.perform(late, socketPath: app.path) == .refused(LookClient.timedOut))
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
