import Foundation
import Synchronization

// PA batch A: jarvis.py's timers (`_set_timer`, `_cancel_timers`, `_timer_status`, 2869-2910),
// reached only by the fast path. Like Python's they live in memory and end with the app.
//
//   set     records the end on the wall clock (`clock`) and makes sure the loop runs.
//   loop    sleeps towards the soonest end, at most `tick` at a time on the SuspendingClock, and
//           compares the ends with the wall clock after every sleep. A timer that ended while
//           the Mac slept is spoken on the first check after it wakes, never a sleep's length
//           late (Python's threading.Timer waits on the monotonic clock, which stops in sleep).
//           The loop ends when no timer is left; the next `set` starts it again.
//   fire    each due timer, soonest first, leaves the list and its line is announced.

public final class QuickTimers: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// The longest single sleep: how late a timer can be after the Mac wakes.
    public static let tick: Duration = .seconds(1)

    struct Running: Sendable {
        let id: Int
        let label: String
        let end: Double
    }

    private struct State: Sendable {
        var seq = 0
        var timers: [Running] = []      // insertion order, as Python's dict
        var loop: Task<Void, Never>?
        var stopped = false
    }

    private let clock: any JarvisClock
    private let sleep: Sleep
    private let announce: @Sendable (String) async -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - announce: says a finished timer's line (the app speaks it after any reply in progress).
    public init(clock: any JarvisClock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                announce: @escaping @Sendable (String) async -> Void) {
        self.clock = clock
        self.sleep = sleep
        self.announce = announce
    }

    /// `_set_timer(seconds)`: the reply. The fast path never passes a label.
    public func set(seconds: Int, label: String = "") -> String {
        let seconds = max(1, seconds)
        let now = clock.now()
        state.withLock { s in
            s.seq += 1
            s.timers.append(Running(id: s.seq, label: label, end: now + Double(seconds)))
        }
        startLoop()
        return "Timer set for \(Self.humanSeconds(Double(seconds))), sir."
    }

    /// `_cancel_timers()`.
    public func cancel() -> String {
        let n = state.withLock { s -> Int in
            defer { s.timers.removeAll() }
            return s.timers.count
        }
        if n == 0 { return "There are no timers running, sir." }
        return n == 1 ? "Timer cancelled, sir." : "All \(n) timers cancelled, sir."
    }

    /// `_timer_status()`.
    public func status() -> String {
        let timers = state.withLock { $0.timers }
        if timers.isEmpty { return "No timers running, sir." }
        let now = clock.now()
        // sorted(…, key=end) is stable: equal ends keep insertion order.
        let bits = timers.enumerated().sorted { ($0.element.end, $0.offset) < ($1.element.end, $1.offset) }
            .map { pair -> String in
                let label = pair.element.label.isEmpty ? "" : " on the \(pair.element.label) timer"
                return "\(Self.humanSeconds(pair.element.end - now)) left\(label)"
            }
        return bits.joined(separator: ", ") + ", sir."
    }

    /// How many timers are running.
    public var count: Int { state.withLock { $0.timers.count } }

    /// The timers due at `now`, soonest first, taken out of the list: their lines.
    public func takeDue(at now: Double) -> [String] {
        let due = state.withLock { s -> [Running] in
            let due = s.timers.filter { $0.end <= now }
            s.timers.removeAll { $0.end <= now }
            return due
        }
        return due.sorted { ($0.end, $0.id) < ($1.end, $1.id) }.map { Self.line(label: $0.label) }
    }

    /// One check: announces every timer due now. Returns the lines announced.
    @discardableResult
    public func check() async -> [String] {
        let lines = takeDue(at: clock.now())
        for line in lines { await announce(line) }
        return lines
    }

    /// The line a finished timer says.
    public static func line(label: String) -> String {
        label.isEmpty ? "Sir, your timer is complete." : "Sir, your \(label) is complete."
    }

    /// `_human_secs(secs)`.
    public static func humanSeconds(_ secs: Double) -> String {
        let whole = secs.rounded(.towardZero)
        let total = whole >= 9.0e18 ? Int.max : max(0, Int(whole))
        let m = total / 60, s = total % 60
        if m != 0 && s != 0 { return "\(m) minute\(m != 1 ? "s" : "") \(s) seconds" }
        if m != 0 { return "\(m) minute\(m != 1 ? "s" : "")" }
        return "\(s) seconds"
    }

    /// Stops the loop for good (app quit). Running timers are dropped, as Python's die with it.
    public func stop() {
        let task = state.withLock { s -> Task<Void, Never>? in
            s.stopped = true
            s.timers.removeAll()
            defer { s.loop = nil }
            return s.loop
        }
        task?.cancel()
    }

    private func startLoop() {
        state.withLock { s in
            guard s.loop == nil, !s.stopped else { return }
            s.loop = Task.detached(priority: .utility) { [self] in
                await run()
            }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            await check()
            let next = state.withLock { s -> Double? in
                guard let soonest = s.timers.map(\.end).min() else {
                    s.loop = nil                     // nothing left: the next set starts a new loop
                    return nil
                }
                return soonest
            }
            guard let next else { return }
            let step = min(Duration.seconds(min(max(0, next - clock.now()), 1)), Self.tick)
            do { try await sleep(step) } catch { return }
        }
    }
}
