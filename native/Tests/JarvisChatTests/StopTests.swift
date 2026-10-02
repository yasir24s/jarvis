import Foundation
import JarvisBrain
@testable import JarvisChat
import JarvisTools
import Testing

/// A submitter that parks before it takes the turn, so Stop can come first.
actor ParkBeforeAccept: TurnSubmitting {
    let gate: Gate

    init(gate: Gate) {
        self.gate = gate
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        await gate.park()
        let turn = TurnContext(channel: input.channel)
        await accepted?(turn)
        await sink.delta("Should not show")
        await turn.close()
        return .reply("Should not show")
    }
}

/// UI1 part 4: Stop in the chat, with fakes. A stopped reply keeps what was shown, marked
/// stopped, takes nothing more, is never spoken, and its turn is closed and cancelled; speech
/// stops; a message sent while he replies follows the stopped turn as added context.
@Suite("UI1 stop and add context", .serialized)
@MainActor
struct StopTests {
    @Test func stopKeepsWhatWasShownAndSpeaksNothing() async throws {
        let gate = Gate()
        let sawCancel = Snapshot<Bool>()
        let coordinator = FakeCoordinator { _, sink in
            await sink.delta("Partial ans")
            await gate.park()
            await sawCancel.set(Task.isCancelled)
            await sink.delta("wer, sent after the stop")
            await sink.sentence("A sentence after the stop.")
            return .reply("Partial answer, sent after the stop")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        let order = Order()
        model.onReplyFinished = { message, _ in order.add("spoken \(message.text)") }
        model.onStopSpeech = { order.add("speech stopped") }
        model.onTurnEnded = { order.add("turn ended") }
        model.draft.text = "Explain it"
        let task = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.canStop)

        #expect(model.stop() != nil)
        let row = try #require(model.messages.last)
        #expect(row.role == .assistant && row.text == "Partial ans" && row.stopped && row.phase == .finished)
        #expect(order.events == ["speech stopped"])

        await gate.open()
        await task.value
        #expect(await sawCancel.value == true)                    // the brain's task was cancelled
        #expect(model.messages.map(\.text) == ["Explain it", "Partial ans"])   // nothing after the stop
        #expect(order.events == ["speech stopped", "turn ended"])   // never spoken
        #expect(!model.responding && !model.canStop)
        let turn = try #require(await coordinator.turns.first)
        #expect(await !turn.isOpen)
    }

    @Test func stopWhileOnlySpeakingStopsTheVoice() async {
        let model = ChatViewModel(submitter: FakeCoordinator(answering: .reply("Done, sir.")), minimumGap: .zero)
        let order = Order()
        model.onStopSpeech = { order.add("speech stopped") }
        model.speaking = true
        #expect(model.canStop)
        #expect(model.stop() == nil)
        #expect(!model.speaking && !model.canStop)
        #expect(order.events == ["speech stopped"])
    }

    @Test func sendWhileReplyingStopsHimThenSendsAsAddedContext() async throws {
        let gate = Gate()
        let order = Order()
        let coordinator = FakeCoordinator { input, sink in
            await order.add("start \(input.text), context \(input.addsContext)")
            if input.text == "Find flights to Rome" {
                await sink.delta("Flights start at")
                await gate.park()
                await order.add("first ended")
                return .reply("Flights start at")
            }
            await sink.delta("In euros, sir: from 89.")
            return .reply("In euros, sir: from 89.")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.onStopSpeech = { order.add("speech stopped") }
        model.draft.text = "Find flights to Rome"
        _ = try #require(model.send())
        await gate.waitUntilParked()

        model.draft.text = "in euros please"
        let second = try #require(model.send())
        #expect(model.draft.text.isEmpty)
        // Not sent yet: it waits for the stopped turn to end.
        #expect(model.messages.map(\.text) == ["Find flights to Rome", "Flights start at"])
        #expect(model.messages.last?.stopped == true)
        #expect(model.responding && model.canStop)

        await gate.open()
        await second.value
        #expect(order.events == ["start Find flights to Rome, context false", "speech stopped",
                                 "first ended", "start in euros please, context true"])
        #expect(model.messages.map(\.text) == ["Find flights to Rome", "Flights start at",
                                               "in euros please", "In euros, sir: from 89."])
        #expect(model.messages.map(\.stopped) == [false, true, false, false])
        #expect(await coordinator.inputs.map(\.addsContext) == [false, true])
        #expect(!model.responding)
    }

    @Test func stopBeforeTheTurnIsTakenStopsItOnceTaken() async throws {
        let gate = Gate()
        let model = ChatViewModel(submitter: ParkBeforeAccept(gate: gate), minimumGap: .zero)
        let order = Order()
        model.onReplyFinished = { message, _ in order.add("spoken \(message.text)") }
        model.draft.text = "Hello"
        let task = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.messages.isEmpty)
        #expect(model.stop() != nil)
        await gate.open()
        await task.value
        #expect(model.messages.map(\.text) == ["Hello", ""])
        #expect(model.messages.last?.stopped == true)
        #expect(order.events.isEmpty)
        #expect(!model.responding)
    }

    @Test func stoppingAMessageWaitingToBeSentGivesItBack() async throws {
        let gate = Gate()
        let coordinator = FakeCoordinator { _, sink in
            await sink.delta("Working")
            await gate.park()
            return .reply("Working")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.draft.text = "first"
        let first = try #require(model.send())
        await gate.waitUntilParked()
        model.draft.text = "more context"
        let second = try #require(model.send())
        #expect(model.stop() != nil)   // stops the message still waiting to be sent
        await gate.open()
        await first.value
        await second.value
        #expect(await coordinator.inputs.map(\.text) == ["first"])
        #expect(model.draft.text == "more context")
        #expect(model.messages.map(\.text) == ["first", "Working"])
        #expect(!model.responding)
    }
}
