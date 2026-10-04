import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// od/phase2 item 1: the on-device reply is checked against the turn's gateway results. Claims
/// nothing backs are dropped, gated and blocked calls get Swift's reply, everything else stays.
@Suite("OD2 reply check: no unearned 'Done', Swift-written gate and block replies", .timeLimit(.minutes(1)))
struct ReplyCheckTests {
    typealias Call = ReplyCheck.Call

    @Test("sentences that report an action are claims; offers, questions, negations and answers are not")
    func detector() {
        for claim in ["Done, sir.", "All set.", "Consider it done, sir.", "I've sent it to Priya.",
                      "I have set an alarm for 7.", "I just turned the volume up.", "I paused the music.",
                      "Your reminder is set for 5 pm.", "The message has been sent.", "Alarm set.",
                      "Volume adjusted to 40%.", "I've opened Notes for you, sir.", "Sorted, sir!",
                      "The file was deleted successfully.", "I\u{2019}ve muted it."] {
            #expect(ReplyCheck.claims(claim), "\(claim)")
        }
        for plain in ["It's 3:45 pm, sir.", "Shall I send it?", "I'll send it once you confirm.",
                      "I haven't sent it yet.", "I can't set alarms without the tool.",
                      "Now playing: Clair de Lune by Debussy.", "Your battery is at 80%, sir.",
                      "A fine hour for regret, sir.", "I set great store by punctuality.", "Done?",
                      "Donegal is lovely in spring."] {
            #expect(!ReplyCheck.claims(plain), "\(plain)")
        }
    }

    @Test("with no action run, claims are dropped and the rest is kept word for word")
    func dropsClaims() {
        #expect(ReplyCheck.check("Done, sir.", calls: []) == ReplyCheck.notDone)
        #expect(ReplyCheck.check("Done, sir — it's noon. Quite the hour.", calls: [])
                == "It's noon. Quite the hour.")
        #expect(ReplyCheck.check("I've set your alarm. You'll thank me at dawn, sir.", calls: [])
                == "You'll thank me at dawn, sir.")
        // Untouched when nothing claims.
        #expect(ReplyCheck.check("It is noon, sir. Anything else?", calls: []) == "It is noon, sir. Anything else?")
    }

    @Test("read-only tools never earn a 'Done'; an action tool that ran does")
    func readOnlyNeverDone() {
        let time = Call(name: "get_time", outcome: .ran, text: "12:00")
        #expect(ReplyCheck.check("Done, sir. It's noon.", calls: [time]) == "It's noon.")
        #expect(ReplyCheck.check("Done, sir.", calls: [time]) == ReplyCheck.notDone)
        let volume = Call(name: "set_volume", outcome: .ran, text: "Volume set, sir.")
        #expect(ReplyCheck.check("Done, sir.", calls: [volume]) == "Done, sir.")
        // A failed action earns nothing.
        let failed = Call(name: "set_volume", outcome: .failed, text: "error")
        #expect(ReplyCheck.check("Done, sir.", calls: [failed]) == ReplyCheck.notDone)
    }

    @Test("a gated or blocked call: Swift writes the reply from the gateway outcome")
    func overrides() {
        let gated = Call(name: "send_email", outcome: .gated,
                         text: GuardStrings.gatePrompt("That will email Priya at priya@example.com"))
        #expect(ReplyCheck.check("Sent, sir. I've emailed Priya.", calls: [gated])
                == "That needs your confirmation, sir: that will email Priya at priya@example.com. "
                + "Say 'confirm' to proceed.")
        let taint = Call(name: "send_message", outcome: .blockedTaint, text: TaintPolicy.blockedTextLocal)
        #expect(ReplyCheck.check("Message sent.", calls: [taint]) == ReplyCheck.taintBlocked)
        let guarded = Call(name: "run_command", outcome: .blockedGuard, text: GuardStrings.systemDamaging)
        #expect(ReplyCheck.check("All done.", calls: [guarded]) == GuardStrings.systemDamaging)
        // Each line once.
        #expect(ReplyCheck.overrideReply([taint, taint]) == ReplyCheck.taintBlocked)
        #expect(ReplyCheck.overrideReply([Call(name: "get_time", outcome: .ran, text: "")]) == nil)
    }

    // MARK: - LocalBrain

    func generate(_ steps: [FakeStep], gateway: ToolGateway = localTestGateway(),
                  turn: TurnContext = TurnContext(channel: .voice)) async -> (LocalOutcome, RecordingSink, LogRecorder) {
        let sink = RecordingSink()
        let logs = LogRecorder()
        let brain = LocalBrain(gateway: gateway, model: FakeLocalModel(attempts: [steps]), log: logs.function)
        let outcome = await brain.generate(system: "S", user: "turn it up", channel: .voice, turn: turn, sink: sink)
        return (outcome, sink, logs)
    }

    @Test("LocalBrain: an unearned 'Done' is never spoken or shown; the persona's remark is")
    func brainDropsClaim() async {
        let (outcome, sink, logs) = await generate([.snapshot("Done, sir. Louder than strictly wise.")])
        #expect(outcome == .reply("Louder than strictly wise."))
        #expect(await sink.sentences == ["Louder than strictly wise."])
        #expect(await sink.deltas == ["Louder than strictly wise."])
        #expect(logs.lines == ["Local model: reply check changed 1 sentence(s)"])
    }

    @Test("LocalBrain: a reply that was only a claim becomes the question")
    func brainNotDone() async {
        let (outcome, sink, _) = await generate([.snapshot("Done, sir.")])
        #expect(outcome == .reply(ReplyCheck.notDone))
        #expect(await sink.sentences == [ReplyCheck.notDone])
    }

    @Test("LocalBrain: the claim stands when the action tool ran")
    func brainKeepsEarnedClaim() async throws {
        let gateway = localTestGateway()
        let schema = try #require(ToolCatalog.tools.first { $0.name == "set_volume" })
        await gateway.register(RecordingBody(calls: RecordingBody.Calls()), schema: schema)
        let (outcome, _, _) = await generate([.call("set_volume", #"{"level": 80}"#), .snapshot("Done, sir.")],
                                             gateway: gateway)
        #expect(outcome == .reply("Done, sir."))
    }

    @Test("LocalBrain: a call blocked by taint gets Swift's reply, not the model's")
    func brainTaint() async {
        let turn = TurnContext(channel: .voice, startTainted: true)
        let (outcome, sink, _) = await generate([.call("send_message", #"{"to": "Priya", "text": "hi"}"#),
                                                 .snapshot("Message sent, sir.")], turn: turn)
        #expect(outcome == .reply(ReplyCheck.taintBlocked))
        #expect(await sink.sentences == [ReplyCheck.taintBlocked])
    }

    @Test("LocalBrain: a guard refusal is the gateway's words")
    func brainGuard() async {
        let script = #"{"script": "do shell script \"rm -rf ~\""}"#
        let (outcome, _, _) = await generate([.call("run_applescript", script), .snapshot("All done, sir.")])
        #expect(outcome == .reply(GuardStrings.appleScriptRefused))
    }
}
