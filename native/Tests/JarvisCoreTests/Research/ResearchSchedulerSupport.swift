import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

// Shared by ResearchSchedulerTests and ResearchLeaseTests (M1b T10, D-36, D-37): virtual time
// for the scheduler, a log recorder, a stand-in for a real repo root, and a rig wired the way
// the app will wire the scheduler. Sandbox or temp-directory roots only.

let schedulerLondon = TimeZone(identifier: "Europe/London")!

/// 2026-09-29 10:00 and 20:00 in London (BST).
let schedulerMorning: Double = 1_790_672_400
let schedulerEvening: Double = 1_790_708_400

enum SchedulerFixtures {
    /// A neutral runtime block; its values are not what these tests check.
    static func runtime(_ build: BuildChannel) -> RuntimeInfo {
        RuntimeInfo(build: build, version: "0.0.0-test", sourceCommit: "0000000", sourceDirty: false,
                    processStarted: schedulerMorning, voice: false, claudeEnabled: false, localModel: nil)
    }

    static let host = HostSample(os: "0.0", osBuild: "0A0", hwModel: "Test1,1", ramBytes: 1 << 33,
                                 footprint: 1 << 20, peakFootprint: 1 << 21)
}

/// Virtual time for the scheduler: a sleep advances the ManualClock by what it asks for and
/// returns at once, so an hour passes in microseconds. After `budget` sleeps have returned,
/// the next one parks until its task is cancelled (the scheduler's stop()).
final class VirtualSleeper: Sendable {
    private struct State {
        var asked: [Duration] = []
        var parked = false
        var cancelled = false
    }

    let clock: ManualClock
    let budget: Int
    private let state = Mutex(State())

    init(clock: ManualClock, budget: Int) {
        self.clock = clock
        self.budget = budget
    }

    /// Every duration asked for, in order, the parked one included.
    var asked: [Duration] { state.withLock { $0.asked } }
    var isParked: Bool { state.withLock { $0.parked } }
    var sawCancellation: Bool { state.withLock { $0.cancelled } }

    func sleep(_ d: Duration) async throws {
        let n = state.withLock { s in
            s.asked.append(d)
            return s.asked.count
        }
        guard n <= budget else {
            state.withLock { $0.parked = true }
            do {
                try await Task.sleep(for: .seconds(600))          // real time: only stop() ends it
            } catch {
                state.withLock { $0.cancelled = true }
                throw error
            }
            throw CancellationError()
        }
        try Task.checkCancellation()
        clock.advance(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

/// The scheduler's injected log.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])

    func record(_ line: String) { lines.withLock { $0.append(line) } }

    var all: [String] { lines.withLock { $0 } }

    /// The per-check lines ("Research check N at +S s: …").
    var checks: [String] { all.filter { $0.hasPrefix("Research check ") } }
}

final class CallCount: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

struct BlankFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}

/// Polls `done` (1 ms apart, real time) until it holds; a test failure after `seconds`.
@MainActor
func until(_ what: String, within seconds: Int64 = 30, _ done: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
    while !done() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out after \(seconds) s waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

/// A temp directory that looks like a real repo root to StateStore's rule (D-36): it has a
/// non-empty jarvis.py and is NOT named like a Sandbox (`jarvis-tests-*`).
final class RealLikeResearchRoot {
    static let prefix = "jarvis-reallike-"
    let url: URL

    init(researchDir: Bool = true) throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: Self.prefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("# stand-in for jarvis.py\n".utf8)
            .write(to: url.appending(path: "jarvis.py", directoryHint: .notDirectory))
        if researchDir {
            try FileManager.default.createDirectory(at: url.appending(path: "research", directoryHint: .isDirectory),
                                                    withIntermediateDirectories: false)
        }
        self.url = url
    }

    /// The InstanceLock on `<root>/.jarvis.lock`, as the app takes it.
    func acquireLease() throws -> InstanceLockLease {
        let outcome = InstanceLock.tryAcquire(at: url.appending(path: ".jarvis.lock", directoryHint: .notDirectory),
                                              repoRoot: url)
        guard case .acquired(let lock) = outcome else {
            Issue.record("could not acquire the lock in \(url.path(percentEncoded: false)): \(outcome)")
            throw CancellationError()
        }
        return InstanceLockLease(lock)
    }

    func remove() {
        precondition(url.lastPathComponent.hasPrefix(Self.prefix))
        try? FileManager.default.removeItem(at: url)
    }
}

/// Every regular file under `root` (relative path → bytes): "nothing was written" is this
/// value unchanged.
func fileTree(_ root: URL) -> [String: Data] {
    let base = root.standardizedFileURL.path(percentEncoded: false)
    var out: [String: Data] = [:]
    guard let walk = FileManager.default.enumerator(atPath: base) else { return out }
    for case let rel as String in walk {
        let full = (base.hasSuffix("/") ? base : base + "/") + rel
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue {
            out[rel] = FileManager.default.contents(atPath: full) ?? Data()
        }
    }
    return out
}

/// The scheduler over `root` at `ts` (Europe/London) on virtual time, wired as the app will
/// wire it: one UsageStore (`store`) that the logger and CoreState both bump through, and the
/// snapshot counts from `core.snapshotInputs()` (D-37), counted in `inputCalls`.
/// `researchLease` goes to the UsageStore (D-36), `stateLease` to the StateStore (a real-like
/// root needs one).
@MainActor
final class SchedulerRig {
    let root: URL
    let paths: ResearchPaths
    let clock: ManualClock
    let store: UsageStore
    let logger: ResearchLogger
    let core: CoreState
    let sleeper: VirtualSleeper
    let lines = LogLines()
    let inputCalls = CallCount()
    let scheduler: ResearchScheduler

