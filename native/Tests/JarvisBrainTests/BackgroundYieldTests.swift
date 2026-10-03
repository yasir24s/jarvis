import Foundation
import Synchronization
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// Live fix 1: the first live session had a file read hold the on-device model for 120 s while
/// the user's turns waited. A background call in flight is cancelled when a turn starts, the
/// turn's model call goes ahead at once, and the background call starts again afterwards.
@Suite("Background on-device work gives way to the user (live fix 1)", .timeLimit(.minutes(2)))
struct BackgroundYieldTests {
    /// A background writer whose first call runs until it is cancelled; later calls answer.
    final class BlockingWriter: PersonaLLM {
        let calls = Mutex<[String]>([])
        let cancelled = Mutex(0)

        func complete(system: String, user: String, timeout: Duration) async throws -> String {
            let n = calls.withLock { $0.append(user); return $0.count }
            guard n == 1 else { return "facts for \(user)" }
            do {
                try await Task.sleep(for: .seconds(600))
            } catch {
                cancelled.withLock { $0 += 1 }
                throw error
            }
            throw PersonaWriterError.localFailed("timed out after 600 seconds")
        }
    }

    @Test func aTurnCancelsTheBackgroundCallAndRunsAtOnceThenTheCallStartsAgain() async throws {
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
        let writer = BlockingWriter()
        let logged = Mutex<[String]>([])
        let background = YieldingPersonaLLM(writer, turns: activity, sleep: { _ in try await Task.sleep(for: .milliseconds(5)) },
                                            log: { line in logged.withLock { $0.append(line) } })
        let read = Task { try await background.complete(system: "s", user: "file one", timeout: .seconds(120)) }
        #expect(await eventually(seconds: 60) { activity.backgroundInFlight == 1 })

        let turn = Task { await coordinator.submit(UserInput(text: "what's on today?", channel: .text),
                                                   sink: EventSink(EventLog())) }
        await hold.waitUntilEntered()                       // the turn's model call has started
        #expect(await eventually(seconds: 60) { writer.cancelled.withLock { $0 } == 1 })
        #expect(activity.isRunning)
        #expect(writer.calls.withLock { $0.count } == 1)   // nothing new starts while the turn runs
        await hold.open()
        #expect(await turn.value == .reply("Claude reply, sir."))

        #expect(try await read.value == "facts for file one")   // the same prompt, started again
        #expect(writer.calls.withLock { $0 } == ["file one", "file one"])
        #expect(logged.withLock { $0 }.contains { $0.contains("gave way to the user") })
        #expect(activity.backgroundInFlight == 0)
    }

    @Test func preemptingByHandCancelsTheCallInFlight() async throws {
        let activity = TurnActivity()
        let started = Mutex(false)
        let call = Task {
            try await activity.yielding { () async throws -> String in
                started.withLock { $0 = true }
                try await Task.sleep(for: .seconds(600))
                return "late"
            }
        }
        #expect(await eventually(seconds: 60) { started.withLock { $0 } && activity.backgroundInFlight == 1 })
        activity.preemptBackground()                          // push-to-talk opened, or the wake word
        guard case .preempted = try await call.value else {
            Issue.record("the call was not preempted")
            return
        }
        #expect(activity.backgroundInFlight == 0)
    }

    @Test func aCallStartedDuringATurnIsPreemptedAtOnce() async throws {
        let activity = TurnActivity()
        activity.begin()
        let result = try await activity.yielding { () async throws -> String in
            try await Task.sleep(for: .seconds(600))
            return "late"
        }
        guard case .preempted = result else {
            Issue.record("a call during a turn ran")
            return
        }
        activity.end()
    }

    @Test func cancellingTheCallerIsNotAPreemption() async throws {
        let activity = TurnActivity()
        let call = Task {
            try await activity.yielding { () async throws -> String in
                try await Task.sleep(for: .seconds(600))
                return "late"
            }
        }
        #expect(await eventually(seconds: 60) { activity.backgroundInFlight == 1 })
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
    }

    /// After a turn ends, the quiet wait waits out what is left of the grace, once per event.
    @Test func theQuietWaitWaitsOutTheGraceAfterATurn() async throws {
        let clock = ManualClock(1_790_582_400)
        let activity = TurnActivity(clock: clock)
        try await activity.waitUntilQuiet(sleep: { _ in Issue.record("slept with no turn yet") })
        activity.begin()
        activity.end()
        clock.advance(1)
        let slept = Mutex<[Duration]>([])
        try await activity.waitUntilQuiet(sleep: { d in slept.withLock { $0.append(d) } })
        #expect(slept.withLock { $0 } == [.milliseconds(Int((TurnActivity.graceSeconds - 1) * 1000))])
        clock.advance(TurnActivity.graceSeconds)
        try await activity.waitUntilQuiet(sleep: { _ in Issue.record("slept after the grace") })
        activity.preemptBackground()                          // the user starting to talk counts too
        let again = Mutex(0)
        try await activity.waitUntilQuiet(sleep: { _ in again.withLock { $0 += 1 } })
        #expect(again.withLock { $0 } == 1)
    }
}
