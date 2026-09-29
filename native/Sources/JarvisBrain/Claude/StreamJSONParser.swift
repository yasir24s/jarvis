import Foundation
import JarvisCore

// `claude -p --output-format stream-json --verbose --include-partial-messages` events
// (plan: M02-M04 §2.4 observed, §3.6 table). Test fixture: Tests/Fixtures/claude/
// probe-2026-09-28.jsonl, the probe's full 35-line output.

/// One event the driver acts on. The cases are exactly plan §3.6's.
public enum ClaudeEvent: Sendable, Equatable {
    case initInfo(apiKeySource: String, tools: [String], mcp: [String: String], model: String)
    case status(String)
    case textDelta(msgID: String, text: String)
    case blockText(msgID: String, text: String)
    case messageStart(msgID: String, model: String)
    case stopReason(msgID: String, String)
    case refusalFallback(from: String, to: String, category: String)
    case rateLimit(status: String, isUsingOverage: Bool)
    case toolResult
    case result(subtype: String, isError: Bool, text: String?, apiErrorStatus: Int?)
    case unknown(type: String)
}

/// Parses the CLI's stdout one NDJSON line at a time.
///
/// It is stateful: `content_block_delta` and `message_delta` carry no message id in the
/// probe, so their `msgID` is the id of the latest `message_start` (learned 2026-09-29).
///
/// A line gives zero or more events. Lines of a known type that carry nothing the driver
/// uses give none: `content_block_start` / `_stop`, `message_stop`, thinking, signature and
/// input-JSON deltas, non-text assistant blocks, synthetic user notes. A line whose
/// top-level `type` is unknown gives `.unknown(type:)`, and a line that is not a JSON object
/// with a string `type` gives `.unknown(type: "")`; the driver ignores both. Stream and
/// assistant events with a non-null `parent_tool_use_id` (a sub-agent's traffic) give none.
/// Empty text gives no event: Python's loop feeds only non-empty text (`if block.text`).
public struct StreamJSONParser: Sendable {
    /// The id of the latest `message_start`; "" before the first one.
    public private(set) var currentMessageID = ""

    public init() {}

    public mutating func parse(_ line: String) -> [ClaudeEvent] {
        if line.unicodeScalars.allSatisfy(Py.isSpace) { return [] }
        guard let value = try? PyJSON.loads(Data(line.utf8)), let obj = value.objectValue,
              let type = obj["type"]?.stringValue else {
            return [.unknown(type: "")]
        }
        switch type {
        case "system": return system(obj)
        case "stream_event": return streamEvent(obj)
        case "assistant": return assistant(obj)
        case "user": return user(obj)
        case "rate_limit_event":
            let info = obj["rate_limit_info"]?.objectValue
            return [.rateLimit(status: Self.string(info?["status"]),
                               isUsingOverage: info?["isUsingOverage"] == .bool(true))]
        case "result":
            var status: Int?
            if case .int(let i)? = obj["api_error_status"] { status = Int(exactly: i) }
            return [.result(subtype: Self.string(obj["subtype"]), isError: obj["is_error"] == .bool(true),
                            text: obj["result"]?.stringValue, apiErrorStatus: status)]
        default:
            return [.unknown(type: type)]
        }
    }

    private func system(_ obj: JSONObject) -> [ClaudeEvent] {
        switch obj["subtype"]?.stringValue {
        case "init":
            var mcp: [String: String] = [:]
            for server in obj["mcp_servers"]?.arrayValue ?? [] {
                if let s = server.objectValue, let name = s["name"]?.stringValue {
                    mcp[name] = Self.string(s["status"])
                }
            }
            let tools = (obj["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
            return [.initInfo(apiKeySource: Self.string(obj["apiKeySource"]), tools: tools, mcp: mcp,
                              model: Self.string(obj["model"]))]
        case "status":
            return [.status(Self.string(obj["status"]))]
        case "model_refusal_fallback":
            return [.refusalFallback(from: Self.string(obj["original_model"]),
                                     to: Self.string(obj["fallback_model"]),
                                     category: Self.string(obj["api_refusal_category"]))]
        default:
            return [.unknown(type: "system")]
        }
    }

    private mutating func streamEvent(_ obj: JSONObject) -> [ClaudeEvent] {
        guard Self.isTopLevel(obj), let event = obj["event"]?.objectValue else { return [] }
        switch event["type"]?.stringValue {
        case "message_start":
            let message = event["message"]?.objectValue
            currentMessageID = Self.string(message?["id"])
            return [.messageStart(msgID: currentMessageID, model: Self.string(message?["model"]))]
        case "content_block_delta":
            guard let delta = event["delta"]?.objectValue, delta["type"] == .string("text_delta"),
                  let text = delta["text"]?.stringValue, !text.isEmpty else { return [] }
            return [.textDelta(msgID: currentMessageID, text: text)]
        case "message_delta":
            guard let reason = event["delta"]?.objectValue?["stop_reason"]?.stringValue else { return [] }
            return [.stopReason(msgID: currentMessageID, reason)]
        default:
            return []
        }
    }

    private func assistant(_ obj: JSONObject) -> [ClaudeEvent] {
        guard Self.isTopLevel(obj), let message = obj["message"]?.objectValue else { return [] }
        let id = Self.string(message["id"])
        return (message["content"]?.arrayValue ?? []).compactMap { block in
            guard let b = block.objectValue, b["type"] == .string("text"),
                  let text = b["text"]?.stringValue, !text.isEmpty else { return nil }
            return .blockText(msgID: id, text: text)
        }
    }

    private func user(_ obj: JSONObject) -> [ClaudeEvent] {
        let content = obj["message"]?.objectValue?["content"]?.arrayValue ?? []
        return content.compactMap { block in
            block.objectValue?["type"] == .string("tool_result") ? .toolResult : nil
        }
    }

    private static func isTopLevel(_ obj: JSONObject) -> Bool {
        obj["parent_tool_use_id"] == nil || obj["parent_tool_use_id"] == .null
    }

    private static func string(_ v: JSONValue?) -> String {
        v?.stringValue ?? ""
    }
}
