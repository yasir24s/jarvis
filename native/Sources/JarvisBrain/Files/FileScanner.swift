import Foundation
import JarvisCore
import Synchronization

/// The background understanding of the user's files (D-51 P3). One file at a time, at
/// background priority:
///
/// 1. `FileWalk` finds the documents in the home folder and iCloud Drive.
/// 2. A file whose size and modification time match its settled index entry is passed over
///    without being opened, and so is one whose bytes hash to the digest it had (it was only
///    touched), or to a document already read (a copy).
/// 3. Otherwise its text is extracted (capped), and `FileFactReader` redacts it, routes it,
///    reads it for facts and merges them with `source: file:<digest>`.
/// 4. The outcome goes into memory/files-index.json, saved atomically under the lease after
///    every model read and every `saveEvery` other changes. Without the lease nothing is
///    read: the index is saved before a pass starts.
///
/// Between files it backs off while the thermal state is serious or Low Power Mode is on,
/// and every read waits while a turn runs. After a pass, files left waiting for Claude's
/// hourly allowance are read as it frees up; the next walk starts `rewalkInterval` after the
/// pass ended and reads only new or changed files. Logs carry counts and digest prefixes,
/// never a path, text or fact.
public actor FileScanner {
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Now = @Sendable () -> SuspendingClock.Instant

    /// The wait after `start()` before the first pass, so app startup settles first.
    public static let startDelay: Duration = .seconds(120)
    /// From the end of one pass to the start of the next.
    public static let rewalkInterval: Duration = .seconds(6 * 3600)
    /// How long to wait before looking again while the Mac is hot or in Low Power Mode.
    public static let backoffInterval: Duration = .seconds(60)
    /// The pause after each file that had to be opened.
    public static let pause: Duration = .milliseconds(250)
    /// Index changes that did not involve a model are saved in batches of this many.
    public static let saveEvery = 50

    /// One pass, in counts.
    public struct PassSummary: Sendable, Equatable {
        public var completed = false       // the walk reached its end
        public var documents = 0
        public var unchanged = 0
        public var readOnDevice = 0
        public var readByClaude = 0
        public var empty = 0
        public var unreadable = 0
        public var duplicates = 0
        public var waiting = 0
        public var failed = 0
        public var cut = 0                 // texts cut at the cap
        public var factsAdded = 0
        public var factsUpdated = 0
        public var removed = 0             // index entries for files no longer found
        public var walkSkipped: [FileSkip: Int] = [:]

        public init() {}
    }

    private enum Step {
        case next          // carry on
        case stop          // cancelled, or nothing more can be saved
    }

    private struct Life {
        var task: Task<Void, Never>?
        var stopped = false
    }

    private let home: URL
    private let stateRoot: URL
    private let indexStore: FileIndexStore
    private let extractors: TextExtractors
    private let reader: FileFactReader
    private let quota: ClaudeReadQuota
    private let turns: TurnActivity
    private let probe: any FileSystemProbe
    private let conditions: @Sendable () -> PowerConditions
    private let clock: any JarvisClock
    private let now: Now
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    private let life = Mutex(Life())

    private var index = FileIndex()
    private var loaded = false
    private var readByDigest: [String: String] = [:]   // digest → path, for entries read
    private var unsaved = 0
    private var waitingForClaude: [FileCandidate] = []
    private var backingOff = false
    private var passes = 0

    /// - Parameters:
    ///   - home: the folder to walk (with iCloud Drive inside it). The app passes the user's
    ///     home folder; tests pass a temp tree.
    ///   - store: the lease-holding store the index is written through.
    ///   - reader: the reader; `quota` and `turns` must be the ones it was given.
    ///   - conditions: the thermal state and Low Power Mode.
    ///   - now, sleep: the SuspendingClock and its sleep. Tests pass their own.
    public init(home: URL, stateRoot: URL, store: StateStore, extractors: TextExtractors, reader: FileFactReader,
                quota: ClaudeReadQuota, turns: TurnActivity, probe: any FileSystemProbe = LiveFileSystemProbe(),
                conditions: @escaping @Sendable () -> PowerConditions = PowerConditions.current,
                clock: any JarvisClock = SystemClock(),
                now: @escaping Now = { SuspendingClock().now },
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.home = home
        self.stateRoot = stateRoot
        self.indexStore = FileIndexStore(store: store)
        self.extractors = extractors
        self.reader = reader
        self.quota = quota
        self.turns = turns
        self.probe = probe
        self.conditions = conditions
        self.clock = clock
        self.now = now
        self.sleep = sleep
        self.log = log
    }

    // MARK: - Lifecycle

    /// Starts the background loop: `startDelay`, a pass, the waiting files, then a pass every
    /// `rewalkInterval` after the last one ended. Once per scanner; nothing after `stop()`.
    public nonisolated func start() {
        let started = life.withLock { l -> Bool in
            guard l.task == nil, !l.stopped else { return false }
            l.task = Task.detached(priority: .background) { [self] in
                await self.run()
            }
            return true
        }
        if started { log("files: scanner started; first pass in \(Self.startDelay.components.seconds) s") }
    }

    /// Cancels the loop and waits for it to save the index and end (at quit, before the lock
    /// is released). A read in flight is cancelled with it and writes nothing.
    public nonisolated func stop() async {
        let task = life.withLock { l -> Task<Void, Never>? in
            l.stopped = true
            return l.task
        }
        guard let task else { return }
        task.cancel()
        await task.value
    }

    private func run() async {
        do {
            try await sleep(Self.startDelay)
            while !Task.isCancelled {
                let summary = await pass()
                let next = now().advanced(by: Self.rewalkInterval)
                if summary.completed { try await readWaiting(before: next) }
                let rest = now().duration(to: next)
                if rest > .zero { try await sleep(rest) }
            }
        } catch {
            // The sleep throws once stop() has cancelled the task: the loop is over.
        }
        saveIfNeeded()
    }

    // MARK: - A pass

    /// One walk: every new or changed document read, the index saved. Tests call it directly.
    @discardableResult
    public func pass() async -> PassSummary {
        var summary = PassSummary()
        loadIndex()
        guard indexStore.save(index) else {
            log("files: index not saved (no lease); nothing read")
            return summary
        }
        unsaved = 0
        passes += 1
        let started = now()
        waitingForClaude = []
        var walk = FileWalk(home: home, stateRoot: stateRoot, probe: probe)
        var seen = Set<String>()
        var stopped = false
        while let candidate = walk.next() {
            seen.insert(Self.key(candidate.url))
            summary.documents += 1
            if await process(candidate, into: &summary) == .stop {
                stopped = true
                break
            }
            await Task.yield()
        }
        summary.walkSkipped = walk.skipped
        if !stopped && !Task.isCancelled {
            summary.completed = true
            let gone = index.entries.keys.filter { !seen.contains($0) }
            for path in gone { index.entries[path] = nil }
            summary.removed = gone.count
            if !gone.isEmpty { unsaved += 1 }
            rebuildDigests()
        }
        saveIfNeeded()
        let seconds = Int(started.duration(to: now()).components.seconds)
        log(Self.describe(summary, pass: passes, seconds: seconds))
        return summary
    }

    /// The files left waiting for Claude, each as the hour's allowance frees up, until
    /// `deadline` (the next walk). Those still waiting then are found again by that walk.
    public func readWaiting(before deadline: SuspendingClock.Instant) async throws {
        var summary = PassSummary()
        var count = 0
        while !waitingForClaude.isEmpty {
            let wait = quota.untilRoom()
            if wait > .zero {
                guard now().advanced(by: wait) < deadline else { break }
                try await sleep(wait)
            }
            let candidate = waitingForClaude.removeFirst()
            count += 1
            if await process(candidate, into: &summary) == .stop { break }
        }
        saveIfNeeded()
        if count > 0 {
            log("files: \(count) waiting file(s) taken up: \(summary.readByClaude) read by Claude, "
                + "\(summary.waiting) still waiting, \(summary.failed) failed; \(summary.factsAdded) new fact(s)")
        }
    }

    /// One document. `.stop` when cancelled or when the index or facts can no longer be saved.
    private func process(_ candidate: FileCandidate, into summary: inout PassSummary) async -> Step {
        let path = Self.key(candidate.url)
        if let entry = index.entries[path], entry.status.isSettled,
           entry.size == candidate.size, entry.mtime == candidate.modified {
            summary.unchanged += 1
            return .next
        }
        do {
            try await paced()
            try await turns.waitUntilIdle(sleep: sleep)
        } catch {
            return .stop
        }

        guard let digest = FileDigest.sha256(of: candidate) else {
            summary.unreadable += 1
            return record(candidate, digest: "", status: .unreadable)
        }
        let tag = String(digest.prefix(12))
        if let entry = index.entries[path], entry.status.isSettled, entry.digest == digest {
            index.entries[path]?.size = candidate.size          // touched, not changed
            index.entries[path]?.mtime = candidate.modified
            summary.unchanged += 1
            return markChanged(modelUsed: false)
        }
        if let other = readByDigest[digest], other != path {
            summary.duplicates += 1
            return record(candidate, digest: digest, status: .duplicate)
        }
        guard let extracted = extractors.extract(candidate) else {
            summary.unreadable += 1
            return record(candidate, digest: digest, status: .unreadable)
        }
        if extracted.wasCut {
            summary.cut += 1
            log("files: \(tag) text cut at \(ExtractedText.maxCharacters) characters (\(extracted.cutCharacters) more)")
        }
        let step: Step
        switch await reader.read(extracted.text, kind: candidate.kind, digest: digest) {
        case .read(let route, let added, let updated, _):
            if route == .local { summary.readOnDevice += 1 } else { summary.readByClaude += 1 }
            summary.factsAdded += added
            summary.factsUpdated += updated
            step = record(candidate, digest: digest, status: .read, facts: added + updated, modelUsed: true)
        case .nothingToRead:
            summary.empty += 1
            step = record(candidate, digest: digest, status: .empty)
        case .overClaudeQuota:
            summary.waiting += 1
            waitingForClaude.append(candidate)
            step = record(candidate, digest: digest, status: .waiting, modelUsed: true)
        case .failed:
            summary.failed += 1
            step = record(candidate, digest: digest, status: .failed, modelUsed: true)
        case .notSaved:
            log("files: facts not saved; pass stopped")
            return .stop
        case .cancelled:
            return .stop
        }
        guard step == .next else { return step }
        do { try await sleep(Self.pause) } catch { return .stop }
        return .next
    }

    /// Backs off while the Mac is hot or in Low Power Mode; throws when cancelled.
    private func paced() async throws {
        while !conditions().allowsBackgroundWork {
            if !backingOff {
                backingOff = true
                log("files: paused (thermal state serious or Low Power Mode)")
            }
            try await sleep(Self.backoffInterval)
        }
        if backingOff {
            backingOff = false
            log("files: resumed")
        }
        try Task.checkCancellation()
    }

    // MARK: - The index

    private func record(_ candidate: FileCandidate, digest: String, status: FileIndexEntry.Status,
                        facts: Int = 0, modelUsed: Bool = false) -> Step {
        let path = Self.key(candidate.url)
        index.entries[path] = FileIndexEntry(path: path, size: candidate.size, mtime: candidate.modified,
                                             digest: digest, status: status, facts: facts, lastRead: clock.now())
        if status == .read { readByDigest[digest] = path }
        return markChanged(modelUsed: modelUsed)
    }

    /// Saves after a model read, or once `saveEvery` other changes have gathered.
    private func markChanged(modelUsed: Bool) -> Step {
        unsaved += 1
        guard modelUsed || unsaved >= Self.saveEvery else { return .next }
        return saveIfNeeded() ? .next : .stop
    }

    @discardableResult
    private func saveIfNeeded() -> Bool {
        guard unsaved > 0 else { return true }
        guard indexStore.save(index) else {
            log("files: index not saved (no lease)")
            return false
        }
        unsaved = 0
        return true
    }

    private func loadIndex() {
        guard !loaded else { return }
        loaded = true
        if let found = indexStore.load() {
            index = found
        } else {
            log("files: files-index.json unreadable; starting a new index")
            index = FileIndex()
        }
        rebuildDigests()
    }

    private func rebuildDigests() {
        readByDigest = [:]
        for entry in index.entries.values where entry.status == .read {
            readByDigest[entry.digest] = entry.path
        }
    }

    /// The index's view of the scanner, for tests.
    public var indexSnapshot: FileIndex { index }

    // MARK: - Helpers

    static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func describe(_ s: PassSummary, pass: Int, seconds: Int) -> String {
        let skipped = FileSkip.allCases.compactMap { reason in
            s.walkSkipped[reason].map { "\(reason.rawValue) \($0)" }
        }.joined(separator: ", ")
        return "files: pass \(pass) \(s.completed ? "done" : "stopped") after \(seconds) s: "
            + "\(s.documents) document(s), \(s.unchanged) unchanged, \(s.readOnDevice) read on-device, "
            + "\(s.readByClaude) by Claude, \(s.empty) empty, \(s.unreadable) unreadable, "
            + "\(s.duplicates) duplicate(s), \(s.waiting) waiting for Claude, \(s.failed) failed, "
            + "\(s.cut) cut at the cap; \(s.factsAdded) new fact(s), \(s.factsUpdated) refreshed; "
            + "\(s.removed) gone from the index; skipped by the walk: \(skipped.isEmpty ? "none" : skipped)"
    }
}
