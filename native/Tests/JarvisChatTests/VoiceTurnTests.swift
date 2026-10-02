import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisChat
import JarvisTools
import Testing

/// M9a part 4: what push-to-talk heard goes out as a turn on the voice channel, and its reply is
/// always spoken, whatever the Speak replies toggle says.
@MainActor
@Suite("M9 voice turns", .timeLimit(.minutes(1)))
struct VoiceTurnTests {
    @Test("the transcript is sent on the voice channel and shown; the draft and the typed acknowledgement are left alone")
    func sendsVoice() async {
        let fake = FakeCoordinator(answering: .reply("It's ten past three, sir."))
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        var sent: [String] = []
        var finished: [TurnSummary] = []
        model.onSend = { text, _ in sent.append(text) }
        model.onReplyFinished = { _, turn in finished.append(turn) }
        model.draft.text = "half-typed note"
        await model.sendVoice("  What's the time?  ")?.value
        let inputs = await fake.inputs
        #expect(inputs.map(\.text) == ["What's the time?"])
        #expect(inputs.map(\.channel) == [.voice])
        #expect(inputs.map(\.pasted) == [false])
        #expect(inputs.map(\.addsContext) == [false])
        #expect(model.messages.map(\.text) == ["What's the time?", "It's ten past three, sir."])
        #expect(model.messages.map(\.role) == [.user, .assistant])
        #expect(finished.map(\.channel) == [.voice])
        #expect(model.draft.text == "half-typed note")
        #expect(sent.isEmpty)
    }

    @Test("nothing to send sends nothing, and before the brain starts nothing is sent")
    func nothing() async {
        let fake = FakeCoordinator(answering: .reply("x"))
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        #expect(model.sendVoice(" \n ") == nil)
        #expect(await fake.inputs.isEmpty)
        #expect(ChatViewModel().sendVoice("hello") == nil)
    }

    @Test("refused as busy, the transcript goes into the composer, in front of what was typed")
    func busy() async {
        let model = ChatViewModel(submitter: FakeCoordinator(answering: .busy), minimumGap: .zero)
        model.draft.text = "typed"
        await model.sendVoice("turn the volume down")?.value
        #expect(model.busy)
        #expect(model.draft.text == "turn the volume down typed")
        #expect(model.messages.isEmpty)
    }

    @Test("sent while a reply is being written, it stops that reply and follows it")
    func interrupts() async {
        let gate = Gate()
        let fake = FakeCoordinator { input, sink in
            if input.text == "first" {
                await sink.delta("Part of a long ")
                await gate.park()
                return .reply("Part of a long answer.")
            }
            return .reply("Second answer, sir.")
        }
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        model.draft.text = "first"
        let first = model.send()
        await gate.waitUntilParked()
        let second = model.sendVoice("never mind, what's the weather?")
        await gate.open()
        await first?.value
        await second?.value
        let inputs = await fake.inputs
        #expect(inputs.map(\.channel) == [.text, .voice])
        #expect(inputs.last?.addsContext == false)
        #expect(model.messages.last?.text == "Second answer, sir.")
        #expect(model.messages.contains { $0.stopped })
    }

    @Test("a voice reply is spoken with the toggle off, whatever its length, and is not a typed reply spoken")
    func alwaysSpoken() async throws {
        let research = ResearchRecorder()
        var spoken: [String] = []
        let long = String(repeating: "A long spoken answer, sir. ", count: 80)        // 2160 scalars
        for text in ["Done, sir.", long] {
            let reply = ChatMessage(role: .assistant, text: text, phase: .finished)
            let turn = await TurnContext(channel: .voice).summary()
            var context: SpeakContext?
            try SpeakPolicyTests.withDefaults { defaults in
                let toggle = SpeakRepliesToggle(defaults: defaults)
                toggle.isOn = false
                context = SpeakReplies.context(for: reply, turn: turn, toggle: toggle, chatWindowIsKey: true,
                                               userIdleSeconds: 0, ttsBackend: "f5")
            }
            let said = SpeakReplies.replyFinished(reply, context: try #require(context), research: research,
                                                  speaker: { text, _ in spoken.append(text) }, log: { _ in })
            #expect(said)
        }
        #expect(spoken == ["Done, sir.", long])
        #expect(research.counts.isEmpty)
        // A blank one, or no speaker, says nothing.
        let blank = ChatMessage(role: .assistant, text: "  ", phase: .finished)
        let turn = await TurnContext(channel: .voice).summary()
        let context = SpeakContext(chatWindowIsKey: false, speakToggleOn: false, userIdleSeconds: 0,
                                   voiceConversationActive: false, replyCharCount: 2, turn: turn, ttsBackend: "f5")
        let blankSaid = SpeakReplies.replyFinished(blank, context: context, research: research,
                                                   speaker: { text, _ in spoken.append(text) }, log: { _ in })
        let noSpeakerSaid = SpeakReplies.replyFinished(Self.done, context: context, research: research, speaker: nil,
                                                       log: { _ in })
        #expect(!blankSaid && !noSpeakerSaid)
        #expect(spoken.count == 2)
    }

