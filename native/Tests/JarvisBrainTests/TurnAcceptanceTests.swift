import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Synchronization
import Testing

/// `TurnCoordinator.submit`'s `accepted` hook (M4 C2): the chat adds its rows there, so a
/// submit the coordinator refuses shows none. Uses the M3 coordinator rig.
@Suite("M4 turn acceptance (chat rows)", .timeLimit(.minutes(1)))
struct TurnAcceptanceTests {
    /// The order in which `accepted` and the sink were reached.
    final class Order: ReplySink {
        private let log = Mutex<[String]>([])
        var events: [String] { log.withLock { $0 } }
        func note(_ event: String) { log.withLock { $0.append(event) } }
        func sentence(_ text: String) async { note("sentence: \(text)") }
        func delta(_ text: String) async { note("delta: \(text)") }
    }

    @Test("a taken turn calls accepted once, with its context, before anything reaches the sink")
    func acceptedComesFirst() async throws {
        let rig = try TurnCoordinatorTests.Rig()
        defer { rig.harness.remove() }
        let action = TurnCoordinatorTests.Action("Deleted, sir.")
        await rig.gate.stash(desc: TurnCoordinatorTests.desc, action: action.body, turn: TurnContext(channel: .voice))
        let order = Order()
        let seen = Mutex<[UUID]>([])
        let outcome = await rig.coordinator.submit(UserInput(text: "yes", channel: .voice), sink: order,
                                                   accepted: { turn in
            let id = await turn.turnID
            seen.withLock { $0.append(id) }
            order.note("accepted")
        })
        #expect(outcome == .confirmation("Deleted, sir."))
        #expect(order.events == ["accepted", "sentence: Deleted, sir."])
        let started = try #require(rig.turns.all.last)
        #expect(seen.withLock { $0 } == [await started.turnID])
    }

    @Test("a submit refused as .empty or .busy never calls accepted")
    func refusedSubmitsAreNotAccepted() async throws {
        let hold = Hold()
        let rig = try TurnCoordinatorTests.Rig(hold: hold)
        defer { rig.harness.remove() }
        let calls = Mutex(0)
        let count: @Sendable (TurnContext) async -> Void = { _ in calls.withLock { $0 += 1 } }

        #expect(await rig.coordinator.submit(UserInput(text: " \n", channel: .text), sink: rig.sink,
                                             accepted: count) == .empty)
        let first = Task { await rig.submit("first command") }
        await hold.waitUntilEntered()
        #expect(await rig.coordinator.submit(UserInput(text: "second command", channel: .text), sink: rig.sink,
                                             accepted: count) == .busy)
        #expect(calls.withLock { $0 } == 0)
        await hold.open()
        _ = await first.value
        #expect(await rig.coordinator.submit(UserInput(text: "third command", channel: .text), sink: rig.sink,
                                             accepted: count) == .reply(TurnCoordinatorTests.claudeReply))
        #expect(calls.withLock { $0 } == 1)
    }
}