    init(root: URL, at ts: Double, budget: Int, build: BuildChannel = .dev,
         environment: [String: String] = [:], researchLease: (any StateLease)? = nil,
         stateLease: (any StateLease)? = nil) throws {
        self.root = root
        paths = ResearchPaths(here: root)
        clock = ManualClock(ts)
        let rclock = ResearchClock(clock, timeZone: schedulerLondon)
        store = UsageStore(paths: paths, clock: rclock, lease: researchLease)
        logger = ResearchLogger(paths: paths, clock: rclock,
                                sources: FileSnapshotSources(here: root, historyTurns: { 0 }),
                                runtime: { SchedulerFixtures.runtime(build) }, store: store,
                                git: { _, _ in "" }, host: { SchedulerFixtures.host })
        let state = try StateStore(root: root.path(percentEncoded: false), lease: stateLease, clock: clock)
        core = CoreState(store: state, clock: clock, research: store, frontApp: BlankFrontApp())
        sleeper = VirtualSleeper(clock: clock, budget: budget)
        let core = core, calls = inputCalls, sleeper = sleeper, lines = lines
        scheduler = ResearchScheduler(store: store, logger: logger, build: build,
                                      snapshotInputs: {
                                          calls.bump()
                                          return await core.snapshotInputs()
                                      },
                                      environment: environment,
                                      sleep: { try await sleeper.sleep($0) },
                                      log: { lines.record($0) })
    }

    /// Starts the scheduler, waits until every budgeted sleep has returned (so every check has
    /// run and logged), then stops it and waits for the loop to end.
    func runUntilParked() async throws {
        scheduler.start()
        try await until("the scheduler to use its \(sleeper.budget) sleeps") { sleeper.isParked }
        await scheduler.stopAndWait()
    }

    /// usage.json's root object (empty when there is no file).
    func usage() throws -> JSONObject {
        guard let data = FileManager.default.contents(atPath: paths.usage.path(percentEncoded: false)) else {
            return JSONObject()
        }
        return try #require(try PyJSON.loads(data).objectValue)
    }

    /// One day's counters as (key, value) pairs in file order.
    func counters(_ day: String) throws -> [(String, JSONValue)] {
        try (usage()[day]?.objectValue?.members ?? []).map { ($0.key, $0.value) }
    }

    func rows() throws -> [JSONObject] {
        guard let data = FileManager.default.contents(atPath: paths.metrics.path(percentEncoded: false)) else {
            return []
        }
        return try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try #require(try PyJSON.loads(Data($0.utf8)).objectValue)
        }
    }
}

/// `counters(day)` as comparable text: "key=value" in file order.
func described(_ pairs: [(String, JSONValue)]) -> [String] {
    pairs.map { "\($0.0)=\(PyJSON.dumps($0.1))" }
}
