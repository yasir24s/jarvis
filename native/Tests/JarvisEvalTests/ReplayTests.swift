import Foundation
import JarvisCore
@testable import JarvisEval
import Testing

/// A brain that echoes the request into its reply, so any text that leaks into the report is
/// easy to find.
struct EchoBrain: EvalBrain {
    func observe(_ evalCase: EvalCase) async -> EvalObservation {
        let r = evalCase.request
        if r.contains("weather") {
            return EvalObservation(calls: [], reply: "Done, sir: \(r)", ending: .reply, latencyMs: 50, offer: nil)
        }
        if r.contains("song") {
            return EvalObservation(calls: [EvalToolCall(name: "music_play", args: ["query": r], outcome: "ran")],
                                   reply: "Playing \(r)", ending: .reply, latencyMs: 80, offer: nil)
        }
        if r.contains("battery") {
            return EvalObservation(calls: [EvalToolCall(name: "get_battery", args: [:], outcome: "ran")],
                                   reply: "Done, sir.", ending: .reply, latencyMs: 30, offer: nil)
        }
        if r.contains("slow") {
            return EvalObservation(calls: [], reply: "", ending: .timeout, latencyMs: 90_000, offer: nil)
        }
        return EvalObservation(calls: [], reply: "", ending: .empty, latencyMs: 20, offer: nil)
    }
}

@Suite("OD-EVAL: the replay reports counts, never text")
struct ReplayTests {
    static let requests = [
        "zebracorn what's the weather in Exampleton",
        "zebracorn play that song about lemons",
        "zebracorn this one is slow",
        "zebracorn quiet one",
        "zebracorn how is the battery",
    ]

    @Test func reportHasNoRequestOrReplyTextByDefault() async throws {
        let report = await Replay.run(Self.requests, brain: EchoBrain())
        let json = String(decoding: try Replay.encode(report), as: UTF8.self)
        #expect(!json.contains("zebracorn"))
        #expect(!json.contains("Exampleton"))
        #expect(!json.contains("lemons"))
        #expect(report.samples == nil)
        #expect(!report.includesText)

        #expect(report.requests == 5)
        #expect(report.claimedActionNoTool == 1)
        #expect(report.claimedActionNoActionTool == 2)
        #expect(report.claimedActionNoToolShare == 0.2)
        #expect(report.timeouts == 1)
        #expect(report.emptyReplies == 1)
        #expect(report.withToolCall == 2)
        // "weather" with no get_weather is a miss; "song" with music_play is not.
        #expect(report.keywordRequests == 2)
        #expect(report.keywordMisses == 1)
        #expect(report.byKeyword.first { $0.keyword == "weather" }?.missedNoTool == 1)
        #expect(report.byKeyword.first { $0.keyword == "song" }?.missed == 0)
        #expect(report.firstTool == ["music_play": 1, "get_battery": 1])
    }

    @Test func textOnlyWithTheFlag() async throws {
        let report = await Replay.run(Self.requests, brain: EchoBrain(), includeText: true)
        let json = String(decoding: try Replay.encode(report), as: UTF8.self)
        #expect(json.contains("zebracorn"))
        #expect(report.includesText)
        // Only the flagged requests are sampled: the two claims, the timeout and the empty reply.
        #expect(report.samples?.count == 4)
    }

    @Test func archiveReaderKeepsTheUsersLinesOnly() throws {
        let tz = TimeZone(identifier: "Europe/London")!
        let lines = [
            ArchiveEntry(timestamp: 1, timeZone: tz, channel: "text", role: .user, text: "first", turn: "t1").line,
            ArchiveEntry(timestamp: 2, timeZone: tz, channel: "text", role: .jarvis, text: "reply", turn: "t1").line,
            ArchiveEntry(timestamp: 3, timeZone: tz, channel: "voice", role: .user, text: "edited away", turn: "t2").line,
            ArchiveSupersede.line(turns: ["t2"], timestamp: 4, timeZone: tz),
            ArchiveEntry(timestamp: 5, timeZone: tz, channel: "text", role: .user, text: "  ", turn: "t3").line,
            "{\"torn\": ",
            ArchiveEntry(timestamp: 6, timeZone: tz, channel: "text", role: .user, text: "second").line,
        ]
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        #expect(Replay.requests(inArchiveData: data) == ["first", "second"])

        let dir = FileManager.default.temporaryDirectory.appending(path: "od-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: "memory"), withIntermediateDirectories: true)
        try data.write(to: dir.appending(path: "memory/archive.jsonl"))
        #expect(try Replay.requests(fromArchive: dir) == ["first", "second"])
        #expect(try Replay.requests(fromArchive: dir.appending(path: "memory/archive.jsonl")) == ["first", "second"])
    }

    @Test(arguments: [
        ("play something by Oasis", ["play"]), ("what's the weather", ["weather"]),
        ("remind me at 5", ["remind"]), ("text Priya that I'm late", ["text"]), ("call Priya", ["find/call <name>"]),
        ("set a timer for 5", ["timer"]), ("what's on my calendar", ["calendar"]), ("hello there", []),
        ("find my files", []),
    ])
    func keywords(_ text: String, _ labels: [String]) {
        #expect(Replay.keywordHits(text).map(\.label) == labels)
    }
}
