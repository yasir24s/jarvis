import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

// A5 (plan: M01b §5): the ResearchLogger façade. D1–D5 are unit-tested in UsageStore,
// MetricsLog and SnapshotBuilder; here they are asserted THROUGH the façade, with the queue's
// FIFO contract (bytes equal to the same bumps applied synchronously with UsageStore),
// hourlyCheck's once-a-day rule across midnight and both London DST changes, and a check that
// no URL the logger resolves lies in the real dataset. Sandbox only.

private let london = TimeZone(identifier: "Europe/London")!

// MARK: - The real dataset is never a test path

/// realpath(3) of the longest existing prefix of `url`, with the rest appended: the path the
/// kernel would open, also for a file not created yet.
private func realPath(_ url: URL) -> String {
    var head = url.standardizedFileURL
    var rest: [String] = []
    while true {
        if let r = realpath(head.path(percentEncoded: false), nil) {
            defer { free(r) }
            var base = String(cString: r)
            if base.hasSuffix("/") { base.removeLast() }
            return ([base] + rest.reversed()).joined(separator: "/")
        }
        let parent = head.deletingLastPathComponent()
        if parent.path(percentEncoded: false) == head.path(percentEncoded: false) {
            return head.path(percentEncoded: false)
        }
        rest.append(head.lastPathComponent)
        head = parent
    }
}

/// `$HOME/jarvis/research` (and the account's home, should HOME be overridden), real paths.
private let realDatasets: [String] = {
    var homes = [FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false), NSHomeDirectory()]
    if let home = ProcessInfo.processInfo.environment["HOME"] { homes.append(home) }
    return Set(homes.map { realPath(URL(filePath: $0, directoryHint: .isDirectory)
            .appending(path: "jarvis/research", directoryHint: .isDirectory)) }).sorted()
}()

private func underRealDataset(_ url: URL) -> Bool {
    let mine = realPath(url)
    return realDatasets.contains { mine == $0 || mine.hasPrefix($0 + "/") }
}

private func requireOutsideRealDataset(_ url: URL) throws {
    try #require(!underRealDataset(url), "test path resolves into the real dataset: \(realPath(url))")
}

/// Every URL the logger (and the snapshot sources over the same root) resolves.
private func resolvedURLs(_ logger: ResearchLogger, now: Double) -> [URL] {
    let p = logger.paths
    return [p.here, p.dir, p.usage, p.metrics, p.jarvisPy, p.voiceprint, p.nativeSources,
            p.usageQuarantine(unix: Int(now)), p.state.personality, p.state.emotions,
            p.state.profile, p.state.corrections, p.state.knowledge]
}

// MARK: - Harness

/// A logger over a fresh Sandbox at `ts` (Europe/London), with every URL it resolves
/// checked first. git and the host are injected; the runtime is the golden runs' fixed one.
private struct Harness {
    let box: Sandbox
    let paths: ResearchPaths
    let clock: ManualClock
    let logger: ResearchLogger

    init(at ts: Double, turns: @escaping @Sendable () -> Int = { 0 }) throws {
        box = try Sandbox()
        paths = ResearchPaths(box.paths)
        clock = ManualClock(ts)
        logger = ResearchLogger(paths: paths, clock: ResearchClock(clock, timeZone: london),
                                sources: FileSnapshotSources(here: box.root, historyTurns: turns),
                                runtime: { SnapshotGoldenTests.fixedRuntime }, git: { _, _ in "" },
                                host: { SnapshotGoldenTests.fixedHost })
        for url in resolvedURLs(logger, now: ts) {
            try requireOutsideRealDataset(url)
            try #require(realPath(url).hasPrefix(realPath(box.root) + "/") || realPath(url) == realPath(box.root))
        }
    }

    func usage() -> Data? { contents(paths.usage) }

    func usageDay(_ day: String) -> JSONObject? {
        guard let data = usage(), case .object(let root)? = try? PyJSON.loads(data) else { return nil }
        return root[day]?.objectValue
    }

    func rows() throws -> [JSONObject] {
        try box.read("research/metrics.jsonl").split(separator: "\n").map {
            try #require(try PyJSON.loads(Data($0.utf8)).objectValue)
        }
    }
}

private func contents(_ url: URL) -> Data? {
    FileManager.default.contents(atPath: url.path(percentEncoded: false))
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []).sorted()
}

private struct Bump: Sendable {
    let key: String
    let n: Int
    var at: Double
}

