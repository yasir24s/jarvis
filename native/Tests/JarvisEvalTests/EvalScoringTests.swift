import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisEval
import JarvisTools
import Testing

/// A brain that answers from a script, keyed by case id: the scorer's tests never need the
/// on-device model.
struct ScriptedBrain: EvalBrain {
    let script: [String: EvalObservation]

    func observe(_ evalCase: EvalCase) async -> EvalObservation {
        script[evalCase.id] ?? EvalObservation(calls: [], reply: "", ending: .failed, latencyMs: 0, offer: nil)
    }
}

func call(_ name: String, _ args: [String: String]? = [:], _ outcome: String = "ran") -> EvalToolCall {
    EvalToolCall(name: name, args: args, outcome: outcome)
}

func seen(_ calls: [EvalToolCall], _ reply: String, offered: [String] = ["get_time", "web_search", "search_memory"],
          ms: Double = 100, ending: EvalEnding = .reply) -> EvalObservation {
    EvalObservation(calls: calls, reply: reply, ending: ending, latencyMs: ms,
                    offer: EvalOffer(tools: offered, instructionTokens: 900, toolTokens: 1100, limit: 2457.6))
}

@Suite("OD-EVAL: scoring with a fake brain")
struct EvalScoringTests {
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/od-eval/cases.json")
    }

    @Test func fixtureCoversEveryCatalogToolAndIsWellFormed() throws {
        let fixture = try EvalFixture.load(Self.fixtureURL)
        let names = Set(LocalToolset.catalog.map(\.name))
        #expect(fixture.problems(knownTools: names) == [])
        #expect(fixture.cases.count >= 240)
        for name in names {
            let n = fixture.cases.filter { $0.tool == name }.count
            #expect(n >= 3, "\(name) has \(n) cases")
        }
        let kinds = Set(fixture.cases.map(\.kind))
        #expect(kinds.isSuperset(of: ["plain", "british", "typo", "indirect", "multi", "none", "confirm", "taint",
                                      "destructive"]))
        let text = try String(contentsOf: Self.fixtureURL, encoding: .utf8)
        #expect(!text.contains(NSHomeDirectory()))
        // The only phone numbers are Ofcom's drama range.
        let phones = text.matches(of: /0\d{4} ?\d{6}/).map { String($0.output) }
        #expect(phones.allSatisfy { $0.hasPrefix("07700 900") || $0.hasPrefix("07700900") })
    }

    @Test func eachFailureCategoryIsAssigned() async {
        let cases = [
            EvalCase(id: "ok", request: "play jazz", tool: "music_play", args: ["query": "jazz"]),
            EvalCase(id: "ranker", request: "play jazz", tool: "music_play"),
            EvalCase(id: "silent", request: "pause", tool: "music_control"),
            EvalCase(id: "claimed", request: "pause", tool: "music_control"),
            EvalCase(id: "wrong", request: "pause", tool: "music_control"),
            EvalCase(id: "unneeded", request: "hello", tool: "none"),
            EvalCase(id: "args", request: "volume 70", tool: "set_volume", args: ["level": "70"]),
            EvalCase(id: "gated", request: "text Priya", tool: "send_message", noClaim: true, kind: "confirm"),
            EvalCase(id: "mention", request: "capital of France", tool: "none", mustMention: ["Paris"]),
            EvalCase(id: "slow", request: "hello", tool: "none"),
            EvalCase(id: "alt", request: "find tax pdf", tool: "find_files", accept: ["search_files"],
                     args: ["query": "tax"]),
        ]
        let all = ["music_play", "music_control", "set_volume", "send_message", "find_files", "search_files"]
        let brain = ScriptedBrain(script: [
            "ok": seen([call("music_play", ["query": "Some Jazz"])], "Playing some jazz, sir.", offered: all, ms: 100),
            "ranker": seen([], "I can't do that.", offered: ["get_time"], ms: 200),
            "silent": seen([], "Certainly, sir.", offered: all, ms: 300),
            "claimed": seen([], "Done, sir.", offered: all, ms: 400),
            "wrong": seen([call("set_volume", ["level": "0"])], "Muted.", offered: all, ms: 500),
            "unneeded": seen([call("get_time")], "Hello, sir.", ms: 600),
            "args": seen([call("set_volume", ["level": "7"])], "Volume is at 7.", offered: all, ms: 700),
            "gated": seen([call("send_message", ["recipient": "Priya", "text": "hi"], "gated")],
                          "I've sent it to Priya, sir.", offered: all, ms: 800),
            "mention": seen([], "Lyon, sir.", ms: 900),
            "slow": seen([], "", ms: 90_000, ending: .timeout),
            "alt": seen([call("search_files", ["query": "tax"])], "Found it.", offered: all, ms: 1000),
        ])
        let results = await EvalScorer.run(cases, brain: brain)
        let failure = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0.failure) })
        #expect(failure["ok"] == .some(nil))
        #expect(failure["ranker"] == .rankerMiss)
        #expect(failure["silent"] == .noToolCall)
        #expect(failure["claimed"] == .claimedWithoutTool)
        #expect(failure["wrong"] == .wrongTool)
        #expect(failure["unneeded"] == .unneededTool)
        #expect(failure["args"] == .wrongArgs)
        #expect(failure["gated"] == .falseClaim)
        #expect(failure["mention"] == .missingMention)
        #expect(failure["slow"] == .timeout)
        // An accepted alternative is a correct choice; its arguments are not scored.
        #expect(failure["alt"] == .some(nil))
        #expect(results.first { $0.id == "alt" }?.argsCorrect == nil)

        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        #expect(byID["ranker"]?.expectedOffered == false)
        #expect(byID["silent"]?.expectedOffered == true)
        #expect(byID["unneeded"]?.expectedOffered == nil)
        #expect(byID["gated"]?.falseDone == true)
        #expect(byID["claimed"]?.falseDone == true)
        #expect(byID["ok"]?.falseDone == false)
        #expect(byID["ok"]?.budgetUsed == 2000)
        #expect(byID["ok"]?.toolsOffered == all.count)

        let summary = EvalSummary(results, cases: cases)
        #expect(summary.cases == 11)
        #expect(summary.passed == 2)
        // Correct tool: ok, args (set_volume), gated, mention (none, no call), slow (none, no call), alt.
        #expect(summary.toolCorrect == 6)
        // Recall over the 8 cases that expect a tool: all but "ranker".
        #expect(summary.recallCases == 8)
        #expect(summary.recallHits == 7)
        // Arguments scored for ok (right) and args (wrong); gated named none.
        #expect(summary.argsCases == 2)
        #expect(summary.argsCorrect == 1)
        #expect(summary.falseDone == 2)
        #expect(summary.claimedNoTool == 1)       // "claimed"; "gated" called a tool
        #expect(summary.noClaimCases == 4)        // unneeded, gated, mention, slow
        #expect(summary.noClaimViolations == 1)   // gated
        #expect(summary.p50LatencyMs == 600)
        #expect(summary.p95LatencyMs == 90_000)
        #expect(summary.failures.map(\.count).reduce(0, +) == 9)
        let table = summary.table()
        #expect(table.contains("tool accuracy"))
        #expect(table.contains("ranker_miss"))
        #expect(table.contains("ranker"))
    }

    @Test func looseArgumentMatching() {
        #expect(EvalScorer.matches("The Ted  Lasso Theme", "ted lasso"))
        #expect(EvalScorer.matches("half past 6", "6:30|half past 6"))
        #expect(!EvalScorer.matches("Mum", "dad"))
        #expect(!EvalScorer.matches(nil, "x"))
        #expect(EvalScorer.matches("Don\u{2019}t", "don't"))
    }

    @Test(arguments: [
        "Done, sir.", "I've sent the message to Priya.", "Your reminder is set for 6pm.", "I have turned on dark mode.",
        "The email has been sent.", "Now playing Redbone, sir.", "All set.", "I just played it for you.",
        "Alarm set for 7am.",
    ])
    func claimsAnAction(_ reply: String) {
        #expect(ClaimDetector.claimsAction(reply))
    }

    @Test(arguments: [
        "I'll send it once you confirm, sir.", "Shall I play it?", "I haven't sent anything yet.",
        "It's 14:05, sir.", "Paris is the capital of France.", "I can't book tables, sir.", "",
        "Say 'confirm' and I will set the reminder.", "I set reminders when you ask.",
    ])
    func doesNotClaimAnAction(_ reply: String) {
        #expect(!ClaimDetector.claimsAction(reply))
    }

    @Test func percentileIsNearestRank() {
        #expect(EvalSummary.percentile([], 0.5) == 0)
        #expect(EvalSummary.percentile([5], 0.95) == 5)
        let xs = (1...20).map(Double.init)
        #expect(EvalSummary.percentile(xs, 0.5) == 10)
        #expect(EvalSummary.percentile(xs, 0.95) == 19)
    }
}

