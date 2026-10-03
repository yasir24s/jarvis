import Foundation
import JarvisBrain
@testable import JarvisChat
import JarvisTools
import Testing

/// A submitter whose first turn parks before it is taken; later turns are taken at once.
actor ParkFirstBeforeAccept: TurnSubmitting {
    let gate: Gate
    private(set) var inputs: [String] = []

    init(gate: Gate) {
        self.gate = gate
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        inputs.append(input.text)
        if inputs.count == 1 { await gate.park() }
        let turn = TurnContext(channel: input.channel)
        await accepted?(turn)
        await sink.delta("Reply to \(input.text)")
        await turn.close()
        return .reply("Reply to \(input.text)")
    }
}

/// Live fix 2: in the first live session Stop showed STOPPED but the chat could not send until
/// the brain's cancellation had finished. Stop now ends the turn for the chat at once; the
/// stopped turn's late result is dropped, and a message sent meanwhile goes once it has unwound.
@Suite("Stop frees the chat at once (live fix 2)", .serialized)
@MainActor
struct StopFreesTheChatTests {
    @Test func stopEndsTheTurnAtOnceAndANewMessageFollowsTheUnwinding() async throws {
        let gate = Gate()
        let order = Order()
        let coordinator = FakeCoordinator { input, sink in
            await order.add("start \(input.text), context \(input.addsContext)")
            if input.text == "Explain it" {
                await sink.delta("Partial ans")
                await gate.park()                              // the brain still unwinding
                await sink.delta("wer, late")
                await order.add("first ended")
                return .reply("Partial answer, late")
            }
            await sink.delta("Here you are, sir.")
            return .reply("Here you are, sir.")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.draft.text = "Explain it"
        let first = try #require(model.send())
        await gate.waitUntilParked()

        #expect(model.stop() != nil)
        #expect(!model.responding && !model.canStop)           // Send is back before the brain ends

        model.draft.text = "Something else"
        let second = try #require(model.send())
        #expect(model.draft.text.isEmpty)
        #expect(model.responding)
        #expect(await coordinator.inputs.count == 1)           // queued behind the unwinding turn

        await gate.open()
        await first.value
        await second.value
        #expect(order.events == ["start Explain it, context false", "first ended",
                                 "start Something else, context false"])
        #expect(model.messages.map(\.text) == ["Explain it", "Partial ans", "Something else", "Here you are, sir."])
        #expect(model.messages.map(\.stopped) == [false, true, false, false])
        #expect(!model.responding)
    }

    @Test func aStopBeforeTheTurnIsTakenDoesNotStopTheNextOne() async throws {
        let gate = Gate()
        let submitter = ParkFirstBeforeAccept(gate: gate)
        let model = ChatViewModel(submitter: submitter, minimumGap: .zero)
        model.draft.text = "First"
        let first = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.stop() != nil)
        #expect(!model.responding)

        model.draft.text = "Second"
        let second = try #require(model.send())
        await gate.open()
        await first.value
        await second.value
        #expect(await submitter.inputs == ["First", "Second"])
        let rows = model.messages.filter { $0.role == .assistant }
        #expect(rows.map(\.stopped) == [true, false])
        #expect(rows.last?.text == "Reply to Second")
        #expect(!model.responding)
    }

    @Test func stopThenStopAgainIsHarmless() async throws {
        let gate = Gate()
        let coordinator = FakeCoordinator { _, sink in
            await sink.delta("Partial")
            await gate.park()
            return .reply("Partial, late")
        }
        let model = ChatViewModel(submitter: coordinator, minimumGap: .zero)
        model.draft.text = "Explain it"
        let first = try #require(model.send())
        await gate.waitUntilParked()
        #expect(model.stop() != nil)
        #expect(model.stop() == nil)                           // nothing running for the chat now
        await gate.open()
        await first.value
        #expect(model.messages.map(\.text) == ["Explain it", "Partial"])
        #expect(!model.responding)
    }
}
