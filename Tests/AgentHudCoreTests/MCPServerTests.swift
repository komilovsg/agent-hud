import Foundation
import Testing
@testable import AgentHudCore

// The MCP side of the screen tools helper: one JSON-RPC message in, one decision out.

private func step(_ json: String) -> MCPServer.Step { MCPServer.step(line: json) }

private func reply(_ json: String) -> JSONValue? {
    if case .reply(let v) = step(json) { return v }
    return nil
}

private func errorCode(_ json: String) -> Int? { reply(json)?["error"]?["code"]?.intValue }

/// `_meta` of a request of the handshake-free revision.
private func meta(_ version: String = MCPServer.modernVersion, capabilities: Bool = true) -> String {
    var s = "\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"\(version)\""
    if capabilities { s += ",\"io.modelcontextprotocol/clientCapabilities\":{}" }
    return s + "}"
}

@Suite struct MCPHandshakeTests {
    @Test func initializeAnswersWithTheAskedVersionWhenItIsKnown() throws {
        for version in MCPServer.legacyVersions {
            let r = try #require(reply(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#))
            #expect(r["jsonrpc"]?.stringValue == "2.0")
            #expect(r["id"] == .number("1"))
            let result = try #require(r["result"])
            #expect(result["protocolVersion"]?.stringValue == version)
            #expect(result["capabilities"]?["tools"]?.objectValue != nil)
            #expect(result["serverInfo"]?["name"]?.stringValue == "agenthud")
            #expect(result["serverInfo"]?["version"]?.stringValue?.isEmpty == false)
            // Fields of the newer revision are not sent to a handshake-era client.
            #expect(result["resultType"] == nil && result["_meta"] == nil)
        }
    }

    @Test func initializeFallsBackToTheNewestHandshakeVersion() throws {
        for asked in ["1999-01-01", "2030-01-01", MCPServer.modernVersion, ""] {
            let r = try #require(reply(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"\#(asked)"}}"#))
            #expect(r["result"]?["protocolVersion"]?.stringValue == "2025-11-25")
            #expect(r["id"] == .string("a"))
        }
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#) == -32602)
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#) == -32602)
    }

    @Test func notificationsAndResponsesGetNoAnswer() {
        #expect(step(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == .ignore)
        #expect(step(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}"#) == .ignore)
        #expect(step(#"{"jsonrpc":"2.0","method":"no/such/notification"}"#) == .ignore)
        #expect(step(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"screenshot"}}"#) == .ignore)
        #expect(step(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == .ignore)
        #expect(step(#"{"jsonrpc":"2.0","id":7,"error":{"code":1,"message":"x"}}"#) == .ignore)
    }

    @Test func cancellationNamesTheRequest() {
        #expect(step(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5,"reason":"x"}}"#) == .cancel(id: .number("5")))
        #expect(step(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"r"}}"#) == .cancel(id: .string("r")))
        #expect(step(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#) == .ignore)
    }

    @Test func ping() throws {
        let old = try #require(reply(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#))
        #expect(old["result"] == .object(JSONObject()))
        let new = try #require(reply(#"{"jsonrpc":"2.0","id":2,"method":"ping","params":{\#(meta())}}"#))
        #expect(new["result"]?["resultType"]?.stringValue == "complete")
    }

