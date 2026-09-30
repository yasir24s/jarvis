import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// Decision D-36 (plan README): UsageStore and ResearchLogger write a real repo's research/
// only while they hold the InstanceLock state lease, as StateStore does; otherwise the write is
// refused and nothing under the root changes. A "real repo" is StateStore's rule: jarvis.py
// present and not a test Sandbox, so these tests use a real-like temp root. A Sandbox needs no
// lease, but a lease that was given (a sandbox lease) must be held. Also the T10
// native-dev-writes annotation helper, which the app never calls. Never the real dataset.

private let refusal = "not written: the state lease is not held (D-36)"
private let day = "2026-09-29"

/// A logger with its own store over `root`; its log lines go to `log`, never to JarvisLog.
private func logger(_ root: URL, lease: (any StateLease)?, clock: ManualClock,
                    log: LogLines = LogLines()) -> ResearchLogger {
    ResearchLogger(paths: ResearchPaths(here: root), clock: ResearchClock(clock, timeZone: schedulerLondon),
                   sources: FileSnapshotSources(here: root, historyTurns: { 0 }),
                   runtime: { SchedulerFixtures.runtime(.dev) }, lease: lease,
                   git: { _, _ in "" }, host: { SchedulerFixtures.host }, log: { log.record($0) })
}

@Suite("Research writes need the state lease (D-36)")
struct ResearchLeaseTests {
    // MARK: UsageStore

