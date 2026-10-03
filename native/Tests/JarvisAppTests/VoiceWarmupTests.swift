import Foundation
@testable import JarvisApp
import Synchronization
import Testing

/// Live fix 5, with fakes: the Qwen helper is loaded once JARVIS is idle after launch unless
/// memory is short, and voice processing starts switching on as a spoken turn starts.
@Suite("Qwen pre-warm and voice processing ahead (live fix 5)", .serialized)
@MainActor
struct VoiceWarmupTests {
    /// Sleeps that return at once and are recorded.
    final class Sleeps: Sendable {
        let asked = Mutex<[Duration]>([])
        /// From this many sleeps on, each waits until `release()`; nil never waits.
        let holdFrom: Int?
        let released = Mutex(false)
        init(holdFrom: Int? = nil) { self.holdFrom = holdFrom }
        func release() { released.withLock { $0 = true } }
        var function: @Sendable (Duration) async throws -> Void {
            { d in
                let n = self.asked.withLock { $0.append(d); return $0.count }
                if let from = self.holdFrom, n >= from {
                    while !self.released.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(1)) }
                }
                await Task.yield()
            }
        }
    }

    final class State {
        var idle = true
        var free: Int? = 50
        var qwen = true
        var warmed = 0
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static func prewarm(_ state: State, sleeps: Sleeps) -> QwenPrewarm {
        QwenPrewarm(.init(usesQwen: { state.qwen }, isIdle: { state.idle },
                          memoryFreePercent: { state.free }, warm: { state.warmed += 1 },
                          sleep: sleeps.function, log: { _ in }))
    }

    @Test func idleWithMemoryFreeItWarmsOnceAfterTheDelay() async {
        let state = State(), sleeps = Sleeps()
        await Self.prewarm(state, sleeps: sleeps).start().value
        #expect(state.warmed == 1)
        #expect(sleeps.asked.withLock { $0 } == [QwenPrewarm.delay])
    }

    @Test func shortOfMemoryItWaitsAndThenWarms() async {
        let state = State(), sleeps = Sleeps(holdFrom: 3)
        state.free = 10
        let task = Self.prewarm(state, sleeps: sleeps).start()
        #expect(await Self.eventually { sleeps.asked.withLock { $0.count } >= 3 })
        #expect(state.warmed == 0)
        state.free = 40
        sleeps.release()
        await task.value
        #expect(state.warmed == 1)
    }

    @Test func busyOrNotQwenItDoesNotWarm() async {
        let busy = State(), sleeps = Sleeps()
        busy.idle = false
        await Self.prewarm(busy, sleeps: sleeps).start().value
        #expect(busy.warmed == 0)
        #expect(sleeps.asked.withLock { $0.count } == 1 + QwenPrewarm.attempts)   // gave up after its looks

        let other = State()
        other.qwen = false
        await Self.prewarm(other, sleeps: Sleeps()).start().value
        #expect(other.warmed == 0)
    }

    @Test func memoryUnknownStillWarms() async {
        let state = State()
        state.free = nil
        await Self.prewarm(state, sleeps: Sleeps()).start().value
        #expect(state.warmed == 1)
    }

    @Test func theSwitchStartsWithTheTurnAndIsReleasedOnce() async {
        var events: [String] = []
        let ahead = VoiceProcessingAhead(willStart: { events.append("on") }, ended: { events.append("off") },
                                         sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        ahead.turnStarting()
        ahead.turnStarting()                                  // one hold per turn
        #expect(events == ["on"] && ahead.isHolding)
        ahead.turnOver()
        ahead.turnOver()                                      // released exactly once
        #expect(events == ["on", "off"] && !ahead.isHolding)
    }

    @Test func aTurnThatNeverEndsIsReleasedAtTheLimit() async {
        var events: [String] = []
        let ahead = VoiceProcessingAhead(willStart: { events.append("on") }, ended: { events.append("off") },
                                         sleep: { _ in })
        ahead.turnStarting()
        #expect(await Self.eventually { events == ["on", "off"] })
        ahead.turnOver()
        #expect(events == ["on", "off"])
    }
}
