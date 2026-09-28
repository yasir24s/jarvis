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

public final class ResearchLogger: ResearchCounting, Sendable {
    public let paths: ResearchPaths
    public let clock: ResearchClock
    private let store: UsageStore
    private let builder: SnapshotBuilder
    private let queue = DispatchQueue(label: "com.jarvis.assistant.research", qos: .utility)

    /// `git` and `host` are SnapshotBuilder's (tests inject a recorder and a fixed host).
    public init(paths: ResearchPaths, clock: ResearchClock, sources: any SnapshotSources,
                runtime: @escaping @Sendable () -> RuntimeInfo,
                git: @escaping GitProbe.Runner = GitProbe.run,
                host: @escaping @Sendable () -> HostSample = { HostSample.current() }) {
        self.paths = paths
        self.clock = clock
        self.store = UsageStore(paths: paths, clock: clock)
        self.builder = SnapshotBuilder(paths: paths, clock: clock, sources: sources,
                                       runtime: runtime, git: git, host: host)
    }

    /// `research_bump(key, n)`: non-blocking, FIFO on the private queue. Never throws: a
    /// failure is logged as Python logs it and nothing is written.
    public func bump(_ key: String, by n: Int = 1) {
        let now = clock.now()
        let day = clock.localDate(now)
        queue.async { [store] in
            Self.apply(store, key, by: n, day: day, now: now)
        }
    }

    /// Bumps `alive_hours`, then snapshots only if metrics.jsonl's last complete row is not
    /// dated today. Idempotent within a local day.
    public func hourlyCheck() -> SnapshotOutcome {
        let now = clock.now()
        let day = clock.localDate(now)
        return queue.sync {
            Self.apply(store, ResearchKey.aliveHours, by: 1, day: day, now: now)
            guard MetricsLog(paths: paths).lastDate() != day else { return .skippedAlreadyToday }
            return builder.snapshot()
        }
    }

    /// `research_snapshot()` + the schema-2 blocks, after every bump already enqueued.
    public func snapshot() -> SnapshotOutcome {
        queue.sync { builder.snapshot() }
    }

    /// Waits for every enqueued bump (tests and applicationWillTerminate).
    public func flush() {
        queue.sync {}
    }

    private static func apply(_ store: UsageStore, _ key: String, by n: Int, day: String, now: Double) {
        do {
            try store.bump(key, by: n, day: day, now: now)
        } catch {
            JarvisLog.log("Research bump: \(error)", category: .research)
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
