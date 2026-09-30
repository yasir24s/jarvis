import Foundation
import JarvisBrain
import JarvisChat
import JarvisTools
import Testing

/// ChatViewModel (plan §3.12, §3.5, D-10, X-8) driven by a fake coordinator; nothing here
/// starts a brain, a window or the app.
@Suite("M4 chat view model (plan 3.12)", .timeLimit(.minutes(1)))
@MainActor
struct ChatViewModelTests {
    static let markdownReply = "It is **three** o'clock, sir."

    @Test("streamed deltas become one live row, then a finished markdown row")
    func streamedDeltasBecomeOneLiveRowThenAFinishedMarkdownRow() async throws {
        let gate = Gate()
        let fake = FakeCoordinator { _, sink in
            await sink.delta("It is **three** ")
            await sink.delta("o'clock, sir.")
            await sink.sentence("It is **three** o'clock, sir.")
            await gate.park()
            return .reply("It is **three** o'clock, sir.")
        }
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        model.draft.text = "what time is it"
        let turn = try #require(model.send())
        await gate.waitUntilParked()

        #expect(model.messages.count == 2)
        let user = try #require(model.messages.first)
        #expect(user.role == .user && user.text == "what time is it" && user.phase == .finished)
        let live = try #require(model.messages.last)
        #expect(live.role == .assistant)
        #expect(live.phase == .streaming)
        #expect(live.text == Self.markdownReply)
        #expect(!live.rendersMarkdown)
        #expect(model.responding)
        #expect(model.draft == ComposerDraft())

        await gate.open()
        await turn.value

        #expect(model.messages.count == 2)
        let done = try #require(model.messages.last)
        #expect(done.id == live.id)
        #expect(done.phase == .finished)
        #expect(done.rendersMarkdown)
        #expect(done.text == Self.markdownReply)
        #expect(String(ChatMarkdown.attributed(done.text).characters) == "It is three o'clock, sir.")
        #expect(!model.responding)
        #expect(!model.busy)
    }

    @Test("deltas inside one update gap are held back, then shown together")
    func deltasAreCoalesced() async throws {
        let gate = Gate()
        let fake = FakeCoordinator { _, sink in
            await sink.delta("It is ")
            await sink.delta("three ")
            await sink.delta("o'clock, sir.")
            await gate.park()
            return .reply("It is three o'clock, sir.")
        }
        // A gap far longer than the test: after the first delta, nothing more can reach the
        // row until the turn ends.
        let model = ChatViewModel(submitter: fake, minimumGap: .seconds(600))
        model.draft.text = "what time is it"
        let turn = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.messages.last?.text == "It is ")
        #expect(model.messages.last?.phase == .streaming)

