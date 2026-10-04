import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// od/guided-generation: the guided tool choice, against FakeGuidedSession. Every chosen tool
/// runs through a real DynamicTool and a real gateway, so taint and confirmation are the
/// gateway's own.
@Suite("od guided generation: tool choice, arguments, chains, fallback and safety", .timeLimit(.minutes(1)))
struct GuidedToolsTests {
    static let system = "You are a test assistant."
    typealias G = FakeGuidedSession

    struct Run {
        let model: FakeLocalModel
        let guided: FakeGuidedSession
        let sink = RecordingSink()
        let logs = LogRecorder()
        let turn: TurnContext
        let brain: LocalBrain

        init(_ guided: FakeGuidedSession, reply: [[FakeStep]] = [[.snapshot("Yes, sir.")]],
             offer: [String]? = nil, gateway: ToolGateway = localTestGateway(), tainted: Bool = false,
             enabled: Bool = true) {
            self.guided = guided
            model = FakeLocalModel(attempts: reply, offer: offer, guided: guided)
            turn = TurnContext(channel: .voice, startTainted: tainted)
            brain = LocalBrain(gateway: gateway, model: model, log: logs.function, guided: { enabled })
        }

        func generate(_ user: String) async -> LocalOutcome {
            await brain.generate(system: GuidedToolsTests.system, user: user, channel: .voice, turn: turn,
                                 sink: sink)
        }
    }

    /// A gateway with set_volume, find_contact and send_message bodies that record.
    struct Bodies {
        let gateway = localTestGateway()
        let volume = RecordingBody.Calls()
        let contacts = RecordingBody.Calls()
        let reached = RecordingBody.Calls()
        let sent = RecordingBody.Calls()

        init() async {
            let volumeSchema = ToolCatalog.tools.first { $0.name == "set_volume" }!
            let contactSchema = ToolCatalog.tools.first { $0.name == "find_contact" }!
            await gateway.register(RecordingBody(calls: volume), schema: volumeSchema)
            await gateway.register(FindContactBody(calls: contacts), schema: contactSchema)
            await gateway.register(SendMessageBody(reached: reached, sent: sent))
        }
    }

    @Test("setting: on when unset, off only when stored false")
    func setting() throws {
        let suite = "jarvis-test-guided-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(GuidedTools.defaultsKey == "onDeviceGuidedTools")
        #expect(GuidedTools.enabled(in: nil))
        #expect(GuidedTools.enabled(in: defaults))
        defaults.set(false, forKey: GuidedTools.defaultsKey)
        #expect(!GuidedTools.enabled(in: defaults))
        #expect(!GuidedTools.enabledSetting(in: defaults))
        defaults.set(true, forKey: GuidedTools.defaultsKey)
        #expect(GuidedTools.enabled(in: defaults))
    }

    @Test("choice schema: an enum of the offered names plus none")
    func choiceSchema() throws {
        let schema = try GuidedTools.choiceSchema(["get_time", "set_volume"])
        let text = String(describing: schema)
        #expect(text.contains("get_time") && text.contains("set_volume") && text.contains("none"))
    }

