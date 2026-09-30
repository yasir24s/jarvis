import Foundation
import Synchronization

// JARVIS's personality upkeep in the background (P1). The app makes one per launch, once the
// state lease is held, and stops it at quit before the lock is released.
//
//   start  a detached utility task sleeps 120 s, then runs CoreState's consolidation check
//          every 3600 s: the timing of Python's proactive_loop (jarvis.py 2535-2567), which
//          calls personality_consolidate() on every pass. The sleeps are on the
//          SuspendingClock, so system sleep does not count toward the hour. CoreState applies
//          the due rule (10+ notes, 7+ days) and writes through its StateStore; this type
//          only keeps time. Python's other proactive nudge, the voiceprint reminder, is not
//          ported here.
//   conversationEnded
//          the user dismissed JARVIS (Dismissal): CoreState's distillation runs in a detached
//          task, as Python's personality_distill_async runs in a daemon thread, so the reply
//          never waits for it. CoreState applies its own rules (900 s apart, 4+ turns). Only
//          between start() and stop().
//   stop   cancels the loop and any distillation in flight. A pass still waiting on its
//          writer is cancelled with it, and CoreState then writes nothing; a save already
//          under way completes.
//
// The sleep, the clock (for the log's "+S s") and the log are injected, so a test runs a day
// in milliseconds.

public final class PersonalitySchedule: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// proactive_loop's `time.sleep(120)` before the first pass ("let startup settle first").
    public static let firstCheck: Duration = .seconds(120)
    /// proactive_loop's `time.sleep(3600)` between passes.
    public static let period: Duration = .seconds(3600)

    private struct State {
        var started = false
        var stopped = false
        var loop: Task<Void, Never>?
        var distills: [Int: Task<Void, Never>] = [:]
        var nextDistill = 0
    }

    private let consolidate: @Sendable () async -> Void
    private let distill: @Sendable () async -> Void
    private let clock: any JarvisClock
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - consolidate: one pass. The app's is `core.consolidatePersonalityIfDue(using:)`
    ///     (the `core:` initializer).
    ///   - distill: what a dismissal runs. The app's is `core.distillPersonalityIfDue(using:)`.
    ///   - clock: only for the elapsed time in the log lines.
    public init(consolidate: @escaping @Sendable () async -> Void, distill: @escaping @Sendable () async -> Void = {},
                clock: any JarvisClock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.consolidate = consolidate
        self.distill = distill
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    /// Each pass is `core.consolidatePersonalityIfDue(using: writer)`, each dismissal
    /// `core.distillPersonalityIfDue(using: writer)`.
    public convenience init(core: CoreState, writer: any PersonaLLM, clock: any JarvisClock = SystemClock(),
                            sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.init(consolidate: { await core.consolidatePersonalityIfDue(using: writer) },
                  distill: { await core.distillPersonalityIfDue(using: writer) }, clock: clock, sleep: sleep, log: log)
    }

    /// Starts the consolidation loop. Once per schedule: a second call, or one after `stop()`,
    /// does nothing.
    public func start() {
        let consolidate = consolidate, clock = clock, sleep = sleep, log = log
        let first = Self.firstCheck, period = Self.period
        let started = state.withLock { s -> Bool in
            guard !s.started, !s.stopped else { return false }
            s.started = true
            let t0 = clock.now()
            s.loop = Task.detached(priority: .utility) {
                do {
                    try await sleep(first)
                    var n = 0
                    while !Task.isCancelled {
                        n += 1
                        await consolidate()
                        log("Personality consolidation check \(n) at +\(Int((clock.now() - t0).rounded())) s")
                        try await sleep(period)
                    }
                } catch {
                    // The sleep throws once stop() has cancelled the task: the loop is over.
                }
            }
            return true
        }
        guard started else { return }
        log("Personality schedule started: first consolidation check in \(first.components.seconds) s, "
            + "then every \(period.components.seconds) s")
    }

    /// The conversation ended (the TurnCoordinator's hook): runs the distillation in the
    /// background and returns at once. Does nothing before `start()` or after `stop()`.
    public func conversationEnded() {
        let distill = distill
        state.withLock { s in
            guard s.started, !s.stopped else { return }
            let id = s.nextDistill
            s.nextDistill += 1
            s.distills[id] = Task.detached(priority: .utility) { [weak self] in
                await distill()
                self?.state.withLock { _ = $0.distills.removeValue(forKey: id) }
            }
        }
    }

    /// Cancels the loop and any distillation in flight (applicationWillTerminate, before the
    /// lock is released). A pass waiting on its writer is cancelled with it; none starts after.
    public func stop() {
        let (loop, distills) = state.withLock { s -> (Task<Void, Never>?, [Task<Void, Never>]) in
            s.stopped = true
            defer {
                s.loop = nil
                s.distills = [:]
            }
            return (s.loop, Array(s.distills.values))
        }
        for task in distills { task.cancel() }
        guard let loop else { return }
        loop.cancel()
        log("Personality schedule stopped")
    }
}
