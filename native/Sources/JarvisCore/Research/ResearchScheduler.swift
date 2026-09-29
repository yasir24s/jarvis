import Foundation

// The dataset's schedule (plan: M01b §3.5, task T10; decisions D-36 and D-37). The app makes one
// per launch in applicationDidFinishLaunching, before and independent of the voice pipeline and
// the windows, and stops it in applicationWillTerminate (that wiring is the next M4 batch's).
// T10 names Sources/JarvisApp/Research/; it lives here because test targets cannot import the
// JarvisApp executable.
//
//   start  bumps starts_swift_<build> at once; a detached utility task then sleeps 90 s and
//          runs a check every 3600 s, research_log_loop's timing (jarvis.py 2569–2578), on the
//          SuspendingClock so system sleep does not count toward the hour. A check bumps
//          alive_hours, then snapshots only if metrics.jsonl's last row is not dated today,
//          with CoreState's in-memory corrections and history counts (D-37). No other trigger
//          (wake, midnight) exists: §3.6 rejects them.
//   stop   cancels the task and waits for the bumps already enqueued (logger.flush()).
//
// JARVIS_RESEARCH_TICK=<seconds> replaces the 3600 s period (never the first 90 s) in a dev
// build only (acceptance A7); a release build ignores it and logs that it did. Without the held
// state lease the logger refuses to write a real research/ root and logs why (D-36). The sleep
// and the log are injected and the time is the logger's clock, so a test runs a day in
// milliseconds.

@MainActor
public final class ResearchScheduler {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// research_log_loop's `time.sleep(90)` before the first check.
    nonisolated public static let firstCheck: Duration = .seconds(90)
    /// research_log_loop's `time.sleep(3600)` between checks.
    nonisolated public static let period: Duration = .seconds(3600)
    /// Whole seconds replacing `period` in a dev build (A7).
    nonisolated public static let tickVariable = "JARVIS_RESEARCH_TICK"

    public let logger: ResearchLogger
    public let build: BuildChannel
    /// The time between checks: `period`, or JARVIS_RESEARCH_TICK in a dev build.
    public let interval: Duration
    private let intervalNote: String?
    private let snapshotInputs: @Sendable () async -> CoreSnapshotInputs
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    private var started = false
    private var task: Task<Void, Never>?