    @Test func usageStoreRefusesARealRootWithoutTheLease() throws {
        let root = try RealLikeResearchRoot(researchDir: false)
        defer { root.remove() }
        let lines = LogLines()
        let store = UsageStore(paths: ResearchPaths(here: root.url),
                               clock: ResearchClock(ManualClock(schedulerMorning), timeZone: schedulerLondon),
                               log: { lines.record($0) })
        #expect(throws: UsageError.leaseNotHeld) {
            try store.bump(ResearchKey.interactions, by: 1, day: day, now: schedulerMorning)
        }
        store.bump(ResearchKey.interactions, by: 1)          // the ResearchCounting path: logged, no throw
        #expect(UsageError.leaseNotHeld.description == refusal)
        #expect(lines.all == ["Research bump: \(refusal)"])
        // Refused before makedirs: not even research/ was created.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path(percentEncoded: false)) == ["jarvis.py"])
    }

    @Test func usageStoreWritesARealRootOnlyWhileTheLeaseIsHeld() throws {
        let root = try RealLikeResearchRoot()
        defer { root.remove() }
        let lease = try root.acquireLease()
        let store = UsageStore(paths: ResearchPaths(here: root.url),
                               clock: ResearchClock(ManualClock(schedulerMorning), timeZone: schedulerLondon),
                               lease: lease, log: { _ in })
        try store.bump(ResearchKey.interactions, by: 1, day: day, now: schedulerMorning)
        let written = fileTree(root.url)
        let usage = try #require(written["research/usage.json"])
        #expect(try PyJSON.loads(usage).objectValue?[day]?.objectValue?[ResearchKey.interactions] == .int(1))

        lease.release()
        #expect(throws: UsageError.leaseNotHeld) {
            try store.bump(ResearchKey.interactions, by: 1, day: day, now: schedulerMorning)
        }
        #expect(fileTree(root.url) == written)
    }

    // MARK: ResearchLogger

    @Test func loggerRefusesEveryWriteToARealRootWithoutTheLease() throws {
        let root = try RealLikeResearchRoot()
        defer { root.remove() }
        let before = fileTree(root.url)
        let lines = LogLines()
        let log = logger(root.url, lease: nil, clock: ManualClock(schedulerMorning), log: lines)

        log.bump(ResearchKey.interactions)
        log.flush()
        #expect(log.snapshot() == .failed(refusal))
        #expect(log.hourlyCheck() == .failed(refusal))
        #expect(log.appendNativeDevWritesAnnotation(text: "stand-in text") == false)
        #expect(fileTree(root.url) == before)
        #expect(lines.all == ["Research bump: \(refusal)", "Research snapshot: \(refusal)",
                              "Research check: \(refusal)", "Research annotation: \(refusal)"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: log.paths.dir.path(percentEncoded: false)).isEmpty)
    }

    @Test func loggerWritesARealRootWhileTheLeaseIsHeldAndStopsWhenItIsLost() throws {
        let root = try RealLikeResearchRoot()
        defer { root.remove() }
        let lease = try root.acquireLease()
        let clock = ManualClock(schedulerMorning)
        let log = logger(root.url, lease: lease, clock: clock)

        #expect(log.hourlyCheck() == .written(date: day))
        log.bump(ResearchKey.interactions)
        log.flush()
        let written = fileTree(root.url)
        #expect(written["research/metrics.jsonl"] != nil)
        #expect(written["research/usage.json"] != nil)

        lease.release()
        clock.advance(86_400)                                 // a new day: a snapshot would be due
        log.bump(ResearchKey.interactions)
        log.flush()
        #expect(log.hourlyCheck() == .failed(refusal))
        #expect(log.snapshot() == .failed(refusal))
        #expect(fileTree(root.url) == written)
    }

    @Test func aSandboxNeedsNoLeaseButAGivenSandboxLeaseMustBeHeld() throws {
        let open = try Sandbox()
        defer { open.remove() }
        #expect(logger(open.root, lease: nil, clock: ManualClock(schedulerMorning)).hourlyCheck() == .written(date: day))

        let box = try Sandbox()
        defer { box.remove() }
        guard case .acquired(let lock) = InstanceLock.tryAcquire(at: box.paths.lockFile, repoRoot: box.root) else {
            Issue.record("could not take the sandbox lock")
            return
        }
        let lease = InstanceLockLease(lock)
        let clock = ManualClock(schedulerMorning)
        let log = logger(box.root, lease: lease, clock: clock)
        #expect(log.hourlyCheck() == .written(date: day))
        let written = fileTree(box.root)

        lease.release()
        clock.advance(86_400)
        #expect(log.hourlyCheck() == .failed(refusal))
        log.bump(ResearchKey.interactions)
        log.flush()
        #expect(fileTree(box.root) == written)
    }

    // MARK: The scheduler

    @MainActor
    @Test func theSchedulerWritesNothingToARealRootWithoutTheLease() async throws {
        let root = try RealLikeResearchRoot()
        defer { root.remove() }
        let lease = try root.acquireLease()                   // held for the StateStore only
        let rig = try SchedulerRig(root: root.url, at: schedulerMorning, budget: 2,
                                   researchLease: nil, stateLease: lease)
        let before = fileTree(root.url)
        try await rig.runUntilParked()

        #expect(fileTree(root.url) == before)
        #expect(rig.lines.all.contains("Research scheduler: the state lease is not held, so research/ is not written (D-36)"))
        #expect(rig.lines.checks == [
            "Research check 1 at +90 s: no snapshot: \(refusal)",
            "Research check 2 at +3690 s: no snapshot: \(refusal)",
        ])
        #expect(rig.inputCalls.value == 0)
        // The launch bump, then both checks, each refused and logged (FIFO on the logger's queue).
        #expect(rig.researchLog.all == ["Research bump: \(refusal)", "Research check: \(refusal)",
                                        "Research check: \(refusal)"])
    }

    @MainActor
    @Test func theSchedulerWritesARealRootWithTheLease() async throws {
        let root = try RealLikeResearchRoot()
        defer { root.remove() }
        let lease = try root.acquireLease()
        let rig = try SchedulerRig(root: root.url, at: schedulerMorning, budget: 2,
                                   researchLease: lease, stateLease: lease)
        try await rig.runUntilParked()

        #expect(try rig.rows().count == 1)
        #expect(described(try rig.counters(day)) == ["starts_swift_dev=1", "alive_hours=2"])
        #expect(!rig.lines.all.contains { $0.contains("D-36") })
        #expect(rig.researchLog.all == ["Research snapshot appended for \(day)."])
    }

    // MARK: The native-dev-writes annotation (T10; the app never calls it)

    @Test func theNativeDevWritesAnnotationAppendsOneLinePerCallAndTheLastWins() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let log = logger(box.root, lease: nil, clock: ManualClock(schedulerMorning))
        #expect(log.appendNativeDevWritesAnnotation(text: "first text"))
        #expect(log.appendNativeDevWritesAnnotation(text: "second text", date: "2026-09-30", recorded: "2026-10-01"))

        let text = try box.read("research/annotations.jsonl")
        #expect(text.hasSuffix("\n"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        try #require(lines.count == 2)
        let objects = try lines.map { try #require(try PyJSON.loads(Data($0.utf8)).objectValue) }
        for o in objects {
            #expect(o.keys == ["id", "kind", "date", "text", "recorded", "by"])
            #expect(o["id"] == .string("native-dev-writes"))
            #expect(o["kind"] == .string("intervention"))
            #expect(o["by"] == .string("user"))
        }
        #expect(objects[0]["date"] == .string(day))
        #expect(objects[0]["recorded"] == .string(day))
        #expect(objects[0]["text"] == .string("first text"))
        #expect(objects[1]["date"] == .string("2026-09-30"))
        #expect(objects[1]["recorded"] == .string("2026-10-01"))
        #expect(objects[1]["text"] == .string("second text"))
        // Python's json.dumps layout, as the T9 lines: ", " and ": " separators, ASCII only.
        #expect(String(lines[0]) == ResearchLogger.nativeDevWritesAnnotation(date: day, text: "first text", recorded: day))
        #expect(String(lines[0]).contains("\"id\": \"native-dev-writes\", \"kind\": \"intervention\", "))
    }
}
