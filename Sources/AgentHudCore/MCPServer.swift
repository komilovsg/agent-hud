import Foundation

/// The MCP side of `agenthud-mcp`, as pure functions over JSON values: one incoming message -> what to do with it.
///
/// Two eras of the protocol are served from the same process:
/// - revision 2026-07-28: no handshake; every request carries its protocol version and the client's capabilities
///   in `params._meta`, results carry `resultType`, and `server/discover` describes the server;
/// - revisions up to 2025-11-25: the `initialize` request, then `notifications/initialized`.
/// Which one a request belongs to is read from the request itself, so nothing is remembered between messages.
public enum MCPServer {
    public static let modernVersion = "2026-07-28"
    /// Handshake-based revisions, newest first.
    public static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static var supportedVersions: [String] { [modernVersion] + legacyVersions }

    public static let serverName = "agenthud"
    public static let serverTitle = "Agent HUD"
    public static let serverVersion = "0.2.1"
    public static let instructions = "Views of the person's Mac screen and, only when the person has turned that on in Agent HUD, actions in other apps: press an element, click, type, press keys, scroll, bring a window forward, open an app. Every call is shown to the person in Agent HUD and waits for their consent, so a call can take up to two minutes and may be refused. To act on a window, call list_windows first; to press an element, call read_window_text and use the reference it prints. The remember, recall and forget tools keep short notes for the Assistant and never ask."

    static let versionKey = "io.modelcontextprotocol/protocolVersion"
    static let capabilitiesKey = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey = "io.modelcontextprotocol/serverInfo"

    public enum ErrorCode {
        public static let parseError = -32700
        public static let invalidRequest = -32600
        public static let methodNotFound = -32601
        public static let invalidParams = -32602
        public static let unsupportedProtocolVersion = -32022
    }

    public enum Step: Equatable, Sendable {
        /// A notification or a stray response: nothing is written back.
        case ignore
        case reply(JSONValue)
        /// A valid tool call: the caller performs it and answers with `callResult`.
        case call(id: JSONValue, call: LookCall, modern: Bool)
        /// A valid act call: performed and answered the same way.
        case act(id: JSONValue, call: ActCall, modern: Bool)
        /// A valid memory call: forwarded to the app and answered the same way.
        case memory(id: JSONValue, call: MemoryCall, modern: Bool)
        /// The client gave up on a request that may still be running.
        case cancel(id: JSONValue)
    }

    // MARK: - Routing

    public static func step(line: String) -> Step {
        guard let message = try? JSONValue.parse(line) else {
            return .reply(error(id: nil, ErrorCode.parseError, "Parse error"))
        }
        return step(message)
    }