    /// `snapshotInputs` is `CoreState.snapshotInputs` in the app (D-37; see the `core:`
    /// initializer). `environment` is read once, here.
    public init(logger: ResearchLogger, build: BuildChannel,
                snapshotInputs: @escaping @Sendable () async -> CoreSnapshotInputs,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .research) }) {
        self.logger = logger
        self.build = build
        let (every, note) = Self.checkInterval(build: build, environment: environment)
        self.interval = every
        self.intervalNote = note
        self.snapshotInputs = snapshotInputs
        self.sleep = sleep
        self.log = log
    }

    /// D-37 as the app wires it: a snapshot counts `core`'s cached corrections and in-memory
    /// history, as Python counts `_corr_cache` and `_history`, not the files.
    public convenience init(logger: ResearchLogger, build: BuildChannel, core: CoreState,
                            environment: [String: String] = ProcessInfo.processInfo.environment,
                            sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .research) }) {
        self.init(logger: logger, build: build, snapshotInputs: { await core.snapshotInputs() },
                  environment: environment, sleep: sleep, log: log)
    }

    /// The period between checks, and a note for the log when JARVIS_RESEARCH_TICK was set
    /// but not used. Honoured only in a dev build, and only as whole seconds above 0.
    nonisolated static func checkInterval(build: BuildChannel,
                                          environment: [String: String]) -> (Duration, String?) {
        guard let raw = environment[tickVariable] else { return (period, nil) }
        guard build == .dev else { return (period, "\(tickVariable) ignored in a release build") }
        guard let seconds = Int(raw), seconds > 0 else {
            return (period, "\(tickVariable) ignored: not a whole number of seconds above 0")
        }
        return (.seconds(seconds), nil)
    }

    /// Bumps the launch counter, then starts the check loop. Once per scheduler (one per app
    /// launch): a second call does nothing.
    public func start() {
        guard !started else { return }
        started = true
        let key = ResearchKey.starts(build: build)
        logger.bump(key)
        if let intervalNote { log("Research: \(intervalNote)") }
        log("Research scheduler started (\(build.rawValue) build): \(key) bumped; first check in "
            + "\(Self.seconds(Self.firstCheck)) s, then every \(Self.seconds(interval)) s")
        if !logger.mayWrite {
            log("Research scheduler: the state lease is not held, so research/ is not written (D-36)")
        }
        let logger = logger, inputs = snapshotInputs, sleep = sleep, log = log
        let first = Self.firstCheck, interval = interval
        let t0 = logger.clock.now()
        task = Task.detached(priority: .utility) {
            do {
                try await sleep(first)
                var n = 0
                while !Task.isCancelled {
                    n += 1
                    let outcome = await logger.hourlyCheck(inputs: inputs)
                    let at = Int((logger.clock.now() - t0).rounded())
                    log("Research check \(n) at +\(at) s: \(ResearchScheduler.describe(outcome))")
                    try await sleep(interval)
                }
            } catch {
                // The sleep throws once stop() has cancelled the task: the loop is over.
            }
        }
    }

    /// Cancels the loop and waits for every bump already enqueued (applicationWillTerminate).
    /// A check already running completes; no new one starts.
    public func stop() {
        guard let running = task else { return }
        task = nil
        running.cancel()
        logger.flush()
        log("Research scheduler stopped")
    }

    /// `stop()`, then waits for the loop to end: nothing is written after this returns.
    public func stopAndWait() async {
        let running = task
        stop()
        await running?.value
        logger.flush()
    }

    nonisolated static func describe(_ outcome: SnapshotOutcome) -> String {
        switch outcome {
        case .written(let date): "alive_hours bumped; snapshot written for \(date)"
        case .skippedAlreadyToday: "alive_hours bumped; today's row already written"
        case .failed(let why): "no snapshot: \(why)"
        }
    }

    nonisolated static func seconds(_ d: Duration) -> Int64 {
        d.components.seconds
    }
}

// MARK: - The native-dev-writes annotation (T10)

extension ResearchLogger {
    /// `research/annotations.jsonl` (plan: M01b §3.8): curated, append-only, last line per id wins.
    public var annotationsURL: URL {
        paths.dir.appending(path: "annotations.jsonl", directoryHint: .notDirectory)
    }

    /// The `native-dev-writes` intervention (plan: M01b §3.8, T10), the first day a dev build
    /// writes real data, as one line with the keys in the order of the T9 lines.
    public static func nativeDevWritesAnnotation(date: String, text: String, recorded: String,
                                                 by: String = "user") -> String {
        PyJSON.dumps(.object(JSONObject([
            .init(key: "id", value: .string("native-dev-writes")),
            .init(key: "kind", value: .string("intervention")),
            .init(key: "date", value: .string(date)),
            .init(key: "text", value: .string(text)),
            .init(key: "recorded", value: .string(recorded)),
            .init(key: "by", value: .string(by)),
        ])))
    }

    /// Appends the `native-dev-writes` line to annotations.jsonl; `date` and `recorded`
    /// default to today. Refused without the lease (D-36). NOTHING IN THE APP CALLS THIS:
    /// T10 appends it on the first real run with the user's OK, so the orchestrator runs it
    /// with the user, once. False (and logged) when nothing was written.
    @discardableResult
    public func appendNativeDevWritesAnnotation(text: String, date: String? = nil,
                                                recorded: String? = nil, by: String = "user") -> Bool {
        guard mayWrite else {
            JarvisLog.log("Research annotation: \(UsageError.leaseNotHeld)", category: .research)
            return false
        }
        let today = clock.today()
        let line = Self.nativeDevWritesAnnotation(date: date ?? today, text: text,
                                                  recorded: recorded ?? today, by: by)
        do {
            try MetricsLog(url: annotationsURL).append(line)
            return true
        } catch {
            JarvisLog.log("Research annotation: \(error)", category: .research)
            return false
        }
    }
}
