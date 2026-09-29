import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// T3.6 (plan M02-M04 §3.8 "Semantics"; jarvis.py 5076-5120): LocalBrain against
/// FakeLocalModel. The fake's tool calls go through real DynamicTools and a real gateway.
@Suite("M3 local model: LocalBrain streaming, retries, tool limit and errors", .timeLimit(.minutes(1)))
struct LocalBrainTests {
    static let system = "You are a test assistant."
    static let user = "what time is it"

    /// One brain, its fake model and its turn.
    struct Run {
        let model: FakeLocalModel
        let sink = RecordingSink()
        let logs = LogRecorder()
        let turn: TurnContext
        let brain: LocalBrain

        init(_ model: FakeLocalModel, channel: Channel = .voice, gateway: ToolGateway = localTestGateway()) {
            self.model = model
            turn = TurnContext(channel: channel)
            brain = LocalBrain(gateway: gateway, model: model, log: logs.function)
        }

        func generate(channel: Channel = .voice) async -> LocalOutcome {
            await brain.generate(system: LocalBrainTests.system, user: LocalBrainTests.user, channel: channel,
                                 turn: turn, sink: sink)
        }
    }

    @Test("names: backend, counter key and the fixed replies")
    func names() throws {
        #expect(LocalBrain.backendName == "local (apple-foundation-model)")
        // The key the REAL `_set_backend` bumps for this name (m3_backend_key). Python's
        // `\W+` also replaces the closing parenthesis, so the key ends in "_".
        let golden = try #require(try Golden.cases("m3_backend_key").first {
            $0.input.string("name") == LocalBrain.backendName
        })
        #expect(BackendReporter.counterKey(LocalBrain.backendName) == golden.expected.string("key"))
        #expect(LocalBrain.emptyReply == "Sorry, sir — could you say that again?")
        #expect(LocalBrain.stuckReply == "I got stuck working through that, sir.")
        #expect(LocalBrain.errorReply == "My local reasoning core had an error, sir.")
    }

    @Test("options: temperature 0.6, 200 tokens for voice, 600 for text")
    func options() async {
        #expect(LocalBrain.options(for: .voice) == GenerationOptions(temperature: 0.6, maximumResponseTokens: 200))
        #expect(LocalBrain.options(for: .text) == GenerationOptions(temperature: 0.6, maximumResponseTokens: 600))
        let voice = Run(FakeLocalModel(attempts: [[.snapshot("Yes, sir.")]]))
        _ = await voice.generate(channel: .voice)
        #expect(voice.model.seen.options.map(\.maximumResponseTokens) == [200])
        let text = Run(FakeLocalModel(attempts: [[.snapshot("Yes, sir.")]]), channel: .text)
        _ = await text.generate(channel: .text)
        #expect(text.model.seen.options.map(\.maximumResponseTokens) == [600])
        #expect(text.model.seen.options.map(\.temperature) == [0.6])
    }

    @Test("cumulative snapshots become deltas, then sentences as they pop")
    func streams() async {
        let run = Run(FakeLocalModel(attempts: [[
            .snapshot("It is"), .snapshot("It is"), .snapshot("It is noon, sir. Anything"),
            .snapshot("It is noon, sir. Anything else?"),
        ]]))
        let outcome = await run.generate()
        #expect(outcome == .reply("It is noon, sir. Anything else?"))
        #expect(await run.sink.deltas == ["It is", " noon, sir. Anything", " else?"])
        #expect(await run.sink.sentences == ["It is noon, sir.", "Anything else?"])
        #expect(run.model.seen.sessions == 1)
        #expect(run.model.seen.prompts == [Self.user])
        #expect(run.model.seen.instructions == [Self.system])
        #expect(run.logs.lines.isEmpty)
    }

    @Test("the returned reply is Python's join of the sentences, stripped")
    func joinedReply() async {
        let run = Run(FakeLocalModel(attempts: [[.snapshot("  One.  Two!\n\nThree  ")]]))
        let outcome = await run.generate()
        let sentences = await run.sink.sentences
        #expect(outcome == .reply(Py.strip(sentences.joined(separator: " "))))
        #expect(sentences == SentenceSplitter.pop("  One.  Two!\n\nThree  ", force: true).sentences)
    }

    @Test("an empty reply is retried in the same session, then succeeds")
    func emptyThenReply() async {
        let run = Run(FakeLocalModel(attempts: [[.snapshot("  ")], [.snapshot("Done, sir.")]]))
        let outcome = await run.generate()
        #expect(outcome == .reply("Done, sir."))
        #expect(run.model.seen.sessions == 1)
        #expect(run.model.seen.prompts == [Self.user, Self.user])
        #expect(run.logs.lines == ["Empty model response — retry 1."])
        #expect(await run.sink.sentences == ["Done, sir."])
    }

    @Test("two retries, then Python's fixed reply")
    func emptyThreeTimes() async {
        let run = Run(FakeLocalModel(attempts: [[], [.snapshot("")], [.snapshot(" \n ")], [.snapshot("unused")]]))
        let outcome = await run.generate()
        #expect(outcome == .reply(LocalBrain.emptyReply))
        #expect(run.model.seen.prompts.count == 3)
        #expect(run.model.seen.sessions == 1)
        #expect(run.logs.lines == ["Empty model response — retry 1.", "Empty model response — retry 2."])
        #expect(await run.sink.sentences == [LocalBrain.emptyReply])
    }

    @Test("ten tool calls are fine; the reply after them stands")
    func tenCalls() async {
        let steps = Array(repeating: FakeStep.call("get_time", "{}"), count: 10) + [.snapshot("It is noon, sir.")]
        let run = Run(FakeLocalModel(attempts: [steps]))
        let outcome = await run.generate()
        #expect(outcome == .reply("It is noon, sir."))
        #expect(run.model.seen.toolOutputs == Array(repeating: GuardStrings.unknownTool("get_time"), count: 10))
        let runs = await run.turn.summary().toolRuns
        #expect(runs.count == 10)
        #expect(runs.allSatisfy { $0.origin == .model(.local) })
    }

    @Test("more than ten tool calls: the eleventh does not run, and Python's stuck reply")
    func stuck() async {
        let steps = Array(repeating: FakeStep.call("get_time", "{}"), count: 12) + [.snapshot("never")]
        let run = Run(FakeLocalModel(attempts: [steps]))
        let outcome = await run.generate()
        #expect(outcome == .reply(LocalBrain.stuckReply))
        #expect(await run.turn.summary().toolRuns.count == 10)
        #expect(await run.sink.sentences == [LocalBrain.stuckReply])
        #expect(await run.sink.deltas.isEmpty)
        #expect(run.logs.lines == ["Local model: stopped after 10 tool calls this turn"])
    }

    @Test("the tool limit counts across empty-reply retries")
    func limitSpansRetries() async {
        let six = Array(repeating: FakeStep.call("get_time", "{}"), count: 6)
        let run = Run(FakeLocalModel(attempts: [six, six]))
        let outcome = await run.generate()
        #expect(outcome == .reply(LocalBrain.stuckReply))
        #expect(await run.turn.summary().toolRuns.count == 10)
    }

    @Test("an error fails the turn, logs it, and says Python's error reply")
    func error() async {
        let run = Run(FakeLocalModel(attempts: [[.snapshot("Checking now, sir. The"),
                                                 .fail(FakeModelError(description: "decoding failed"))]]))
        let outcome = await run.generate()
        #expect(outcome == .failed(LocalBrain.errorReply))
        #expect(run.logs.lines == ["Brain error: decoding failed"])
        #expect(await run.sink.sentences == ["Checking now, sir.", LocalBrain.errorReply])
        #expect(run.model.seen.prompts.count == 1)
    }

    @Test("a tool that throws for another reason is an error, not the stuck reply")
    func toolError() async {
        let run = Run(FakeLocalModel(attempts: [[.call("not_a_catalog_tool", "{}")]]))
        let outcome = await run.generate()
        #expect(outcome == .failed(LocalBrain.errorReply))
        #expect(run.logs.lines == ["Brain error: tool not_a_catalog_tool not offered"])
    }

    @Test("an unavailable model fails the turn with its reason logged, and no session")
    func unavailable() async {
        let run = Run(FakeLocalModel(reason: "appleIntelligenceNotEnabled", attempts: [[.snapshot("never")]]))
        let outcome = await run.generate()
        #expect(outcome == .failed(LocalBrain.errorReply))
        #expect(run.logs.lines == ["Brain error: the on-device model is unavailable (appleIntelligenceNotEnabled)"])
        #expect(run.model.seen.sessions == 0)
        #expect(run.model.seen.offeredTools.isEmpty)
        #expect(await run.sink.sentences == [LocalBrain.errorReply])
    }

    @Test("context overflow is named in the log, in either SDK spelling")
    func contextOverflow() {
        let old = LanguageModelSession.GenerationError.exceededContextWindowSize(.init(debugDescription: "full"))
        #expect(LocalBrain.describe(old).hasPrefix("context size exceeded: "))
        if #available(macOS 27, *) {
            let new = LanguageModelError.contextSizeExceeded(
                .init(contextSize: 4096, tokenCount: 5000, debugDescription: "full"))
            #expect(LocalBrain.describe(new).hasPrefix("context size exceeded: "))
        }
        #expect(LocalBrain.describe(FakeModelError(description: "x")) == "x")
    }

    @Test("one session per turn, and it is released when the turn ends")
    func sessionPerTurn() async throws {
        let model = FakeLocalModel(attempts: [[.snapshot("One, sir.")]])
        let run = Run(model)
        _ = await run.generate()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while model.seen.lastSessionAlive, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.seen.lastSessionAlive)
        _ = await run.generate()
        #expect(model.seen.sessions == 2)
        #expect(model.seen.offeredTools.count == 2)
    }

    // MARK: - SnapshotDiff

    @Test("snapshot diffing: extensions, repeats, a new message, a combining mark")
    func snapshotDiff() {
        var diff = SnapshotDiff()
        #expect(diff.delta(to: "") == "")
        #expect(diff.delta(to: "Hel") == "Hel")
        #expect(diff.delta(to: "Hello") == "lo")
        #expect(diff.delta(to: "Hello") == "")
        // A snapshot that does not extend the last yields what follows the shared part.
        #expect(diff.delta(to: "Help") == "p")
        #expect(diff.delta(to: "It is") == "It is")
        // Compared by scalar: "e" then "e" + U+0301 is a delta of just the mark.
        var mark = SnapshotDiff()
        #expect(mark.delta(to: "cafe") == "cafe")
        #expect(mark.delta(to: "cafe\u{301}").unicodeScalars.map(\.value) == [0x301])
    }
}