    public static func step(_ message: JSONValue) -> Step {
        guard message.objectValue != nil, message["jsonrpc"]?.stringValue == "2.0" else {
            return .reply(error(id: nil, ErrorCode.invalidRequest, "Invalid request"))
        }
        let rawId = message["id"]
        guard let method = message["method"]?.stringValue else {
            // A response is not something a client sends; it is dropped. Anything else is not a message at all.
            if message["result"] != nil || message["error"] != nil { return .ignore }
            return .reply(error(id: validId(rawId), ErrorCode.invalidRequest, "Invalid request"))
        }
        let params = message["params"]
        guard let rawId else {
            if method == "notifications/cancelled", let rid = validId(params?["requestId"]) { return .cancel(id: rid) }
            return .ignore
        }
        guard let id = validId(rawId) else {
            return .reply(error(id: nil, ErrorCode.invalidRequest, "Invalid request: id must be a string or a number"))
        }
        if let params, params.objectValue == nil {
            return .reply(error(id: id, ErrorCode.invalidParams, "params must be an object"))
        }

        if method == "initialize" {
            guard let asked = params?["protocolVersion"]?.stringValue else {
                return .reply(error(id: id, ErrorCode.invalidParams, "initialize needs protocolVersion"))
            }
            // The same version when it is one of ours, otherwise the newest handshake-based one.
            let version = legacyVersions.contains(asked) ? asked : legacyVersions[0]
            return .reply(result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": capabilities,
                "serverInfo": serverInfo,
                "instructions": .string(instructions),
            ]))
        }

        let meta = params?["_meta"]
        var modern = false
        if let asked = meta?[versionKey] {
            guard let version = asked.stringValue, version == modernVersion else {
                return .reply(error(id: id, ErrorCode.unsupportedProtocolVersion, "Unsupported protocol version", data: [
                    "supported": .array(supportedVersions.map { .string($0) }),
                    "requested": asked,
                ]))
            }
            guard meta?[capabilitiesKey]?.objectValue != nil else {
                return .reply(error(id: id, ErrorCode.invalidParams, "Missing _meta field \(capabilitiesKey)"))
            }
            modern = true
        }

        switch method {
        case "server/discover":
            guard modern else {
                return .reply(error(id: id, ErrorCode.invalidParams, "Missing _meta field \(versionKey)"))
            }
            return .reply(result(id: id, modern: true, [
                "supportedVersions": .array(supportedVersions.map { .string($0) }),
                "capabilities": capabilities,
                "instructions": .string(instructions),
            ]))
        case "ping":
            return .reply(result(id: id, modern: modern, [:]))
        case "tools/list":
            // The 2026-07-28 revision makes a list result say how long it may be kept and for whom; a client of
            // that revision drops the whole list without these two fields. The list never changes while running.
            var listed = JSONObject([JSONObject.Entry("tools", .array(tools))])
            if modern {
                listed["ttlMs"] = .int(300_000)
                listed["cacheScope"] = "private"
            }
            return .reply(result(id: id, modern: modern, .object(listed)))
        case "tools/call":
            if let kind = params?["name"]?.stringValue.flatMap(ActKind.init(rawValue:)) {
                switch ActCall.parse(kind: kind, arguments: params?["arguments"] ?? .object(JSONObject())) {
                case .success(let call): return .act(id: id, call: call, modern: modern)
                case .failure(let problem): return .reply(error(id: id, ErrorCode.invalidParams, problem.message))
                }
            }
            if let tool = params?["name"]?.stringValue.flatMap(MemoryTool.init(rawValue:)) {
                let args = params?["arguments"] ?? .object(JSONObject())
                guard args.objectValue != nil else { return .reply(error(id: id, ErrorCode.invalidParams, "arguments must be an object")) }
                switch MemoryCall.parse(tool: tool, arguments: args) {
                case .success(let call): return .memory(id: id, call: call, modern: modern)
                case .failure(let problem): return .reply(error(id: id, ErrorCode.invalidParams, problem.message))
                }
            }
            switch parseCall(params) {
            case .success(let call): return .call(id: id, call: call, modern: modern)
            case .failure(let problem): return .reply(error(id: id, ErrorCode.invalidParams, problem.message))
            }
        default:
            return .reply(error(id: id, ErrorCode.methodNotFound, "Method not found: \(RequestLog.clip(method))"))
        }
    }

    /// The whole exchange for one line when the tool call can be answered on the spot.
    public static func handle(line: String, call perform: (LookCall) -> LookReply.Outcome,
                              act: (ActCall) -> LookReply.Outcome = { _ in .refused(LookGate.Refusal.failed.message) },
                              memory: (MemoryCall) -> LookReply.Outcome = { _ in .refused(LookGate.Refusal.failed.message) }) -> String? {
        switch step(line: line) {
        case .ignore, .cancel: return nil
        case .reply(let v): return v.compact()
        case .call(let id, let call, let modern): return callResult(id: id, outcome: perform(call), modern: modern).compact()
        case .act(let id, let call, let modern): return callResult(id: id, outcome: act(call), modern: modern).compact()
        case .memory(let id, let call, let modern): return callResult(id: id, outcome: memory(call), modern: modern).compact()
        }
    }

    // MARK: - Tool calls

    struct Problem: Error, Equatable { let message: String }

    static func parseCall(_ params: JSONValue?) -> Result<LookCall, Problem> {
        guard let name = params?["name"]?.stringValue else { return .failure(Problem(message: "tools/call needs a tool name")) }
        guard let tool = LookTool(rawValue: name) else { return .failure(Problem(message: "Unknown tool: \(RequestLog.clip(name))")) }
        let args = params?["arguments"] ?? .object(JSONObject())
        guard args.objectValue != nil else { return .failure(Problem(message: "arguments must be an object")) }
        switch tool {
        case .listWindows:
            return .success(LookCall(tool: tool))
        case .screenshot:
            guard let text = args["target"]?.stringValue else {
                return .failure(Problem(message: "screenshot needs target: \"screen\" or a window id from list_windows"))
            }
            let target: LookTarget
            if text == LookTarget.screenWord { target = .screen }
            else if let n = LookTarget.parseWindowId(text) { target = .window(n) }
            else { return .failure(Problem(message: "target must be \"screen\" or a window id from list_windows")) }
            var requested: Int?
            if let raw = args["max_side"], !raw.isNull {
                guard let d = raw.doubleValue, d.isFinite, d >= 1, d.rounded() == d, d < 1e9 else {
                    return .failure(Problem(message: "max_side must be a whole number of pixels"))
                }
                requested = Int(d)
            }
            return .success(LookCall(tool: tool, target: target, maxSide: LookImage.maxSide(requested)))
        case .readWindowText:
            guard let text = args["window"]?.stringValue, let n = LookTarget.parseWindowId(text) else {
                return .failure(Problem(message: "read_window_text needs window: a window id from list_windows"))
            }
            return .success(LookCall(tool: tool, target: .window(n)))
        }
    }

    /// A finished tool call as a `tools/call` result. A refusal is a normal result marked `isError`.
    public static func callResult(id: JSONValue, outcome: LookReply.Outcome, modern: Bool) -> JSONValue {
        var content: [JSONValue] = []
        var isError = false
        switch outcome {
        case .text(let t):
            content.append(["type": "text", "text": .string(t)])
        case .image(let data, let mime, let caption):
            content.append(["type": "image", "data": .string(data), "mimeType": .string(mime)])
            content.append(["type": "text", "text": .string(caption)])
        case .refused(let why):
            content.append(["type": "text", "text": .string(why)])
            isError = true
        }
        return result(id: id, modern: modern, ["content": .array(content), "isError": .bool(isError)])
    }

    // MARK: - Tool list

    public static var tools: [JSONValue] { lookTools + actTools + memoryTools }

    /// The tools that act in other apps. None is read-only; the ones that can change or send something are marked destructive.
    public static var actTools: [JSONValue] {
        let consent = "Works only when the person turned agent actions on in Agent HUD, and asks them first."
        let window: JSONValue = ["type": "string", "description": "A window id from list_windows, for example \"w1234\""]
        func tool(_ kind: ActKind, _ title: String, _ description: String, destructive: Bool,
                  properties: JSONValue, required: [String]) -> JSONValue {
            var schema: JSONValue = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
            schema["additionalProperties"] = false
            return [
                "name": .string(kind.rawValue),
                "title": .string(title),
                "description": .string("\(description) \(consent)"),
                "inputSchema": schema,
                "annotations": ["title": .string(title), "readOnlyHint": false, "destructiveHint": .bool(destructive),
                                "idempotentHint": false, "openWorldHint": true],
            ]
        }
        return [
            tool(.pressElement, "Press element",
                 "Presses one control (a button, a checkbox, a menu item, a link) through its accessibility press action. element is a reference such as \"e12\" that read_window_text printed for this window; references stop working when the window is read again.",
                 destructive: true,
                 properties: ["window": window,
                              "element": ["type": "string", "description": "A reference from read_window_text, for example \"e12\""]],
                 required: ["window", "element"]),
            tool(.clickAt, "Click at a point",
                 "Clicks at a point of a window, for things that have no accessibility element. x and y are window points from the window's top-left corner. The window is brought to the front first.",
                 destructive: true,
                 properties: ["window": window,
                              "x": ["type": "number", "minimum": 0, "description": "Points from the window's left edge"],
                              "y": ["type": "number", "minimum": 0, "description": "Points from the window's top edge"],
                              "button": ["type": "string", "enum": ["left", "right"], "description": "Default \"left\""],
                              "count": ["type": "integer", "enum": [1, 2], "description": "2 for a double click. Default 1"]],
                 required: ["window", "x", "y"]),
            tool(.typeText, "Type text",
                 "Types text into whatever has the keyboard focus in a window, after bringing the window to the front. At most \(ActText.limit) characters: printable characters, tabs and newlines; a newline is typed as the Return key. Never types into a password field.",
                 destructive: true,
                 properties: ["window": window,
                              "text": ["type": "string", "maxLength": .int(ActText.limit), "description": "The characters to type"]],
                 required: ["window", "text"]),
            tool(.pressKeys, "Press keys",
                 "Presses one key combination in a window, after bringing it to the front, for example \"cmd+s\", \"shift+tab\" or \"escape\". Modifiers: cmd, shift, option, control. Keys: \(KeyCombo.keyNamesHelp).",
                 destructive: true,
                 properties: ["window": window,
                              "keys": ["type": "string", "description": "Modifiers and exactly one key joined by +, for example \"cmd+s\""]],
                 required: ["window", "keys"]),
            tool(.scroll, "Scroll",
                 "Scrolls a window by lines from its centre, after bringing it to the front. dy is positive to scroll down, dx is positive to scroll right; each is capped at \(ActCall.scrollCap).",
                 destructive: false,
                 properties: ["window": window,
                              "dx": ["type": "integer", "minimum": .int(-ActCall.scrollCap), "maximum": .int(ActCall.scrollCap), "description": "Lines to the right (negative: left)"],
                              "dy": ["type": "integer", "minimum": .int(-ActCall.scrollCap), "maximum": .int(ActCall.scrollCap), "description": "Lines down (negative: up)"]],
                 required: ["window"]),
            tool(.focusWindow, "Focus window", "Brings a window to the front.", destructive: false,
                 properties: ["window": window], required: ["window"]),
            tool(.openApp, "Open app",
                 "Opens an installed app, or brings it to the front when it is already running. Give exactly one of bundle_id and name.",
                 destructive: false,
                 properties: ["bundle_id": ["type": "string", "description": "For example \"com.apple.Notes\""],
                              "name": ["type": "string", "description": "The app's name as shown in the Applications folder, for example \"Notes\""]],
                 required: []),
        ]
    }

    /// The Assistant's notes. They never ask the person anything: the app shows every save and every removal itself.
    public static var memoryTools: [JSONValue] {
        func tool(_ t: MemoryTool, _ title: String, _ description: String, properties: JSONValue, required: [String],
                  readOnly: Bool, destructive: Bool) -> JSONValue {
            var schema: JSONValue = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
            schema["additionalProperties"] = false
            return [
                "name": .string(t.rawValue), "title": .string(title), "description": .string(description),
                "inputSchema": schema,
                "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive),
                                "idempotentHint": .bool(readOnly), "openWorldHint": false],
            ]
        }
        return [
            tool(.remember, "Remember",
                 "Saves one short note about a lasting preference or fact the person gave, never a secret and never anything read from a page, file or screen.",
                 properties: ["text": ["type": "string", "maxLength": .int(Memory.maxLength), "description": "One short sentence"]],
                 required: ["text"], readOnly: false, destructive: false),
            tool(.recall, "Recall", "Returns the saved notes, each with its id.",
                 properties: [:], required: [], readOnly: true, destructive: false),
            tool(.forget, "Forget", "Removes one saved note by the id that recall printed.",
                 properties: ["id": ["type": "string", "description": "An id from recall"]], required: ["id"],
                 readOnly: false, destructive: true),
        ]
    }

    public static var lookTools: [JSONValue] {
        func annotations(_ title: String) -> JSONValue {
            ["title": .string(title), "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]
        }
        let consent = "The person is asked in Agent HUD before anything is returned."
        return [
            [
                "name": .string(LookTool.listWindows.rawValue),
                "title": "List windows",
                "description": .string("Lists the windows on the person's screen: app name, window title, window id, size, and which one is frontmost. Text only, no image. Windows of excluded apps are left out. \(consent)"),
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
                "annotations": annotations("List windows"),
            ],
            [
                "name": .string(LookTool.screenshot.rawValue),
                "title": "Screenshot",
                "description": .string("Takes one screenshot and returns it as an image with a line saying what was captured. target is \"screen\" (the display under the frontmost window) or a window id from list_windows. Windows of excluded apps are never in the picture. \(consent)"),
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "target": ["type": "string", "description": "\"screen\" or a window id from list_windows, for example \"w1234\""],
                        "max_side": ["type": "integer", "minimum": .int(LookImage.minSide), "maximum": .int(LookImage.hardCap),
                                     "description": .string("Longer side of the returned image in pixels. Default \(LookImage.defaultMaxSide), at most \(LookImage.hardCap).")],
                    ],
                    "required": ["target"],
                    "additionalProperties": false,
                ],
                "annotations": annotations("Screenshot"),
            ],
            [
                "name": .string(LookTool.readWindowText.rawValue),
                "title": "Read window text",
                "description": .string("Returns the visible text of one window from its accessibility tree: roles and values, indented, at most \(LookText.limit) characters. No image. window is a window id from list_windows. While agent actions are on, controls carry a reference such as [e12] for press_element. \(consent)"),
                "inputSchema": [
                    "type": "object",
                    "properties": ["window": ["type": "string", "description": "A window id from list_windows, for example \"w1234\""]],
                    "required": ["window"],
                    "additionalProperties": false,
                ],
                "annotations": annotations("Read window text"),
            ],
        ]
    }

    // MARK: - JSON-RPC shapes

    static var capabilities: JSONValue { ["tools": [:]] }

    static var serverInfo: JSONValue {
        ["name": .string(serverName), "title": .string(serverTitle), "version": .string(serverVersion)]
    }

    /// A string or a whole-looking number; `null`, booleans and containers are not ids.
    static func validId(_ v: JSONValue?) -> JSONValue? {
        switch v {
        case .string?, .number?: return v
        default: return nil
        }
    }

    static func result(id: JSONValue, modern: Bool = false, _ fields: JSONValue) -> JSONValue {
        var r = JSONObject()
        // Handshake-era clients do not know these two fields, so only requests of the new revision get them.
        if modern { r["resultType"] = "complete" }
        for e in fields.objectValue?.entries ?? [] { r[e.key] = e.value }
        if modern { r["_meta"] = .object(JSONObject([JSONObject.Entry(serverInfoKey, serverInfo)])) }
        return ["jsonrpc": "2.0", "id": id, "result": .object(r)]
    }

    /// Without an id when the request's id could not be read.
    static func error(id: JSONValue?, _ code: Int, _ message: String, data: JSONValue? = nil) -> JSONValue {
        var e: JSONValue = ["code": .int(code), "message": .string(message)]
        if let data { e["data"] = data }
        var o = JSONObject()
        o["jsonrpc"] = "2.0"
        if let id { o["id"] = id }
        o["error"] = e
        return .object(o)
    }
}
