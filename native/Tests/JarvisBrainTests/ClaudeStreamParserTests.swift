import Foundation
import JarvisBrain
import JarvisTestSupport
import Testing

/// A-7 (plan M02-M04 §5): the probe's recorded stdout (Tests/Fixtures/claude/
/// probe-2026-09-28.jsonl, 35 lines from claude 2.1.282) parses into the events the driver
/// needs: 1 init, 2 refusals, 1 model fallback, 1 tool_use, the text "pong" and a success.
@Suite("M3 Claude stream-json parser (A-7)")
struct ClaudeStreamParserTests {
    static let probe = Golden.directory.deletingLastPathComponent()
        .appending(path: "claude/probe-2026-09-28.jsonl", directoryHint: .notDirectory)

    // The four message ids in the probe, in message_start order.
    static let id1 = "msg_011CfVnAMKLzhzDLagZZB3UU", id2 = "msg_011CfVnAWdvwURqsySYN9Pkp"
    static let id3 = "msg_011CfVnAkMSAX6WB2yVrH2ei", id4 = "msg_011CfVnAtxrsd7zQYEkr7wVw"

    static func probeLines() throws -> [String] {
        let text = try String(contentsOf: probe, encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func probeEvents() throws -> [ClaudeEvent] {
        var parser = StreamJSONParser()
        return try probeLines().flatMap { parser.parse($0) }
    }

    @Test func probeParsesIntoTheA7Events() throws {
        #expect(try Self.probeLines().count == 35)
        let events = try Self.probeEvents()

        let inits = events.filter { if case .initInfo = $0 { true } else { false } }
        #expect(inits == [.initInfo(apiKeySource: "none", tools: ["mcp__jarvis__ping"],
                                    mcp: ["jarvis": "connected"], model: "claude-opus-5-5")])

        let stops = events.compactMap { e -> String? in
            if case .stopReason(_, let r) = e { r } else { nil }
        }
        #expect(stops.filter { $0 == "refusal" }.count == 2)
        #expect(stops.filter { $0 == "tool_use" }.count == 1)

        let fallbacks = events.filter { if case .refusalFallback = $0 { true } else { false } }
        #expect(fallbacks == [.refusalFallback(from: "claude-opus-5-5", to: "claude-opus-4-8", category: "cyber")])

        #expect(events.filter { $0 == .toolResult }.count == 1)

        let deltas = events.compactMap { e -> String? in
            if case .textDelta(_, let t) = e { t } else { nil }
        }
        #expect(deltas.joined() == "pong")
        let blocks = events.filter { if case .blockText = $0 { true } else { false } }
        #expect(blocks == [.blockText(msgID: Self.id4, text: "pong")])

        let results = events.filter { if case .result = $0 { true } else { false } }
        #expect(results == [.result(subtype: "success", isError: false, text: "pong", apiErrorStatus: nil)])

        #expect(!events.contains { if case .unknown = $0 { true } else { false } })
    }

    /// Every event, in order. Deltas and stop reasons take the latest message_start's id.
    @Test func probeFullEventSequence() throws {
        let expected: [ClaudeEvent] = [
            .initInfo(apiKeySource: "none", tools: ["mcp__jarvis__ping"], mcp: ["jarvis": "connected"],
                      model: "claude-opus-5-5"),
            .status("requesting"),
            .messageStart(msgID: Self.id1, model: "claude-opus-5-5"),
            .stopReason(msgID: Self.id1, "refusal"),
            .rateLimit(status: "allowed", isUsingOverage: false),
            .status("requesting"),
            .messageStart(msgID: Self.id2, model: "claude-opus-5-5"),
            .refusalFallback(from: "claude-opus-5-5", to: "claude-opus-4-8", category: "cyber"),
            .stopReason(msgID: Self.id2, "refusal"),
            .messageStart(msgID: Self.id3, model: "claude-opus-4-8"),
            .stopReason(msgID: Self.id3, "tool_use"),
            .toolResult,
            .status("requesting"),
            .messageStart(msgID: Self.id4, model: "claude-opus-4-8"),
            .textDelta(msgID: Self.id4, text: "p"),
            .textDelta(msgID: Self.id4, text: "ong"),
            .blockText(msgID: Self.id4, text: "pong"),
            .stopReason(msgID: Self.id4, "end_turn"),
            .result(subtype: "success", isError: false, text: "pong", apiErrorStatus: nil),
        ]
        #expect(try Self.probeEvents() == expected)
    }

    @Test func unknownAndMalformedLinesAreIgnored() {
        var p = StreamJSONParser()
        _ = p.parse(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m1","model":"x"}}}"#)
        #expect(p.parse(#"{"type":"brand_new_event","x":1}"#) == [.unknown(type: "brand_new_event")])
        #expect(p.parse(#"{"type":"system","subtype":"compact_boundary"}"#) == [.unknown(type: "system")])
        #expect(p.parse("not json") == [.unknown(type: "")])
        #expect(p.parse("[1, 2]") == [.unknown(type: "")])
        #expect(p.parse(#"{"type": 5}"#) == [.unknown(type: "")])
        #expect(p.parse("") == [])
        #expect(p.parse("  \t") == [])
        #expect(p.currentMessageID == "m1")
    }

    @Test func deltaIDsFollowTheLatestMessageStart() {
        var p = StreamJSONParser()
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}},"parent_tool_use_id":null}"#
        #expect(p.parse(delta) == [.textDelta(msgID: "", text: "hi")])
        _ = p.parse(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"m2","model":"x"}}}"#)
        #expect(p.parse(delta) == [.textDelta(msgID: "m2", text: "hi")])
        #expect(p.parse(#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"end_turn"}}}"#)
                == [.stopReason(msgID: "m2", "end_turn")])
        #expect(p.parse(#"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":null}}}"#) == [])
    }

    @Test func subAgentTrafficAndEmptyTextGiveNoEvents() {
        var p = StreamJSONParser()
        #expect(p.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}},"parent_tool_use_id":"toolu_1"}"#) == [])
        #expect(p.parse(#"{"type":"stream_event","event":{"type":"message_start","message":{"id":"sub","model":"x"}},"parent_tool_use_id":"toolu_1"}"#) == [])
        #expect(p.currentMessageID == "")
        #expect(p.parse(#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":"x"}]},"parent_tool_use_id":"toolu_1"}"#) == [])
        #expect(p.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":""}}}"#) == [])
        #expect(p.parse(#"{"type":"assistant","message":{"id":"a","content":[{"type":"text","text":""},{"type":"text","text":"y"}]}}"#)
                == [.blockText(msgID: "a", text: "y")])
    }

    @Test func resultCarriesAPIErrorStatus() {
        var p = StreamJSONParser()
        #expect(p.parse(#"{"type":"result","subtype":"error_during_execution","is_error":true,"api_error_status":529}"#)
                == [.result(subtype: "error_during_execution", isError: true, text: nil, apiErrorStatus: 529)])
        #expect(p.parse(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","isUsingOverage":true}}"#)
                == [.rateLimit(status: "allowed_warning", isUsingOverage: true)])
    }
}
