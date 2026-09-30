import Foundation
import JarvisCore
import JarvisTools

/// The JSON-RPC subset of plan §3.7: newline-delimited, one object per line. Lines are parsed
/// with `PyJSON.loads` and replies written with `PyJSON.dumps`, which is Python's `json.dumps`:
/// one line, strings escaped, key order kept (so each `inputSchema` stays in Python's order).
struct MCPJSONRPC: Sendable {
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let defaultProtocolVersion = "2025-11-25"

    /// What one incoming line asks for.
    enum Message: Sendable {
        /// Not a request: reply with this error at once.
        case invalid(JSONValue)
        /// No `id`: never answered, only logged.
        case notification(method: String)
        case request(id: JSONValue, method: String, params: JSONObject?)
    }

    /// What the server does with a request.
    enum Action: Sendable {
        case reply(JSONValue)
        case callTool(name: String, arguments: JSONObject)
    }

    private let toolsList: JSONValue
    private let toolNames: Set<String>

    init(tools: [ToolSchema]) {
        let entries = tools.map { tool -> JSONValue in
            let schema = (try? PyJSON.loads(Data(tool.parametersJSON.utf8)))
                ?? .object(JSONObject([.init(key: "type", value: .string("object")),
                                       .init(key: "properties", value: .object(JSONObject()))]))
            return .object(JSONObject([.init(key: "name", value: .string(tool.name)),
                                       .init(key: "description", value: .string(tool.description)),
                                       .init(key: "inputSchema", value: schema)]))
        }
        toolsList = .object(JSONObject([.init(key: "tools", value: .array(entries))]))
        toolNames = Set(tools.map(\.name))
    }

    static func encode(_ value: JSONValue) -> String {
        PyJSON.dumps(value)
    }

    static func parse(_ line: [UInt8]) -> Message {
        guard let value = try? PyJSON.loads(Data(line)) else {
            return .invalid(error(id: .null, code: -32700, message: "Parse error"))
        }
        guard case .object(let object) = value else {
            // A batch array, or a bare scalar.
            return .invalid(error(id: .null, code: -32600, message: "Invalid Request"))
        }
        // The envelope, checked on top of the parser: `"jsonrpc": "2.0"`, a string method, and
        // a request id that is a string or an integer. Anything else is answered, never dispatched.
        let id = object["id"]
        guard object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else {
            return .invalid(error(id: id.flatMap(validID) ?? .null, code: -32600, message: "Invalid Request"))
        }
        guard let id else { return .notification(method: method) }
        guard let requestID = validID(id) else {
            return .invalid(error(id: .null, code: -32600, message: "Invalid Request"))
        }
        return .request(id: requestID, method: method, params: object["params"]?.objectValue)
    }

    /// The reply to a request on an open turn, or the tool call it needs.
    func action(method: String, id: JSONValue, params: JSONObject?) -> Action {
        switch method {
        case "initialize":
            let asked = params?["protocolVersion"]?.stringValue
            let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil }
                ?? Self.defaultProtocolVersion
            let tools = JSONObject([.init(key: "listChanged", value: .bool(false))])
            let serverInfo = JSONObject([.init(key: "name", value: .string("jarvis")),
                                         .init(key: "version", value: .string("1.0.0"))])
            return .reply(Self.result(id: id, .object(JSONObject([
                .init(key: "protocolVersion", value: .string(version)),
                .init(key: "capabilities", value: .object(JSONObject([.init(key: "tools", value: .object(tools))]))),
                .init(key: "serverInfo", value: .object(serverInfo)),
            ]))))
        case "ping":
            return .reply(Self.result(id: id, .object(JSONObject())))
        case "tools/list":
            return .reply(Self.result(id: id, toolsList))
        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            guard toolNames.contains(name) else {
                return .reply(Self.error(id: id, code: -32602, message: "Unknown tool: \(name)"))
            }
            return .callTool(name: name, arguments: params?["arguments"]?.objectValue ?? JSONObject())
        default:
            return .reply(Self.error(id: id, code: -32601, message: "Method not found"))
        }
    }

    /// `{"content":[{"type":"text","text":…}]}`, plus `"isError":true` only when the gateway says so.
    static func toolResult(id: JSONValue, _ call: ToolCallResult) -> JSONValue {
        let text = JSONObject([.init(key: "type", value: .string("text")),
                               .init(key: "text", value: .string(call.text))])
        var members: [JSONObject.Member] = [.init(key: "content", value: .array([.object(text)]))]
        if call.isError { members.append(.init(key: "isError", value: .bool(true))) }
        return result(id: id, .object(JSONObject(members)))
    }

    static func turnClosed(id: JSONValue) -> JSONValue {
        error(id: id, code: -32000, message: "Turn closed")
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        .object(JSONObject([.init(key: "jsonrpc", value: .string("2.0")), .init(key: "id", value: id),
                            .init(key: "result", value: result)]))
    }

    static func error(id: JSONValue, code: Int64, message: String) -> JSONValue {
        let body = JSONObject([.init(key: "code", value: .int(code)), .init(key: "message", value: .string(message))])
        return .object(JSONObject([.init(key: "jsonrpc", value: .string("2.0")), .init(key: "id", value: id),
                                   .init(key: "error", value: .object(body))]))
    }

    /// An MCP request id is a string or an integer (MCP rules out null; a fraction is no id).
    /// Anything else, NaN and infinity included, is not echoed: the error reply carries `null`.
    private static func validID(_ id: JSONValue) -> JSONValue? {
        switch id {
        case .string, .int, .bigInt: id
        case .null, .double, .bool, .array, .object: nil
        }
    }
}