        await gate.open()
        await turn.value
        #expect(model.messages.last?.text == "It is three o'clock, sir.")
        #expect(model.messages.last?.phase == .finished)
    }

    @Test("a pasted draft reaches the coordinator with pasted: true, a typed one with false",
          arguments: [true, false])
    func pasteFlagReachesTheCoordinator(pasted: Bool) async throws {
        let fake = FakeCoordinator(answering: .reply("Done, sir."))
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "summarise this note for Robin"
        if pasted { model.notePaste() }
        await model.send()?.value
        #expect(await fake.inputs == [UserInput(text: "summarise this note for Robin", channel: .text, pasted: pasted)])
    }

    @Test("the paste flag covers only the next input")
    func pasteFlagIsUsedOnce() async throws {
        let fake = FakeCoordinator(answering: .reply("Done, sir."))
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "a note from Morgan"
        model.notePaste()
        await model.send()?.value
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(await fake.inputs.map(\.pasted) == [true, false])
        #expect(model.draft == ComposerDraft())
    }

    @Test(".busy keeps the draft and its paste flag, withdraws the rows, and shows the busy line")
    func busyKeepsTheDraft() async throws {
        let fake = FakeCoordinator(answering: .busy)
        let model = ChatViewModel(submitter: fake, lastBackend: { "claude" })
        model.draft.text = "what time is it"
        model.notePaste()
        await model.send()?.value
        #expect(model.busy)
        #expect(ChatViewModel.busyNotice == "JARVIS is busy — voice turn in progress.")
        #expect(model.draft == ComposerDraft(text: "what time is it", pasted: true))
        #expect(model.messages.isEmpty)
        #expect(!model.responding)
        #expect(model.lastBackend == nil)
        #expect(await fake.inputs.count == 1)
    }

    @Test("the next send that runs clears the busy line")
    func busyClearsOnTheNextSend() async throws {
        let outcomes = Outcomes([.busy, .reply("It is three o'clock, sir.")])
        let fake = FakeCoordinator(outcomes)
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(model.busy)
        await model.send()?.value
        #expect(!model.busy)
        #expect(model.messages.map(\.text) == ["what time is it", "It is three o'clock, sir."])
        #expect(model.draft == ComposerDraft())
    }

    @Test("empty input is ignored", arguments: ["", "   ", "\n\t \n"])
    func emptyInputIsIgnored(text: String) async throws {
        let fake = FakeCoordinator(answering: .reply("Done, sir."))
        let model = ChatViewModel(submitter: fake)
        model.draft.text = text
        #expect(model.send() == nil)
        #expect(model.messages.isEmpty)
        #expect(model.draft.text == text)
        #expect(!model.responding)
        #expect(await fake.inputs.isEmpty)
    }

    @Test("Return during this window's own turn neither sends nor queues the draft (D-10)")
    func secondSendDuringATurnIsRefused() async throws {
        let gate = Gate()
        let fake = FakeCoordinator { _, _ in
            await gate.park()
            return .reply("Done, sir.")
        }
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "first"
        let turn = try #require(model.send())
        await gate.waitUntilParked()
        model.draft.text = "second"
        #expect(model.send() == nil)
        #expect(model.draft.text == "second")

        await gate.open()
        await turn.value
        #expect(await fake.inputs.map(\.text) == ["first"])
        #expect(model.draft.text == "second")
        #expect(model.messages.map(\.text) == ["first", "Done, sir."])
    }

    @Test("a stream that fails finishes with the reply the turn returned, not the partial text")
    func failedStreamShowsTheReturnedReply() async throws {
        let fake = FakeCoordinator { _, sink in
            await sink.delta("The time is")
            await sink.sentence(LocalBrain.errorReply)
            return .reply(LocalBrain.errorReply)
        }
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(model.messages.map(\.text) == ["what time is it", LocalBrain.errorReply])
        #expect(model.messages.allSatisfy { $0.phase == .finished })
        #expect(!model.responding)
    }

    @Test("Claude's nil path: the retracted message's row is struck through, then the local model's reply follows")
    func retractedClaudeThenLocalReply() async throws {
        let fake = FakeCoordinator { _, sink in
            await sink.delta("I can't help with")
            await sink.retracted(messageID: "msg_01")
            await sink.delta("It is three o'clock, sir.")
            await sink.sentence("It is three o'clock, sir.")
            return .reply("It is three o'clock, sir.")
        }
        let model = ChatViewModel(submitter: fake, minimumGap: .zero)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(model.messages.map(\.text) == ["what time is it", "I can't help with", "It is three o'clock, sir."])
        #expect(model.messages.map(\.retracted) == [false, true, false])
        #expect(model.messages.allSatisfy { $0.phase == .finished })
        #expect(!model.messages[1].rendersMarkdown)
    }

    @Test("a turn that returns nothing keeps the user row and leaves no empty assistant row")
    func emptyReplyLeavesNoAssistantRow() async throws {
        let fake = FakeCoordinator(answering: .reply(""))
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(model.messages.map(\.role) == [.user])
        #expect(model.messages.allSatisfy { $0.phase == .finished })
        #expect(!model.responding)
        #expect(!model.busy)
    }

    @Test("a confirmation or fast-path result streams as one sentence and finishes as the row",
          arguments: [TurnOutcome.confirmation("Done, sir."), .fastPath("Done, sir.")])
    func sentenceOnlyPaths(outcome: TurnOutcome) async throws {
        let gate = Gate()
        let fake = FakeCoordinator { _, sink in
            await sink.sentence("Done, sir.")
            await gate.park()
            return outcome
        }
        let model = ChatViewModel(submitter: fake)
        model.draft.text = "yes"
        let turn = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.messages.last?.text == "Done, sir.")
        #expect(model.messages.last?.phase == .streaming)

        await gate.open()
        await turn.value
        #expect(model.messages.map(\.text) == ["yes", "Done, sir."])
        #expect(model.messages.last?.phase == .finished)
    }

    @Test("before the brain starts, Return keeps the draft; once connected, turns run")
    func connectAfterStart() async throws {
        let model = ChatViewModel()
        model.draft.text = "what time is it"
        #expect(!model.isConnected)
        #expect(model.send() == nil)
        #expect(model.draft.text == "what time is it")
        #expect(model.messages.isEmpty)
        #expect(model.backendLine == "Last backend: —")

        let fake = FakeCoordinator(answering: .reply("It is three o'clock, sir."))
        model.connect(fake, lastBackend: { LocalBrain.backendName })
        await model.send()?.value
        #expect(model.isConnected)
        #expect(model.messages.map(\.text) == ["what time is it", "It is three o'clock, sir."])
        #expect(model.backendLine == "Last backend: \(LocalBrain.backendName)")
    }

    @Test("when the brain does not start, one system row says chat is off and names the log")
    func startFailedShowsOneRow() async throws {
        let model = ChatViewModel()
        model.startFailed(log: "~/jarvis/logs/jarvis.log")
        model.startFailed(log: "~/jarvis/logs/jarvis.log")
        #expect(model.messages.map(\.role) == [.system])
        #expect(model.messages.map(\.text)
                == ["Chat is off: JARVIS could not start its brain. The reason is in the log, ~/jarvis/logs/jarvis.log."])
        #expect(model.messages.allSatisfy { $0.phase == .finished && !$0.rendersMarkdown })
        model.draft.text = "what time is it"
        #expect(model.send() == nil)
        #expect(model.draft.text == "what time is it")
        #expect(model.messages.count == 1)
    }

    @Test("the speak hook sees each finished reply once, with its turn, and nothing for a refused submit")
    func speakHookSeesFinishedReplies() async throws {
        let outcomes = Outcomes([.reply("It is three o'clock, sir."), .busy])
        let fake = FakeCoordinator(outcomes)
        let model = ChatViewModel(submitter: fake)
        var seen: [ChatMessage] = []
        var turns: [TurnSummary] = []
        model.onReplyFinished = { message, turn in
            seen.append(message)
            turns.append(turn)
        }
        model.draft.text = "what time is it"
        await model.send()?.value
        model.draft.text = "and the date"
        await model.send()?.value
        #expect(seen.map(\.text) == ["It is three o'clock, sir."])
        #expect(seen.allSatisfy { $0.role == .assistant && $0.phase == .finished })
        var taken: [UUID] = []
        for turn in await fake.turns { taken.append(await turn.turnID) }
        #expect(taken.count == 1)
        #expect(turns.map(\.turnID) == taken)
        #expect(turns.map(\.channel) == [.text])
    }

    @Test("a submit the coordinator refuses as .busy shows no row, even while it is being refused")
    func busyNeverShowsARow() async throws {
        let model = ChatViewModel()
        let rowsWhileRefused = Snapshot<[String]>()
        let fake = FakeCoordinator(refusing: { _ in
            await rowsWhileRefused.set(await model.messages.map(\.text))
            return .busy
        }) { _, _ in .reply("never sent") }
        model.connect(fake, lastBackend: nil)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(await rowsWhileRefused.value == [])
        #expect(model.messages.isEmpty)
        #expect(model.busy)
        #expect(model.draft.text == "what time is it")
        #expect(await fake.turns.isEmpty)
    }

    @Test("the rows appear once the coordinator takes the turn, before anything streams")
    func rowsAppearWhenTheTurnIsTaken() async throws {
        let gate = Gate()
        let model = ChatViewModel()
        let fake = FakeCoordinator { _, _ in
            await gate.park()
            return .reply("Done, sir.")
        }
        model.connect(fake, lastBackend: nil)
        model.draft.text = "what time is it"
        let turn = try #require(model.send())
        #expect(model.messages.isEmpty)
        #expect(model.responding)
        #expect(model.draft == ComposerDraft())
        await gate.waitUntilParked()
        #expect(model.messages.map(\.text) == ["what time is it", ""])
        #expect(model.messages.map(\.phase) == [.finished, .streaming])
        await gate.open()
        await turn.value
        #expect(model.messages.map(\.text) == ["what time is it", "Done, sir."])
    }
}