/// The same bumps applied synchronously, in order, with UsageStore directly (the clock set to
/// each bump's time), in a Sandbox of its own seeded with `seed` as usage.json.
private func reference(_ bumps: [Bump], seed: String? = nil) throws -> (usage: Data?, names: [String]) {
    let box = try Sandbox()
    defer { box.remove() }
    let paths = ResearchPaths(box.paths)
    try requireOutsideRealDataset(paths.usage)
    if let seed { try box.write("research/usage.json", seed) }
    let clock = ManualClock(0)
    let store = UsageStore(paths: paths, clock: ResearchClock(clock, timeZone: london))
    for b in bumps {
        clock.set(b.at)
        store.bump(b.key, by: b.n)
    }
    return (contents(paths.usage), names(paths.dir))
}

private final class Recorder: Sendable {
    let log = Mutex<[Bump]>([])
    let outcome = Mutex<SnapshotOutcome?>(nil)
}

// MARK: - Tests

@Suite("ResearchLogger: ordered bumps and the daily snapshot (A5)")
struct ResearchLoggerTests {
    static let ts = 1786525200.25                        // 2026-08-12 10:00:00.25 BST
    static let lastSecond = 1786575599.5                 // 2026-08-12 23:59:59.5 BST
    static let firstSecond = 1786575600.5                // 2026-08-13 00:00:00.5 BST

    // MARK: ResearchCounting