    @Test("a typed reply with the toggle off is still not spoken")
    func typedStillAsks() async throws {
        let research = ResearchRecorder()
        var spoken: [String] = []
        let context = try await SpeakPolicyTests.context(toggle: false)
        let said = SpeakReplies.replyFinished(Self.done, context: context, research: research,
                                              speaker: { text, _ in spoken.append(text) }, log: { _ in })
        #expect(!said)
        #expect(spoken.isEmpty)
    }

    static let done = ChatMessage(role: .assistant, text: "Done, sir.", phase: .finished)

    // MARK: - Part 6: a spoken confirmation passes the owner check (D-41)

    /// A coordinator that confirms as TurnCoordinator does: typed turns through the text port,
    /// spoken ones through the voice port with the owner check.
    static func confirming(_ gate: ConfirmationGate, _ authenticator: any TextConfirmAuthenticator) -> FakeCoordinator {
        FakeCoordinator { input, sink in
            let turn = TurnContext(channel: input.channel)
            let port: InputPort = input.channel == .text ? .text(authenticator: authenticator)
                : .voice(confirming: .ownerCheck(authenticator))
            if case .handled(let result) = await gate.consume(Py.strip(input.text), via: port, runIn: turn) {
                if !result.isEmpty { await sink.sentence(result) }
                return .confirmation(result)
            }
            await sink.sentence("It is three o'clock, sir.")
            return .reply("It is three o'clock, sir.")
        }
    }

    static func card(_ authenticator: FakeTextAuthenticator, actions: ActionLog)
        async -> (ChatViewModel, ConfirmationGate, FakeCoordinator) {
        let gate = ConfirmationGate()
        let coordinator = Self.confirming(gate, authenticator)
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.watchConfirmations(gate, authenticator: authenticator)
        await gate.stash(desc: "delete test.txt permanently", action: { await actions.ran(); return "Done, sir." },
                         turn: TurnContext(channel: .text))
        _ = await eventually { model.pending != nil }
        return (model, gate, coordinator)
    }

    @Test("a spoken yes on a pending card asks for the owner check, and the chat says so", arguments: [true, false])
    func spokenYes(approve: Bool) async {
        let authenticator = FakeTextAuthenticator(answer: approve)
        let actions = ActionLog()
        let (model, gate, coordinator) = await Self.card(authenticator, actions: actions)
        await model.sendVoice("Yes")?.value
        #expect(await coordinator.inputs.map(\.channel) == [.voice])
        #expect(authenticator.reasons == ["delete test.txt permanently"])
        #expect(model.messages.map(\.text) == ["Yes", TextConfirmation.spokenNote,
                                                approve ? "Done, sir." : VoiceConfirmation.notConfirmed])
        #expect(model.messages[1].role == .system)
        #expect(TextConfirmation.spokenNote == "Confirm in the chat with Touch ID")
        #expect(await actions.runs == (approve ? 1 : 0))
        // Denied: the card is back until its deadline.
        #expect(await eventually { (model.pending != nil) == !approve })
        #expect((await gate.pending != nil) == !approve)
    }

    @Test("with no owner check on this Mac, a spoken yes is refused as a typed one is, and the card stays")
    func spokenYesUnavailable() async {
        let authenticator = FakeTextAuthenticator(available: false, answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = await Self.card(authenticator, actions: actions)
        #expect(model.sendVoice("go ahead") == nil)
        #expect(model.messages.map(\.text) == ["go ahead", TextConfirmation.cannotVerifySpoken])
        #expect(await coordinator.inputs.isEmpty)
        #expect(authenticator.reasons.isEmpty)
        #expect(await actions.runs == 0)
        #expect(model.pending != nil)
        #expect(await gate.pending != nil)
    }

    @Test("a spoken no on a pending card declines it with no check and no note")
    func spokenNo() async {
        let authenticator = FakeTextAuthenticator(answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = await Self.card(authenticator, actions: actions)
        await model.sendVoice("no")?.value
        #expect(await coordinator.inputs.map(\.text) == ["no"])
        #expect(authenticator.reasons.isEmpty)
        #expect(model.messages.map(\.text) == ["no", "It is three o'clock, sir."])
        #expect(await actions.runs == 0)
        #expect(await gate.pending == nil)
        #expect(await eventually { model.pending == nil })
    }
}
