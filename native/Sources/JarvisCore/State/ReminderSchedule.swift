import Foundation
import Synchronization

// F1: the alarms and reminders JARVIS set, spoken when they come due. The app makes one per
// launch, once the state lease is held, and stops it at quit.
//
//   start  a detached utility task checks alarms.json at once, then every `tick`. Each check
//          compares the entries with the wall clock (`clock`), never with time slept, so one that
//          came due while the Mac slept fires on the first check after it wakes. The sleeps are
//          on the SuspendingClock. The first check is the launch's: what came due while JARVIS
//          was quit is handled by the same rule.
//   due    an entry at most `maxLateness` late is announced (`line(for:)`); one later than that
//          is only logged. Either way it leaves the file, or a repeating one rolls forward
//          (AlarmBook.takeDue). Labels are never logged: they are the user's own words.
//   stop   cancels the loop.

public final class ReminderSchedule: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How often alarms.json is checked against the clock.
    public static let tick: Duration = .seconds(10)
    /// An entry later than this (JARVIS quit, or the Mac asleep) is logged and not spoken.
    public static let maxLateness: Double = 2 * 3600

    private let book: AlarmBook
    private let clock: any JarvisClock
    private let sleep: Sleep
    private let announce: @Sendable (String) async -> Void
    private let log: @Sendable (String) -> Void
    private let loop = Mutex<(started: Bool, task: Task<Void, Never>?)>((false, nil))

    /// - Parameters:
    ///   - announce: says the line (the app speaks it after any reply in progress).
    public init(book: AlarmBook, clock: any JarvisClock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                announce: @escaping @Sendable (String) async -> Void,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.book = book
        self.clock = clock
        self.sleep = sleep
        self.announce = announce
        self.log = log
    }

    /// What JARVIS says for `entry`: "Sir, you asked me to remind you: call the dentist." for a
    /// reminder; Python's `_fire_alarm` line for an alarm.
    public static func line(for entry: AlarmEntry) -> String {
        var label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = label.last, ".!".contains(last) { label.removeLast() }
        switch entry.kind {
        case .reminder:
            return label.isEmpty ? "Sir, you asked me to remind you of something now."
                : "Sir, you asked me to remind you: \(label)."
        case .alarm:
            return label.isEmpty ? "Alarm, sir. It's time." : "Alarm, sir. \(label)."
        }
    }

    /// One check: announces or logs every entry due now. Returns the lines announced.
    @discardableResult
    public func check() async -> [String] {
        let now = clock.now()
        var spoken: [String] = []
        for entry in book.takeDue(at: Date(timeIntervalSince1970: now)) {
            let late = now - entry.time.timeIntervalSince1970
            if late <= Self.maxLateness {
                let line = Self.line(for: entry)
                await announce(line)
                spoken.append(line)
            } else {
                log("Reminders: an \(entry.kind.rawValue) due \(Int(late / 60)) min ago was missed; not spoken")
            }
        }
        return spoken
    }

    /// Starts the loop; a second call does nothing.
    public func start() {
        loop.withLock { s in
            guard !s.started else { return }
            s.started = true
            let sleep = sleep, tick = Self.tick
            s.task = Task.detached(priority: .utility) { [self] in
                do {
                    while !Task.isCancelled {
                        await check()
                        try await sleep(tick)
                    }
                } catch {
                    // The sleep throws once stop() has cancelled the task.
                }
            }
        }
    }

    public func stop() {
        let task = loop.withLock { s -> Task<Void, Never>? in
            defer { s.task = nil }
            return s.task
        }
        task?.cancel()
    }
}