    @Test func handsToCoreStateAsResearchCounting() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        let counting: any ResearchCounting = h.logger
        counting.bump(ResearchKey.interactions, by: 2)
        h.logger.bump(ResearchKey.userCorrection)          // n defaults to 1, like research_bump
        h.logger.bump(ResearchKey.interactions)
        h.logger.flush()
        #expect(h.usage() == (try reference([Bump(key: "interactions", n: 2, at: Self.ts),
                                             Bump(key: "user_correction", n: 1, at: Self.ts),
                                             Bump(key: "interactions", n: 1, at: Self.ts)]).usage))
        #expect(h.usageDay("2026-08-12")?.keys == ["interactions", "user_correction"])
        #expect(h.usageDay("2026-08-12")?["interactions"] == .int(3))
    }

    // MARK: FIFO

    /// 40 tasks × 25 bumps over 23 keys. Each bump is logged and enqueued inside one lock, so
    /// the log's order IS the enqueue order; the file must equal that sequence applied
    /// synchronously: exact sums, keys in first-enqueue order, identical bytes.
    @Test func thousandConcurrentBumpsKeepEnqueueOrder() async throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        let rec = Recorder()
        let logger = h.logger
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<40 {
                group.addTask {
                    for i in 0..<25 {
                        let b = Bump(key: "fifo_\((t * 7 + i * 3) % 23)", n: 1 + (t + i) % 3, at: Self.ts)
                        rec.log.withLock { log in
                            log.append(b)
                            logger.bump(b.key, by: b.n)
                        }
                    }
                }
            }
        }
        logger.flush()
        let enqueued = rec.log.withLock { $0 }
        try #require(enqueued.count == 1000)

        var firstOrder: [String] = []
        var sums: [String: Int] = [:]
        for b in enqueued {
            if sums[b.key] == nil { firstOrder.append(b.key) }
            sums[b.key, default: 0] += b.n
        }
        let day = try #require(h.usageDay("2026-08-12"))
        #expect(day.keys == firstOrder, "first-bump key order == first-enqueue order")
        #expect(day.keys.count == 23)
        for key in firstOrder {
            #expect(day[key] == .int(Int64(sums[key]!)), "\(key)")
        }
        let total = day.members.reduce(Int64(0)) { acc, m in
            if case .int(let v) = m.value { acc + v } else { acc }
        }
        #expect(total == Int64(enqueued.reduce(0) { $0 + $1.n }))
        #expect(h.usage() == (try reference(enqueued).usage), "bytes == synchronous UsageStore reference")
        #expect(names(h.paths.dir) == ["usage.json"])
    }

    /// No lock around the callers: the queue alone must lose no update.
    @Test func unsynchronisedCallersLoseNoBump() async throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        let logger = h.logger
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<50 {
                group.addTask {
                    for i in 0..<20 { logger.bump("free_\((t + i) % 5)", by: 1 + i % 2) }
                }
            }
        }
        logger.flush()
        let day = try #require(h.usageDay("2026-08-12"))
        #expect(Set(day.keys) == Set((0..<5).map { "free_\($0)" }))
        // per key: 50 × 20 bumps spread evenly over 5 keys, n alternating 1, 2 with i.
        var expected: [String: Int64] = [:]
        for t in 0..<50 { for i in 0..<20 { expected["free_\((t + i) % 5)", default: 0] += Int64(1 + i % 2) } }
        for (key, sum) in expected { #expect(day[key] == .int(sum), "\(key)") }
    }

    /// A snapshot holds the queue (its history source blocks). bump must return anyway,
    /// write nothing yet, and date each bump by the clock at the CALL — the second one is
    /// made after midnight while both still wait behind the snapshot.
    @Test(.timeLimit(.minutes(1)))
    func bumpNeverWaitsAndDatesTheCall() throws {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let h = try Harness(at: Self.lastSecond, turns: { entered.signal(); gate.wait(); return 0 })
        defer { h.box.remove() }
        let rec = Recorder()
        let logger = h.logger
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let o = logger.snapshot()
            rec.outcome.withLock { $0 = o }
            done.signal()
        }
        try #require(entered.wait(timeout: .now() + 20) == .success, "snapshot reached the queue")

        logger.bump(ResearchKey.interactions)                 // 23:59:59.5, the queue is busy
        h.clock.set(Self.firstSecond)
        logger.bump(ResearchKey.interactions, by: 2)          // 00:00:00.5 next day
        #expect(!FileManager.default.fileExists(atPath: h.paths.usage.path(percentEncoded: false)),
                "nothing written while the snapshot holds the queue")

        gate.signal()
        try #require(done.wait(timeout: .now() + 20) == .success)
        logger.flush()
        #expect(rec.outcome.withLock { $0 } == .written(date: "2026-08-12"))
        #expect(try h.rows().first?["usage_today"] == .object(JSONObject()), "bumps enqueued after it")
        #expect(h.usage() == (try reference([Bump(key: "interactions", n: 1, at: Self.lastSecond),
                                             Bump(key: "interactions", n: 2, at: Self.firstSecond)]).usage))
        #expect(h.usageDay("2026-08-12")?["interactions"] == .int(1))
        #expect(h.usageDay("2026-08-13")?["interactions"] == .int(2))
    }

    // MARK: D1–D5 through the façade

    @Test func d1UnparseableUsageIsKeptThenReplacedLikePython() throws {
        let garbage = #"{"2026-08-11": {"interactions": 4}"#     // truncated: json.load raises
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        try h.box.write("research/usage.json", garbage)
        h.logger.bump(ResearchKey.interactions)
        h.logger.flush()

        let quarantine = h.paths.usageQuarantine(unix: Int(Self.ts))
        try requireOutsideRealDataset(quarantine)
        #expect(contents(quarantine) == Data(garbage.utf8), "original bytes kept")
        let ref = try reference([Bump(key: "interactions", n: 1, at: Self.ts)], seed: garbage)
        #expect(h.usage() == ref.usage, "today only, as Python writes it")
        #expect(names(h.paths.dir) == ref.names)
        #expect(names(h.paths.dir) == ["usage.json", "usage.json.corrupt-1786525200"])
    }

    @Test func d2LastRowLongerThan8KiBStillCountsAsToday() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        let long = PyJSON.dumps(.object(JSONObject([.init(key: "date", value: .string("2026-08-12")),
                                                    .init(key: "pad", value: .string(String(repeating: "x", count: 9000)))])))
        try #require(long.utf8.count > 8192, "Python's 8 KiB tail would miss the date")
        try h.box.write("research/metrics.jsonl", long + "\n")
        #expect(h.logger.hourlyCheck() == .skippedAlreadyToday)
        #expect(try h.box.read("research/metrics.jsonl") == long + "\n", "no duplicate row")
        #expect(h.usageDay("2026-08-12")?["alive_hours"] == .int(1))
    }

    @Test func d3UsageIsReplacedByRenameWithNoTempLeft() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        h.logger.bump(ResearchKey.interactions)
        h.logger.flush()
        var st = stat()
        try #require(stat(h.paths.usage.path(percentEncoded: false), &st) == 0)
        let first = st.st_ino
        h.logger.bump(ResearchKey.interactions)
        h.logger.flush()
        try #require(stat(h.paths.usage.path(percentEncoded: false), &st) == 0)
        #expect(st.st_ino != first, "rename(2), not rewritten in place")
        #expect(names(h.paths.dir) == ["usage.json"])
    }

    @Test func d4RowAfterADanglingFragmentStartsOnItsOwnLine() throws {
        let fragment = #"{"ts": 1786400000.0, "date": "2026-08-1"#
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        try h.box.write("research/metrics.jsonl", fragment)
        #expect(h.logger.hourlyCheck() == .written(date: "2026-08-12"))
        let text = try h.box.read("research/metrics.jsonl")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[0] == fragment && lines[2].isEmpty, "fragment, row, final newline")
        #expect(try PyJSON.loads(Data(lines[1].utf8)).objectValue?["date"] == .string("2026-08-12"))
        #expect(h.logger.hourlyCheck() == .skippedAlreadyToday, "the row, not the fragment, is last")
    }

    @Test func d5MissingJarvisPyStillWritesARow() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        try FileManager.default.removeItem(at: h.paths.jarvisPy)
        #expect(h.logger.snapshot() == .written(date: "2026-08-12"))
        let code = try #require(try h.rows().first?["code"]?.objectValue)
        #expect(code["bytes"] == .null && code["lines"] == .null)
    }

    // MARK: snapshot

    /// The appended line is SnapshotBuilder's row on the same inputs, in the Sandbox, and it
    /// sees bumps enqueued before it without a flush.
    @Test func snapshotAppendsSnapshotBuildersRowInTheSandbox() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        try h.box.write("jarvis.py", "print(1)\nprint(2)\n")
        h.logger.bump(ResearchKey.interactions, by: 3)
        #expect(h.logger.snapshot() == .written(date: "2026-08-12"))

        try #require(realPath(h.paths.metrics).hasPrefix(realPath(h.box.root) + "/"))
        let builder = SnapshotBuilder(paths: h.paths, clock: ResearchClock(h.clock, timeZone: london),
                                      sources: FileSnapshotSources(here: h.box.root, historyTurns: { 0 }),
                                      runtime: { SnapshotGoldenTests.fixedRuntime }, git: { _, _ in "" },
                                      host: { SnapshotGoldenTests.fixedHost })
        let expected = PyJSON.dumps(.object(try builder.row(now: Self.ts).row)) + "\n"
        #expect(try h.box.read("research/metrics.jsonl") == expected)

        let row = try #require(try h.rows().first)
        #expect(row.keys == SnapshotBuilder.schema1Keys + SnapshotBuilder.schema2Keys)
        #expect(row["usage_today"] == .object(JSONObject([.init(key: "interactions", value: .int(3))])))
        #expect(row["code"]?.objectValue?["lines"] == .int(2))
    }

    // MARK: hourlyCheck

    @Test func hourlyCheckSnapshotsOncePerDayThenAgainAfterMidnight() throws {
        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        #expect(h.logger.hourlyCheck() == .written(date: "2026-08-12"))
        h.clock.advance(3600)
        #expect(h.logger.hourlyCheck() == .skippedAlreadyToday)
        h.clock.set(Self.lastSecond)
        #expect(h.logger.hourlyCheck() == .skippedAlreadyToday)
        h.clock.set(Self.firstSecond)
        #expect(h.logger.hourlyCheck() == .written(date: "2026-08-13"))
        h.clock.advance(3600)
        #expect(h.logger.hourlyCheck() == .skippedAlreadyToday)

        let rows = try h.rows()
        #expect(rows.map { $0["date"] } == [.string("2026-08-12"), .string("2026-08-13")])
        let aliveFirst = JSONValue.object(JSONObject([.init(key: "alive_hours", value: .int(1))]))
        #expect(rows.map { $0["usage_today"] } == [aliveFirst, aliveFirst], "bumped before the snapshot")
        #expect(h.usageDay("2026-08-12")?["alive_hours"] == .int(3))
        #expect(h.usageDay("2026-08-13")?["alive_hours"] == .int(2))
    }

    struct DSTCase: Sendable, CustomTestStringConvertible {
        let name: String
        let start: Double            // local midnight of the first day
        let dates: [String]
        let hours: [Int]             // local hours in each day
        let offsets: [String]        // runtime.utc_offset of each day's snapshot (00:00:30 local)
        var testDescription: String { name }
    }

    static let dst = [
        DSTCase(name: "BST ends 25 Oct 2026", start: 1792796400,
                dates: ["2026-10-24", "2026-10-25", "2026-10-26"], hours: [24, 25, 24],
                offsets: ["+0100", "+0100", "+0000"]),
        DSTCase(name: "BST starts 29 Mar 2026", start: 1774656000,
                dates: ["2026-03-28", "2026-03-29", "2026-03-30"], hours: [24, 23, 24],
                offsets: ["+0000", "+0000", "+0100"]),
    ]

    /// Hourly ticks (30 s past each hour) over three local days around a DST change: one row
    /// per local date, written on each day's first tick, and alive_hours == the day's length.
    @Test(arguments: ResearchLoggerTests.dst)
    func hourlyCheckAcrossMidnightAndDST(_ c: DSTCase) throws {
        let h = try Harness(at: c.start + 30)
        defer { h.box.remove() }
        var written: [(tick: Int, date: String)] = []
        for tick in 0..<c.hours.reduce(0, +) {
            h.clock.set(c.start + 30 + 3600 * Double(tick))
            switch h.logger.hourlyCheck() {
            case .written(let date): written.append((tick, date))
            case .skippedAlreadyToday: break
            case .failed(let why): Issue.record("tick \(tick): \(why)")
            }
        }
        #expect(written.map(\.date) == c.dates)
        #expect(written.map(\.tick) == [0, c.hours[0], c.hours[0] + c.hours[1]])
        for (date, hours) in zip(c.dates, c.hours) {
            #expect(h.usageDay(date)?["alive_hours"] == .int(Int64(hours)), "\(date)")
        }
        let rows = try h.rows()
        #expect(rows.map { $0["date"]?.stringValue } == c.dates)
        #expect(rows.map { $0["runtime"]?.objectValue?["utc_offset"]?.stringValue } == c.offsets)
    }

    // MARK: TTS invariant

    @Test func ttsCountersKeepTheInvariantByConstruction() throws {
        let outcomes: [ResearchLogger.TTSOutcome] = [.elevenLabs, .piper(fallback: nil)]
            + TTSFallbackReason.allCases.map { .piper(fallback: $0) }
        for o in outcomes {
            let names = ResearchLogger.ttsCounters(o)
            #expect(names.filter { $0 == "tts_elevenlabs" || $0 == "tts_piper" }.count == 1, "\(o)")
            let fallbacks = names.filter { $0.hasPrefix("tts_fallback_") }
            #expect(fallbacks.count <= 1, "\(o)")
            if !fallbacks.isEmpty { #expect(names.contains("tts_piper"), "a fallback ends in Piper") }
        }
        #expect(ResearchLogger.ttsCounters(.elevenLabs) == ["tts_elevenlabs"])
        #expect(ResearchLogger.ttsCounters(.piper(fallback: nil)) == ["tts_piper"])
        #expect(ResearchLogger.ttsCounters(.piper(fallback: .sensitive)) == ["tts_piper", "tts_fallback_sensitive"])

        let h = try Harness(at: Self.ts)
        defer { h.box.remove() }
        for o in outcomes { for key in ResearchLogger.ttsCounters(o) { h.logger.bump(key) } }
        h.logger.flush()
        let day = try #require(h.usageDay("2026-08-12"))
        let fallbackSum = day.members.filter { $0.key.hasPrefix("tts_fallback_") }.reduce(Int64(0)) { acc, m in
            if case .int(let v) = m.value { acc + v } else { acc }
        }
        #expect(day["tts_elevenlabs"] == .int(1))
        #expect(day["tts_piper"] == .int(Int64(1 + TTSFallbackReason.allCases.count)))
        #expect(fallbackSum == Int64(TTSFallbackReason.allCases.count))
        if case .int(let piper)? = day["tts_piper"] { #expect(piper >= fallbackSum, "tts_piper >= Σ tts_fallback_*") }
    }

    // MARK: the guard itself

    @Test func realDatasetGuardRecognisesTheRealPaths() {
        #expect(!realDatasets.isEmpty)
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let real = URL(filePath: home, directoryHint: .isDirectory).appending(path: "jarvis/research")
        #expect(underRealDataset(real))
        #expect(underRealDataset(real.appending(path: "usage.json")))
        #expect(underRealDataset(real.appending(path: "usage.json.corrupt-1")))
        #expect(!underRealDataset(URL(filePath: home).appending(path: "jarvis/research2/usage.json")))
        #expect(!underRealDataset(FileManager.default.temporaryDirectory.appending(path: "jarvis/research/usage.json")))
    }
}