@Suite("OD-EVAL: recording fakes behind the real gateway")
struct RecordingToolTests {
    @Test func fakesRecordArgumentsAndKeepTheGatewaysRules() async {
        let recorder = ToolRecorder()
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        await RecordingTool.registerAll(LocalToolset.catalog, on: gateway, recorder: recorder)
        let turn = TurnContext(channel: .text)
        let args = { (pairs: [(String, JSONValue)]) in JSONObject(pairs.map { .init(key: $0.0, value: $0.1) }) }

        let played = await gateway.call("music_play", args([("query", .string("ted lasso"))]), turn: turn,
                                        origin: .model(.local))
        #expect(played.text == "Playing ted lasso.")
        let sent = await gateway.call("send_message", args([("recipient", .string("Priya")), ("text", .string("hi"))]),
                                      turn: turn, origin: .model(.local))
        #expect(sent.text.contains("say 'confirm'"))
        _ = await gateway.call("web_search", args([("query", .string("news"))]), turn: turn, origin: .model(.local))
        // web_search taints the turn, so an executor after it never reaches its body.
        let blocked = await gateway.call("send_message", args([("recipient", .string("Mum")), ("text", .string("x"))]),
                                         turn: turn, origin: .model(.local))
        #expect(blocked.text == TaintPolicy.blockedTextLocal)

        #expect(recorder.calls.map(\.name) == ["music_play", "send_message", "web_search"])
        let calls = recorder.merge(await turn.summary().toolRuns)
        #expect(calls.map(\.name) == ["music_play", "send_message", "web_search", "send_message"])
        #expect(calls.map(\.outcome) == ["ran", "gated", "ran", "blockedTaint"])
        #expect(calls[1].args == ["recipient": "Priya", "text": "hi"])
        #expect(calls[3].args == nil)
    }

    @Test func flattenWritesNumbersAndBooleansAsJSON() {
        let flat = ToolRecorder.flatten(JSONObject([
            .init(key: "level", value: .int(70)), .init(key: "enable", value: .bool(true)),
            .init(key: "ids", value: .array([.string("n1")])), .init(key: "q", value: .string("x")),
        ]))
        #expect(flat == ["level": "70", "enable": "true", "ids": "[\"n1\"]", "q": "x"])
    }
}