    @Test func discoverDescribesTheServer() throws {
        let r = try #require(reply(#"{"jsonrpc":"2.0","id":"d","method":"server/discover","params":{\#(meta())}}"#))
        let result = try #require(r["result"])
        #expect(result["resultType"]?.stringValue == "complete")
        #expect(result["supportedVersions"]?.arrayValue?.compactMap(\.stringValue) == MCPServer.supportedVersions)
        #expect(MCPServer.supportedVersions.first == "2026-07-28")
        #expect(result["capabilities"]?["tools"]?.objectValue != nil)
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["name"]?.stringValue == "agenthud")
        // Without the per-request fields the request is malformed.
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"server/discover"}"#) == -32602)
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{}}"#) == -32602)
    }

    @Test func aRequestOfAnUnknownRevisionIsToldWhichOnesWork() throws {
        for method in ["server/discover", "tools/list", "tools/call", "ping"] {
            let r = try #require(reply(#"{"jsonrpc":"2.0","id":1,"method":"\#(method)","params":{\#(meta("2031-01-01"))}}"#))
            #expect(r["error"]?["code"]?.intValue == -32022)
            #expect(r["error"]?["data"]?["requested"]?.stringValue == "2031-01-01")
            #expect(r["error"]?["data"]?["supported"]?.arrayValue?.compactMap(\.stringValue) == MCPServer.supportedVersions)
            #expect(r["id"] == .number("1"))
        }
        // The version field must be a string.
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":7}}}"#) == -32022)
        // A request of the new revision without its capabilities field is malformed.
        #expect(errorCode(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta(capabilities: false))}}"#) == -32602)
    }
}

@Suite struct MCPToolTests {
    @Test func toolListSchema() throws {
        let r = try #require(reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#))
        let all = try #require(r["result"]?["tools"]?.arrayValue)
        // The look tools come first; the tools that act and then the memory tools follow them (see ActWireTests).
        #expect(all.count == LookTool.allCases.count + ActKind.allCases.count + MemoryTool.allCases.count)
        let tools = Array(all.prefix(LookTool.allCases.count))
        #expect(tools == MCPServer.lookTools)
        #expect(tools.compactMap { $0["name"]?.stringValue } == ["list_windows", "screenshot", "read_window_text"])
        for t in tools {
            #expect(t["description"]?.stringValue?.isEmpty == false)
            #expect((t["description"]?.stringValue?.count ?? 999) < 520)
            #expect(t["inputSchema"]?["type"]?.stringValue == "object")
            #expect(t["inputSchema"]?["properties"]?.objectValue != nil)
            #expect(t["inputSchema"]?["additionalProperties"] == .bool(false))
            #expect(t["annotations"]?["readOnlyHint"] == .bool(true))
            #expect(t["annotations"]?["destructiveHint"] == .bool(false))
        }
        #expect(tools[0]["inputSchema"]?["required"] == nil)
        #expect(tools[1]["inputSchema"]?["required"] == ["target"])
        #expect(tools[1]["inputSchema"]?["properties"]?["max_side"]?["maximum"]?.intValue == 2000)
        #expect(tools[1]["inputSchema"]?["properties"]?["target"]?["type"]?.stringValue == "string")
        #expect(tools[2]["inputSchema"]?["required"] == ["window"])
        // The same list for the new revision, marked as complete.
        let modern = try #require(reply(#"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{\#(meta())}}"#))
        #expect(modern["result"]?["resultType"]?.stringValue == "complete")
        #expect(modern["result"]?["tools"]?.arrayValue == all)
    }

    @Test func noLookToolActs() {
        // The look tools are read-only by construction: none offers to click, type, move or change anything.
        // (The one mention of pressing is the reference that read_window_text prints for press_element.)
        let text = JSONValue.array(MCPServer.lookTools).compact().lowercased().replacingOccurrences(of: "press_element", with: "")
        for word in ["click", "type text", "press", "move the", "drag", "write", "delete", "close the"] {
            #expect(!text.contains(word), "\(word)")
        }
        // And every tool that is marked read-only is one of them, or the memory's recall, which changes nothing.
        let readOnly = MCPServer.tools.filter { $0["annotations"]?["readOnlyHint"] == .bool(true) }.compactMap { $0["name"]?.stringValue }
        #expect(readOnly == LookTool.allCases.map(\.rawValue) + ["recall"])
    }

