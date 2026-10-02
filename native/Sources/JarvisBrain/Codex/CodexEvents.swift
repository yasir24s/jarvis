import Foundation
import JarvisCore

/// B2: one line of `codex exec --json` output, as codex-cli 0.159.2 writes them:
///
///     {"type":"thread.started","thread_id":…}
///     {"type":"turn.started"}
///     {"type":"item.started"|"item.updated"|"item.completed","item":{"id":…,"type":…,…}}
///     {"type":"turn.completed","usage":{"input_tokens":…,"output_tokens":…,…}}
///     {"type":"turn.failed","error":{"message":…}}
///     {"type":"error","message":…}
///
/// An agent message arrives whole, in its `item.completed`: exec's JSON output has no text
/// deltas. A JARVIS tool call is an `mcp_tool_call` item with `server` and `tool`.
public enum CodexEvent: Sendable, Equatable {
    case threadStarted
    case turnStarted
    /// A finished agent message.
    case message(id: String, text: String)
    /// A reasoning item (its text is not shown).
    case reasoning
    /// An MCP tool call starting or finished.
    case toolCall(id: String, server: String, tool: String, finished: Bool, failed: Bool)
    /// A notice item (`"type":"error"` inside an item): the CLI goes on.
    case notice(String)
    /// Any other item: a Codex built-in tool (`command_execution`, `file_change`, `web_search`,
    /// …). JARVIS stops the turn on it.
    case builtIn(type: String)
    case turnCompleted(inputTokens: Int?, outputTokens: Int?)
    case turnFailed(String)
    /// A top-level error event. A retry notice ("Reconnecting... 2/5 (…)") comes as one too.
    case error(String)
    /// Not JSON, or a type this parser does not know.
    case unknown(String)

    public static func parse(_ line: String) -> CodexEvent? {
        guard !Py.strip(line).isEmpty else { return nil }
        guard let value = try? PyJSON.loads(Data(line.utf8)), case .object(let o) = value,
              case .string(let type)? = o["type"] else {
            return .unknown(line)
        }
        switch type {
        case "thread.started":
            return .threadStarted
        case "turn.started":
            return .turnStarted
        case "turn.completed":
            var input: Int?, output: Int?
            if case .object(let usage)? = o["usage"] {
                if case .int(let n)? = usage["input_tokens"] { input = Int(n) }
                if case .int(let n)? = usage["output_tokens"] { output = Int(n) }
            }
            return .turnCompleted(inputTokens: input, outputTokens: output)
        case "turn.failed":
            if case .object(let error)? = o["error"], case .string(let message)? = error["message"] {
                return .turnFailed(message)
            }
            return .turnFailed("")
        case "error":
            if case .string(let message)? = o["message"] { return .error(message) }
            return .error("")
        case "item.started", "item.updated", "item.completed":
            guard case .object(let item)? = o["item"], case .string(let itemType)? = item["type"] else {
                return .unknown(line)
            }
            let id: String
            if case .string(let s)? = item["id"] { id = s } else { id = "" }
            let finished = type == "item.completed"
            switch itemType {
            case "agent_message":
                guard finished else { return nil }
                if case .string(let text)? = item["text"] { return .message(id: id, text: text) }
                return .message(id: id, text: "")
            case "reasoning":
                return .reasoning
            case "error":
                if case .string(let message)? = item["message"] { return .notice(message) }
                return .notice("")
            case "mcp_tool_call":
                var server = "", tool = "", failed = false
                if case .string(let s)? = item["server"] { server = s }
                if case .string(let s)? = item["tool"] { tool = s }
                if case .string(let status)? = item["status"] { failed = Py.eq(status, "failed") }
                return .toolCall(id: id, server: server, tool: tool, finished: finished, failed: failed)
            default:
                return .builtIn(type: itemType)
            }
        default:
            return .unknown(line)
        }
    }
}
