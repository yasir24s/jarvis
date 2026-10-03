import Foundation
import JarvisCore
import Synchronization

/// Whether a turn is running, for background work that must not compete with one (D-51 P3:
/// every file read waits while a turn runs). `TurnCoordinator.submit` brackets each accepted
/// turn with `begin()` and `end()`. P6: it also notes when a turn last began or ended, for the
/// idle compile (`IdleCompile`). V1 part 5: the app's voice brackets the speech it generates
/// and plays with `speechBegan()` and `speechEnded()`, and the file scan waits for that too
/// (`waitUntilQuiet`). Speech is not a turn: `isRunning`, `lastActivity` and `waitUntilIdle`
/// do not count it.
///
/// Live fix 1: the user always comes first. Background on-device work runs its model call
/// through `yielding`, and a turn beginning (or `preemptBackground()`, which the app calls when
/// push-to-talk opens or the wake word is heard) cancels every such call in flight; the caller
/// gets `.preempted` and tries again later. After a turn or a preemption, `waitUntilQuiet`
/// also waits out `graceSeconds`, so a follow-up turn finds the model free.
public final class TurnActivity: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How often a waiter looks again while a turn runs.
    public static let pollInterval: Duration = .milliseconds(500)

    /// How long background work waits after a turn ends, or after a preemption, before it
    /// starts a model call.
    public static let graceSeconds: Double = 3

    /// What a `yielding` call came to.
    public enum Yield<Value: Sendable>: Sendable {
        case finished(Value)
        /// A turn began, or `preemptBackground()` was called, while it ran: it was cancelled.
        case preempted
    }

    private let running = Mutex(0)
    private let speaking = Mutex(0)
    private let clock: any JarvisClock
    private let last = Mutex<Double?>(nil)
    /// The cancel handlers of the yielding calls in flight, by id.
    private let inFlight = Mutex<(next: Int, cancels: [Int: @Sendable () -> Void])>((0, [:]))
    /// When a turn last ended or background work was last preempted, and how many times either
    /// has happened: what a quiet wait measures its grace from.
    private let quietSince = Mutex<(at: Double, count: Int)?>(nil)

    public init(clock: any JarvisClock = SystemClock()) {
        self.clock = clock
    }

    public func begin() {
        running.withLock { $0 += 1 }
        last.withLock { $0 = clock.now() }
        preemptBackground()
    }

    public func end() {
        running.withLock { $0 = max(0, $0 - 1) }
        last.withLock { $0 = clock.now() }
        markGrace()
    }

    private func markGrace() {
        let now = clock.now()
        quietSince.withLock { $0 = (now, ($0?.count ?? 0) + 1) }
    }

    /// Cancels every background model call in flight (`yielding`), and makes the next quiet
    /// wait wait out `graceSeconds`. Called by `begin()`, and by the app as the user starts to talk.
    public func preemptBackground() {
        markGrace()
        let cancels = inFlight.withLock { state in
            let all = Array(state.cancels.values)
            state.cancels.removeAll()
            return all
        }
        for cancel in cancels { cancel() }
    }

    /// The number of background model calls in flight.
    public var backgroundInFlight: Int { inFlight.withLock { $0.cancels.count } }

    /// Runs a background model call so that the user can take the model from it: a turn
    /// beginning, or `preemptBackground()`, cancels it and this returns `.preempted`. A call
    /// started while a turn runs is preempted at once. Cancelling the caller cancels the call
    /// and throws as it does.
    public func yielding<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value)
        async throws -> Yield<Value> {
        let preempted = Flag()
        let task = Task { try await operation() }
        let id = inFlight.withLock { state in
            let id = state.next
            state.next += 1
            state.cancels[id] = {
                preempted.set()
                task.cancel()
            }
            return id
        }
        defer { _ = inFlight.withLock { $0.cancels.removeValue(forKey: id) } }
        if isRunning { preemptBackground() }    // a turn began before the call was registered
        do {
            let value = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            return .finished(value)
        } catch {
            if preempted.isSet && !Task.isCancelled { return .preempted }
            throw error
        }
    }

    private final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    public var isRunning: Bool { running.withLock { $0 > 0 } }

    public func speechBegan() {
        speaking.withLock { $0 += 1 }
    }

    public func speechEnded() {
        speaking.withLock { $0 = max(0, $0 - 1) }
    }

    /// Speech is being generated or played.
    public var isSpeaking: Bool { speaking.withLock { $0 > 0 } }

    /// When a turn last began or ended; nil before the first.
    public var lastActivity: Double? { last.withLock { $0 } }

    /// Returns once no turn is running, at once when none is; throws when cancelled.
    public func waitUntilIdle(sleep: Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) async throws {
        while isRunning {
            try await sleep(Self.pollInterval)
        }
        try Task.checkCancellation()
    }

    /// Returns once no turn is running and no speech is being generated or played, at once when
    /// neither is; throws when cancelled. What the file scan waits on.
    public func waitUntilQuiet(sleep: Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) async throws {
        var waitedOut = -1    // the event whose grace this wait has already slept through
        while true {
            while isRunning || isSpeaking {
                try await sleep(Self.pollInterval)
            }
            // Live fix 1: within `graceSeconds` of a turn ending or the user starting to talk, wait the
            // rest of it. Each event is waited out once, so a clock that stands still cannot hold
            // the wait for ever.
            guard let since = quietSince.withLock({ $0 }), since.count != waitedOut else { break }
            let left = Self.graceSeconds - (clock.now() - since.at)
            guard left > 0 else { break }
            waitedOut = since.count
            try await sleep(.milliseconds(Int((left * 1000).rounded(.up))))
        }
        try Task.checkCancellation()
    }
}