    @Test("one tool: chosen, filled, run through the gateway; the reply session gets its result, no tools")
    func oneTool() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("set_volume"), .json(#"{"level": 80}"#), G.choose("none")]),
                      reply: [[.snapshot("Volume is at eighty, sir.")]], gateway: bodies.gateway)
        let outcome = await run.generate("turn the volume up to 80")
        #expect(outcome == .reply("Volume is at eighty, sir."))
        #expect(bodies.volume.args.map { $0["level"] } == [.int(80)])
        #expect(bodies.volume.origins == [.model(.local)])
        #expect(run.model.seen.sessionTools == [[]])
        let prompt = run.model.seen.prompts.first ?? ""
        #expect(prompt.hasPrefix("turn the volume up to 80"))
        #expect(prompt.contains("set_volume: Volume set, sir."))
        // The first prompt lists the offered tools; the third asks again after the result.
        #expect(run.guided.prompts.count == 3)
        #expect(run.guided.prompts[0].contains("- set_volume: "))
        #expect(run.guided.prompts[2].hasPrefix("set_volume returned: Volume set, sir."))
        #expect(run.logs.lines.contains("Local model: guided tool choice ran set_volume"))
    }

    @Test("none: the reply session gets no tools, so the choice stands")
    func none() async {
        let run = Run(G([G.choose("none")]), reply: [[.snapshot("Hello, sir.")]], offer: ["get_time", "set_volume"])
        let outcome = await run.generate("hello there")
        #expect(outcome == .reply("Hello, sir."))
        #expect(run.model.seen.sessionTools == [[]])
        #expect(run.model.seen.prompts == ["hello there"])
        #expect(run.guided.prompts.count == 1)
    }

    @Test("fallback: a guided error before any call means free-form tool calling")
    func fallback() async {
        let bodies = await Bodies()
        let run = Run(G([.fail(FakeModelError(description: "guardrail"))]),
                      reply: [[.call("set_volume", #"{"level": 30}"#), .snapshot("Volume set, sir.")]],
                      gateway: bodies.gateway)
        let outcome = await run.generate("volume to 30")
        #expect(outcome == .reply("Volume set, sir."))
        #expect(bodies.volume.args.map { $0["level"] } == [.int(30)])
        #expect(run.model.seen.sessionTools.first?.isEmpty == false)
        #expect(run.logs.lines.contains { $0.contains("guided tool choice failed (guardrail), free-form") })
    }

    @Test("fallback: the model without a guided session calls tools free-form")
    func noGuidedSession() async {
        let model = FakeLocalModel(attempts: [[.snapshot("Yes, sir.")]], offer: ["get_time"])
        let brain = LocalBrain(gateway: localTestGateway(), model: model, log: { _ in }, guided: { true })
        _ = await brain.generate(system: Self.system, user: "time", channel: .voice,
                                 turn: TurnContext(channel: .voice), sink: RecordingSink())
        #expect(model.seen.sessionTools == [["get_time"]])
    }

    @Test("setting off: the guided session is never asked")
    func off() async {
        let run = Run(G([G.choose("set_volume")]), offer: ["set_volume"], enabled: false)
        _ = await run.generate("volume up")
        #expect(run.guided.prompts.isEmpty)
        #expect(run.model.seen.sessionTools == [["set_volume"]])
    }

    @Test("chain: find_contact then send_message, and send_message is still gated by confirmation")
    func chain() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("find_contact"), .json(#"{"name": "Priya"}"#),
                         G.choose("send_message"), .json(#"{"to": "+44 7700 900123", "text": "running late"}"#),
                         G.choose("none")]),
                      reply: [[.snapshot("Message sent to Priya, sir.")]], gateway: bodies.gateway)
        let outcome = await run.generate("find Priya then text her that I'm running late")
        #expect(bodies.contacts.args.count == 1)
        // The body asked for confirmation; nothing was sent.
        #expect(bodies.reached.args.count == 1)
        #expect(bodies.sent.args.isEmpty)
        let runs = await run.turn.summary().toolRuns
        #expect(runs.map(\.name) == ["find_contact", "send_message"])
        #expect(runs.map(\.outcome) == [.ran, .gated])
        // A gated call ends the chain: the fifth reply (none) is never asked for.
        #expect(run.guided.prompts.count == 4)
        #expect(run.guided.prompts[2].hasPrefix("find_contact returned: \(FindContactBody.reply)"))
        // Swift's confirmation reply, not the model's "sent".
        #expect(outcome == .reply(ReplyCheck.needsConfirmation("Send Priya a message")))
    }

    @Test("safety: a tainted turn blocks the executor tool the guided step chose")
    func taint() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("send_message"), .json(#"{"to": "Priya", "text": "hi"}"#), G.choose("none")]),
                      reply: [[.snapshot("Message sent, sir.")]], gateway: bodies.gateway, tainted: true)
        let outcome = await run.generate("text Priya hi")
        #expect(bodies.reached.args.isEmpty)
        #expect(bodies.sent.args.isEmpty)
        let runs = await run.turn.summary().toolRuns
        #expect(runs.map(\.outcome) == [.blockedTaint])
        #expect(outcome == .reply(ReplyCheck.taintBlocked))
        #expect(await run.sink.sentences == [ReplyCheck.taintBlocked])
    }

    @Test("limit: at most three guided calls per turn")
    func maxSteps() async {
        let bodies = await Bodies()
        var script: [FakeGuidedSession.Reply] = []
        for level in [10, 20, 30, 40] {
            script += [G.choose("set_volume"), .json(#"{"level": \#(level)}"#)]
        }
        let run = Run(G(script), reply: [[.snapshot("Volume set, sir.")]], gateway: bodies.gateway)
        _ = await run.generate("volume 10 20 30 40")
        #expect(bodies.volume.args.count == GuidedTools.maxSteps)
        #expect(run.guided.prompts.count == 2 * GuidedTools.maxSteps)
    }

    @Test("repeat: the same call twice ends the chain without running it again")
    func repeated() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("set_volume"), .json(#"{"level": 50}"#),
                         G.choose("set_volume"), .json(#"{"level": 50}"#)]),
                      reply: [[.snapshot("Volume set, sir.")]], gateway: bodies.gateway)
        _ = await run.generate("volume 50")
        #expect(bodies.volume.args.count == 1)
    }

    @Test("an error after a call keeps it; free-form never runs it again")
    func errorAfterCall() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("set_volume"), .json(#"{"level": 60}"#), .fail(FakeModelError(description: "x"))]),
                      reply: [[.snapshot("Volume is at sixty, sir.")]], gateway: bodies.gateway)
        let outcome = await run.generate("volume 60")
        #expect(outcome == .reply("Volume is at sixty, sir."))
        #expect(bodies.volume.args.count == 1)
        #expect(run.model.seen.sessionTools == [[]])
    }

    @Test("a name that was not offered is treated as none")
    func notOffered() async {
        let run = Run(G([G.choose("run_command")]), offer: ["get_time"])
        _ = await run.generate("what time")
        #expect(run.guided.prompts.count == 1)
        #expect(run.model.seen.sessionTools == [[]])
    }

    @Test("cancel: a Stop after the arguments are generated never calls the tool")
    func cancelAfterArguments() async {
        let bodies = await Bodies()
        let run = Run(G([G.choose("set_volume"), .jsonThenCancel(#"{"level": 90}"#)]), gateway: bodies.gateway)
        let outcome = await Task { await run.generate("volume 90") }.value
        #expect(outcome == .failed(LocalBrain.errorReply))
        #expect(bodies.volume.args.isEmpty)
        #expect(await run.turn.summary().toolRuns.isEmpty)
        #expect(run.model.seen.sessions == 0)
    }

    @Test("cancel: a CancellationError from the choice ends the turn, with no free-form fallback")
    func cancelNoFallback() async {
        let bodies = await Bodies()
        let run = Run(G([.fail(CancellationError())]),
                      reply: [[.call("set_volume", #"{"level": 20}"#), .snapshot("Volume set, sir.")]],
                      gateway: bodies.gateway)
        let outcome = await run.generate("volume 20")
        #expect(outcome == .failed(LocalBrain.errorReply))
        #expect(bodies.volume.args.isEmpty)
        #expect(run.model.seen.sessions == 0)
        #expect(!run.logs.lines.contains { $0.contains("free-form") })
    }
}
