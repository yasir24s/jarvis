import Foundation
import Synchronization
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// D-51 P3, piece 4: TurnCoordinator marks each accepted turn on its TurnActivity, which is
/// what every file read waits on.
@Suite("Turn activity for background work (D-51 P3)", .timeLimit(.minutes(1)))
struct TurnActivityTests {
    @Test func anAcceptedTurnIsRunningUntilItsReplyIsDone() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let hold = Hold()
        let claude = FakeClaudeBrain(reply: "Claude reply, sir.", sentences: ["Claude reply, sir."], hold: hold)
        let router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: [:]), claude: claude,
                                 local: FakeLocalBrain(.reply("Local reply, sir.")),
                                 backend: EventBackend(EventLog()), research: NullCounter(), log: { _ in })
        let activity = TurnActivity()
        let coordinator = TurnCoordinator(brain: router, confirmations: ConfirmationGate(),
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { true },
                                          activity: activity)
        let sink = EventSink(EventLog())
        #expect(await coordinator.submit(UserInput(text: "   ", channel: .text), sink: sink) == .empty)
        #expect(!activity.isRunning)

        let turn = Task { await coordinator.submit(UserInput(text: "what's on today?", channel: .text), sink: sink) }
        await hold.waitUntilEntered()
        #expect(activity.isRunning)
        #expect(await coordinator.submit(UserInput(text: "and tomorrow?", channel: .text), sink: sink) == .busy)
        #expect(activity.isRunning)
        await hold.open()
        #expect(await turn.value == .reply("Claude reply, sir."))
        #expect(!activity.isRunning)
    }

    @Test func waitingReturnsAtOnceWhenIdleAndStopsWhenCancelled() async throws {
        let activity = TurnActivity()
        try await activity.waitUntilIdle(sleep: { _ in Issue.record("slept while idle") })
        activity.begin()
        let waiter = Task { try await activity.waitUntilIdle() }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        activity.end()
        activity.end()                                                    // never below zero
        #expect(!activity.isRunning)
    }

    /// V1 part 5: speech holds the file scan back (`waitUntilQuiet`) but is not a turn: the idle
    /// compile's `waitUntilIdle` and `lastActivity` do not see it.
    @Test func speechHoldsTheQuietWaitButIsNotATurn() async throws {
        let clock = ManualClock(1_790_582_400)
        let activity = TurnActivity(clock: clock)
        activity.speechBegan()
        #expect(activity.isSpeaking && !activity.isRunning)
        #expect(activity.lastActivity == nil)
        try await activity.waitUntilIdle(sleep: { _ in Issue.record("waitUntilIdle slept for speech") })
        let slept = Mutex(0)
        let waiter = Task {
            try await activity.waitUntilQuiet(sleep: { _ in
                slept.withLock { $0 += 1 }
                try await Task.sleep(for: .milliseconds(2))
            })
        }
        while slept.withLock({ $0 }) < 3 { try await Task.sleep(for: .milliseconds(2)) }
        activity.speechEnded()
        try await waiter.value
        activity.begin()                                                   // a turn holds it too
        let turnWaiter = Task { try await activity.waitUntilQuiet(sleep: { _ in try await Task.sleep(for: .milliseconds(2)) }) }
        try await Task.sleep(for: .milliseconds(20))
        activity.end()
        try await turnWaiter.value
        activity.speechEnded()                                             // never below zero
        #expect(!activity.isSpeaking)
        try await activity.waitUntilQuiet(sleep: { _ in Issue.record("slept while quiet") })
    }
}