    @Test func callsAreRouted() {
        func call(_ params: String) -> MCPServer.Step { step(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":\#(params)}"#) }
        let id = JSONValue.number("9")
        #expect(call(#"{"name":"list_windows"}"#) == .call(id: id, call: LookCall(tool: .listWindows), modern: false))
        #expect(call(#"{"name":"list_windows","arguments":{}}"#) == .call(id: id, call: LookCall(tool: .listWindows), modern: false))
        #expect(call(#"{"name":"screenshot","arguments":{"target":"screen"}}"#)
                == .call(id: id, call: LookCall(tool: .screenshot, target: .screen, maxSide: 1568), modern: false))
        #expect(call(#"{"name":"screenshot","arguments":{"target":"w4021","max_side":800}}"#)
                == .call(id: id, call: LookCall(tool: .screenshot, target: .window(4021), maxSide: 800), modern: false))
        #expect(call(#"{"name":"screenshot","arguments":{"target":"screen","max_side":99999}}"#)
                == .call(id: id, call: LookCall(tool: .screenshot, target: .screen, maxSide: 2000), modern: false))
        #expect(call(#"{"name":"screenshot","arguments":{"target":"screen","max_side":2}}"#)
                == .call(id: id, call: LookCall(tool: .screenshot, target: .screen, maxSide: 64), modern: false))
        #expect(call(#"{"name":"screenshot","arguments":{"target":"screen","max_side":null}}"#)
                == .call(id: id, call: LookCall(tool: .screenshot, target: .screen, maxSide: 1568), modern: false))
        #expect(call(#"{"name":"read_window_text","arguments":{"window":"w7"}}"#)
                == .call(id: id, call: LookCall(tool: .readWindowText, target: .window(7)), modern: false))
        #expect(call(#"{"name":"list_windows","arguments":{},\#(meta())}"#)
                == .call(id: id, call: LookCall(tool: .listWindows), modern: true))
    }

    @Test func unknownToolsAndMalformedArgumentsAreProtocolErrors() throws {
        func code(_ params: String) -> Int? { errorCode(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":\#(params)}"#) }
        let bad = [
            #"{"name":"click"}"#, #"{"name":"Screenshot","arguments":{"target":"screen"}}"#, #"{"name":""}"#,
            #"{"arguments":{}}"#, #"{"name":7}"#, #"{}"#,
            #"{"name":"list_windows","arguments":[]}"#, #"{"name":"list_windows","arguments":"x"}"#,
            #"{"name":"screenshot"}"#, #"{"name":"screenshot","arguments":{}}"#,
            #"{"name":"screenshot","arguments":{"target":7}}"#, #"{"name":"screenshot","arguments":{"target":"window"}}"#,
            #"{"name":"screenshot","arguments":{"target":"w"}}"#, #"{"name":"screenshot","arguments":{"target":"w-1"}}"#,
            #"{"name":"screenshot","arguments":{"target":"w99999999999"}}"#, #"{"name":"screenshot","arguments":{"target":"W12"}}"#,
            #"{"name":"screenshot","arguments":{"target":"screen","max_side":"big"}}"#,
            #"{"name":"screenshot","arguments":{"target":"screen","max_side":800.5}}"#,
            #"{"name":"screenshot","arguments":{"target":"screen","max_side":0}}"#,
            #"{"name":"screenshot","arguments":{"target":"screen","max_side":-5}}"#,
            #"{"name":"screenshot","arguments":{"target":"screen","max_side":true}}"#,
            #"{"name":"read_window_text"}"#, #"{"name":"read_window_text","arguments":{"window":"screen"}}"#,
            #"{"name":"read_window_text","arguments":{"window":12}}"#, #"{"name":"read_window_text","arguments":{"target":"w1"}}"#,
        ]
        for params in bad { #expect(code(params) == -32602, "\(params)") }
        #expect(errorCode(#"{"jsonrpc":"2.0","id":9,"method":"tools/call"}"#) == -32602)
        #expect(errorCode(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":[1]}"#) == -32602)
        let unknown = try #require(reply(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"drag_to"}}"#))
        #expect(unknown["error"]?["message"]?.stringValue == "Unknown tool: drag_to")
        #expect(unknown["id"] == .number("9"))
    }

    @Test func unknownMethodsAndBrokenMessages() throws {
        #expect(errorCode(#"{"jsonrpc":"2.0","id":4,"method":"resources/list"}"#) == -32601)
        #expect(errorCode(#"{"jsonrpc":"2.0","id":4,"method":"sampling/createMessage","params":{}}"#) == -32601)
        // Not JSON: a parse error without an id, because none could be read.
        for garbage in ["", "hello", "{", #"{"jsonrpc":"2.0","id":1,"#, "\u{0}\u{1}", "[1,2", "nul"] {
            let r = try #require(reply(garbage), "\(garbage)")
            #expect(r["error"]?["code"]?.intValue == -32700)
            #expect(r["id"] == nil)
            #expect(r["jsonrpc"]?.stringValue == "2.0")
        }
        // JSON, but not a request.
        for invalid in ["[]", "7", "null", #""x""#, #"{"id":1,"method":"ping"}"#, #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
                        #"{"jsonrpc":"2.0","id":1}"#, #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
                        #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                        #"{"jsonrpc":"2.0","id":{},"method":"ping"}"#, #"{"jsonrpc":"2.0","id":1,"method":7}"#] {
            #expect(errorCode(invalid) == -32600, "\(invalid)")
        }
        // The id is echoed when it could be read.
        #expect(reply(#"{"jsonrpc":"2.0","id":"k"}"#)?["id"] == .string("k"))
        #expect(reply(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#)?["id"] == nil)
    }

    @Test func resultsOfACall() throws {
        let id = JSONValue.number("11")
        let text = MCPServer.callResult(id: id, outcome: .text("3 windows"), modern: false)
        #expect(text["result"]?["isError"] == .bool(false))
        #expect(text["result"]?["content"] == [["type": "text", "text": "3 windows"]])
        #expect(text["result"]?["resultType"] == nil)

        let image = MCPServer.callResult(id: id, outcome: .image(data: "QUJD", mimeType: "image/png", caption: "Screenshot of the screen"), modern: true)
        #expect(image["result"]?["isError"] == .bool(false))
        #expect(image["result"]?["resultType"]?.stringValue == "complete")
        #expect(image["result"]?["content"] == [["type": "image", "data": "QUJD", "mimeType": "image/png"],
                                                ["type": "text", "text": "Screenshot of the screen"]])

        let refused = MCPServer.callResult(id: id, outcome: .refused("The person did not allow this"), modern: false)
        #expect(refused["result"]?["isError"] == .bool(true))
        #expect(refused["result"]?["content"] == [["type": "text", "text": "The person did not allow this"]])
        #expect(refused["error"] == nil && refused["id"] == id)
    }

    @Test func everyAnswerIsOneLine() throws {
        var asked: [LookCall] = []
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_window_text","arguments":{"window":"w5"}}}"#,
            "not json",
        ]
        let out = lines.map { line in
            MCPServer.handle(line: line) { call in asked.append(call); return .text("Window \"A\"\n  Button \"OK\"") }
        }
        #expect(out[1] == nil)
        #expect(asked == [LookCall(tool: .readWindowText, target: .window(5))])
        for line in out.compactMap({ $0 }) {
            #expect(!line.contains("\n"))
            #expect((try? JSONValue.parse(line))?["jsonrpc"]?.stringValue == "2.0")
        }
        let called = try JSONValue.parse(try #require(out[3]))
        #expect(called["result"]?["content"]?[0]?["text"]?.stringValue == "Window \"A\"\n  Button \"OK\"")
        #expect((try JSONValue.parse(try #require(out[4])))["error"]?["code"]?.intValue == -32700)
    }
}
