import Foundation
@testable import JarvisApp
import JarvisVoice
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

/// V9, with fakes: the turn-start warm-up runs only for a cloud brain, Qwen, speech on, enough
/// memory and a helper idle past the limit; it never plays anything (it has no player to reach).
@Suite("V9 turn-start warm-up", .serialized)
@MainActor
struct TurnStartWarmupTests {
    final class State: Sendable {
        struct Values {
            var qwen = true
            var cloud = true
            var muted = false
            var free: Int? = 50
            var idle: Double? = 300
            var warmUps = 0
            var finishes = true
            var cold: [Bool] = []
            var logs: [String] = []
        }
        let values = Mutex(Values())
    }

    static func warmup(_ state: State) -> TurnStartWarmup {
        TurnStartWarmup(.init(
            usesQwen: { state.values.withLock { $0.qwen } },
            cloudBrain: { state.values.withLock { $0.cloud } },
            muted: { state.values.withLock { $0.muted } },
            memoryFreePercent: { state.values.withLock { $0.free } },
            idleSeconds: { state.values.withLock { $0.idle } },
            warmUp: { state.values.withLock { $0.warmUps += 1; return $0.finishes } },
            coldVoice: { cold in state.values.withLock { $0.cold.append(cold) } },
            log: { line in state.values.withLock { $0.logs.append(line) } }))
    }

    static func run(_ change: (inout State.Values) -> Void) async -> State.Values {
        let state = State()
        var values = State.Values()
        change(&values)
        state.values.withLock { [values] in $0 = values }
        await warmup(state).turnStarting()?.value
        return state.values.withLock { $0 }
    }

    @Test func aCloudTurnAfterIdleWarmsTheHelperAndLogsIt() async {
        let values = await Self.run { _ in }
        #expect(values.warmUps == 1)
        #expect(values.logs.count == 1)
        #expect(values.logs.first?.hasPrefix("voice: warm-up at turn start (idle 300 s), took ") == true)
    }

    @Test func itIsSkippedOutsideItsConditions() async {
        #expect(await Self.run { $0.cloud = false }.warmUps == 0)   // on-device brain
        #expect(await Self.run { $0.qwen = false }.warmUps == 0)
        #expect(await Self.run { $0.muted = true }.warmUps == 0)
        #expect(await Self.run { $0.free = 19 }.warmUps == 0)
        #expect(await Self.run { $0.idle = 120 }.warmUps == 0)   // not past the limit
        #expect(await Self.run { $0.idle = nil }.warmUps == 0)   // never used
        #expect(await Self.run { $0.free = 20 }.warmUps == 1)
        #expect(await Self.run { $0.free = nil }.warmUps == 1)   // unknown is not short
    }

    /// Part 3: idle with no warm-up finished, the reply's pre-roll starts at x0.85.
    @Test func aColdVoiceIsFlaggedUnlessTheWarmUpFinished() async {
        #expect(await Self.run { _ in }.cold == [true, false])
        #expect(await Self.run { $0.finishes = false }.cold == [true])   // cut short by the reply
        let onDevice = await Self.run { $0.cloud = false }
        #expect(onDevice.cold == [true])
        #expect(onDevice.logs == ["voice: helper idle 300 s, no warm-up (on-device brain): the reply's pre-roll starts at x0.85"])
        #expect(await Self.run { $0.free = 10 }.cold == [true])
        #expect(await Self.run { $0.idle = 30 }.cold == [false])
        #expect(await Self.run { $0.muted = true }.cold == [])
    }

    @Test func oneAtATime() async {
        let state = State()
        let warmup = Self.warmup(state)
        let first = warmup.turnStarting()
        #expect(warmup.turnStarting() == nil)
        await first?.value
        #expect(state.values.withLock { $0.warmUps } == 1)
    }
}

/// V10, with fakes: the Qwen model stays resident unless the voice is F5, speech has been muted
/// longer than ten minutes, or memory is under 10% free; it comes back when those clear.
@Suite("V10 Qwen model resident")
@MainActor
struct QwenResidencyTests {
    /// The plain fields are only touched on the main actor; the Mutexes from the engine's side.
    final class State: @unchecked Sendable {
        var qwen = true
        var muted = false
        var free: Int? = 40
        var now = ContinuousClock.now
        let told = Mutex<[Bool]>([])
        let logs = Mutex<[String]>([])
    }

    static func residency(_ state: State) -> QwenResidency {
        QwenResidency(.init(
            usesQwen: { state.qwen },
            muted: { state.muted },
            memoryFreePercent: { state.free },
            setResident: { on in state.told.withLock { $0.append(on) } },
            now: { state.now },
            sleep: { _ in },
            log: { line in state.logs.withLock { $0.append(line) } }))
    }

    @Test func onWithQwenSoNothingIsSent() async {
        let state = State()
        let residency = Self.residency(state)
        await residency.check()
        #expect(residency.resident)
        #expect(state.told.withLock { $0 }.isEmpty)
    }

    @Test func offForF5AndOnAgainForQwen() async {
        let state = State()
        let residency = Self.residency(state)
        state.qwen = false
        await residency.check()
        await residency.check()
        state.qwen = true
        await residency.check()
        #expect(state.told.withLock { $0 } == [false, true])
        #expect(state.logs.withLock { $0 } == ["voice: Qwen model resident off (the voice is F5)",
                                               "voice: Qwen model resident on"])
    }

    @Test func offOnlyAfterTenMinutesMutedAndOnWhenUnmuted() async {
        let state = State()
        let residency = Self.residency(state)
        state.muted = true
        await residency.check()
        state.now += .seconds(600)
        await residency.check()
        #expect(state.told.withLock { $0 }.isEmpty)
        state.now += .seconds(1)
        await residency.check()
        #expect(state.told.withLock { $0 } == [false])
        #expect(state.logs.withLock { $0 }.last == "voice: Qwen model resident off (speech muted over 10 min)")
        state.muted = false
        await residency.check()
        #expect(state.told.withLock { $0 } == [false, true])
    }

    @Test func offUnderTenPercentFreeAndOnWhenItClears() async {
        let state = State()
        let residency = Self.residency(state)
        state.free = 10
        await residency.check()
        #expect(state.told.withLock { $0 }.isEmpty)
        state.free = 9
        await residency.check()
        #expect(state.logs.withLock { $0 }.last == "voice: Qwen model resident off (9% of memory free)")
        state.free = nil   // unreadable is not short
        await residency.check()
        #expect(state.told.withLock { $0 } == [false, true])
    }
}
