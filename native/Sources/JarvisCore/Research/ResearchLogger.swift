import Foundation

// The dataset façade (plan: M01b §3.2). One private serial queue — the analogue of
// jarvis.py's _research_lock (2449) — runs every read-modify-write of usage.json and
// metrics.jsonl, so the two files are only ever touched in call order:
//
//   bump         research_bump (2451–2464): queue.async, so callers on the audio/main threads
//                never block on disk. The day and `now` are read from the clock at the CALL,
//                as Python's time.strftime is, so the file equals the same bumps applied
//                synchronously in order (first-bump key order, exact sums), even across midnight.
//   hourlyCheck  one research_log_loop iteration (2569–2578), plus the native-only schema-2
//                `alive_hours` bump: snapshot only if the last row's date is not today.
//   snapshot     research_snapshot (2484–2522) + schema-2 blocks: SnapshotBuilder builds and
//                appends the row; nothing here builds one.
//
// UsageStore (D1, D3), MetricsLog (D2, D4) and SnapshotBuilder (D5) own the file formats and
// the deviations; this class only orders the calls. Cross-process exclusion is M0's guard.
//
// Decision D-36: a real repo's research/ is written only while the InstanceLock state lease is
// held (UsageStore's rule, the same as StateStore's); otherwise a bump, check or snapshot is
// refused and logged, and nothing is written. Decision D-37: `hourlyCheck(inputs:)` and
// `snapshot(inputs:)` count corrections and history turns from CoreState's memory, not files.

public final class ResearchLogger: ResearchCounting, Sendable {
    public let paths: ResearchPaths
    public let clock: ResearchClock
    /// Every bump goes through this one UsageStore. Its Mutex is what makes usage.json's
    /// read-modify-write atomic, and only within one instance, so the app gives the logger the
    /// same instance everything else bumps (a second instance over the file could lose bumps).
    public let store: UsageStore
    private let builder: SnapshotBuilder
    private let queue = DispatchQueue(label: "com.jarvis.assistant.research", qos: .utility)
    /// The logger's and its snapshots' log lines (JarvisLog by default; tests pass a recorder).
    let log: @Sendable (String) -> Void

    /// The app's wiring: `store` is the process's one UsageStore over `paths.usage`, and it
    /// carries the InstanceLock state lease (D-36). `git` and `host` are SnapshotBuilder's
    /// (tests inject a recorder and a fixed host).
    public init(paths: ResearchPaths, clock: ResearchClock, sources: any SnapshotSources,
                runtime: @escaping @Sendable () -> RuntimeInfo, store: UsageStore,
                git: @escaping GitProbe.Runner = GitProbe.run,
                host: @escaping @Sendable () -> HostSample = { HostSample.current() },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .research) }) {
        precondition(store.url.standardizedFileURL.path(percentEncoded: false)
                     == paths.usage.standardizedFileURL.path(percentEncoded: false),
                     "ResearchLogger: the UsageStore must be over paths.usage")
        self.paths = paths
        self.clock = clock
        self.store = store
        self.log = log
        self.builder = SnapshotBuilder(paths: paths, clock: clock, sources: sources,
                                       runtime: runtime, git: git, host: host, log: log)
    }

    /// A logger with a UsageStore of its own over `paths.usage`, for tests and tools that
    /// bump nothing else. `lease` is the InstanceLock state lease (D-36): required for a real
    /// repo root, and once given it must be held for any root.
    public convenience init(paths: ResearchPaths, clock: ResearchClock, sources: any SnapshotSources,
                            runtime: @escaping @Sendable () -> RuntimeInfo,
                            lease: (any StateLease)? = nil,
                            git: @escaping GitProbe.Runner = GitProbe.run,
                            host: @escaping @Sendable () -> HostSample = { HostSample.current() },
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .research) }) {
        self.init(paths: paths, clock: clock, sources: sources, runtime: runtime,
                  store: UsageStore(paths: paths, clock: clock, lease: lease, log: log),
                  git: git, host: host, log: log)
    }

    /// D-36: false while research/ may not be written (the store's lease rule).
    var mayWrite: Bool { store.mayWrite }

    /// `research_bump(key, n)`: non-blocking, FIFO on the private queue. Never throws: a
    /// failure is logged as Python logs it and nothing is written.
    public func bump(_ key: String, by n: Int = 1) {
        let now = clock.now()
        let day = clock.localDate(now)
        queue.async { [store, log] in
            Self.apply(store, key, by: n, day: day, now: now, log: log)
        }
    }

    /// Bumps `alive_hours`, then snapshots only if metrics.jsonl's last complete row is not
    /// dated today. Idempotent within a local day.
    public func hourlyCheck() -> SnapshotOutcome {
        let now = clock.now()
        let day = clock.localDate(now)
        return queue.sync {
            if let refused = refusal("Research check") { return refused }
            Self.apply(store, ResearchKey.aliveHours, by: 1, day: day, now: now, log: log)
            guard MetricsLog(paths: paths).lastDate() != day else { return .skippedAlreadyToday }
            return builder.snapshot()
        }
    }

    /// `hourlyCheck()` with D-37: `inputs` (the app passes `CoreState.snapshotInputs`) is
    /// awaited only when a row is due, as research_log_loop calls research_snapshot (and so
    /// `_corrections_load`) only then, and its two counts go into the row.
    public func hourlyCheck(inputs: () async -> CoreSnapshotInputs) async -> SnapshotOutcome {
        let now = clock.now()
        let day = clock.localDate(now)
        let due: SnapshotOutcome? = queue.sync {
            if let refused = refusal("Research check") { return refused }
            Self.apply(store, ResearchKey.aliveHours, by: 1, day: day, now: now, log: log)
            return MetricsLog(paths: paths).lastDate() != day ? nil : .skippedAlreadyToday
        }
        if let due { return due }
        let counts = await inputs()
        return snapshot(inputs: counts)
    }

    /// `research_snapshot()` + the schema-2 blocks, after every bump already enqueued.
    /// `inputs`: CoreState's in-memory corrections and history counts (D-37).
    public func snapshot(inputs: CoreSnapshotInputs? = nil) -> SnapshotOutcome {
        queue.sync {
            if let refused = refusal("Research snapshot") { return refused }
            return builder.snapshot(inputs: inputs)
        }
    }

    /// Waits for every enqueued bump (tests and applicationWillTerminate).
    public func flush() {
        queue.sync {}
    }

    /// D-36: `.failed` (logged under `what`) when research/ may not be written now, else nil.
    /// Checked on the queue, before anything is read or written.
    private func refusal(_ what: String) -> SnapshotOutcome? {
        guard !store.mayWrite else { return nil }
        let why = UsageError.leaseNotHeld.description
        log("\(what): \(why)")
        return .failed(why)
    }

    private static func apply(_ store: UsageStore, _ key: String, by n: Int, day: String, now: Double,
                              log: @Sendable (String) -> Void) {
        do {
            try store.bump(key, by: n, day: day, now: now)
        } catch {
            log("Research bump: \(error)")
        }
    }
}

// MARK: - TTS counters

extension ResearchLogger {
    /// How one synthesis request ended. The shape is the tts_* invariant (M01b counter table):
    /// exactly one engine, at most one fallback reason, and a fallback only ever ends in Piper,
    /// so `tts_piper >= Σ tts_fallback_*` holds per day by construction.
    public enum TTSOutcome: Sendable, Equatable {
        case elevenLabs
        case piper(fallback: TTSFallbackReason?)
    }

    /// The counter names one synthesis request bumps, in bump order. Names only: when they are
    /// bumped, and `tts_chars_elevenlabs` (counted per transmitted body), belong to M8.
    public static func ttsCounters(_ outcome: TTSOutcome) -> [String] {
        switch outcome {
        case .elevenLabs: [ResearchKey.ttsElevenLabs]
        case .piper(nil): [ResearchKey.ttsPiper]
        case .piper(let reason?): [ResearchKey.ttsPiper, ResearchKey.ttsFallback(reason)]
        }
    }
}
