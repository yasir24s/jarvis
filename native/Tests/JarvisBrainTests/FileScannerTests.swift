import CryptoKit
import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

// D-51 P3, piece 5: the scanner over a temp home tree with scripted writers. The index skips
// unchanged files and re-reads changed ones, nothing is read without the lease, it backs off
// when the Mac is hot, waiting files are read as Claude's hour frees up, and the logs hold
// counts and digests only. The real home folder is never walked.

/// Every extraction it was asked for, then the plain-text reader's answer.
final class RecordingExtractor: TextExtracting {
    private let asked = Mutex<[String]>([])
    var kinds: Set<DocumentKind> { [.plainText, .markdown, .csv, .pdf] }
    var paths: [String] { asked.withLock { $0 } }

    func extract(_ url: URL, kind: DocumentKind, limit: Int) -> ExtractedText? {
        asked.withLock { $0.append(url.lastPathComponent) }
        return PlainTextExtractor().extract(url, kind: kind == .pdf ? .plainText : kind, limit: limit)
    }
}

/// Lines a test can read back.
final class LineLog: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var function: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private let epoch: Double = 1790582400

private final class ScanRig: Sendable {
    let home: TempHome
    let state: Sandbox
    let store: StateStore
    let memory: MemoryStore
    let local: ScriptedWriter
    let claude: ScriptedWriter
    let extractor = RecordingExtractor()
    let probe = FakeFileProbe()
    let turns = TurnActivity()
    let quota: ClaudeReadQuota
    let logs = LineLog()
    let sleeps = Mutex<[Duration]>([])
    let conditions: Mutex<[PowerConditions]>
    let hand = HandInstant()

    init(local: ScriptedWriter = ScriptedWriter(), claude: ScriptedWriter = ScriptedWriter(),
         quotaLimit: Int = FileReading.claudeFilesPerHour, lease: (any StateLease)? = nil,
         conditions: [PowerConditions] = []) throws {
        home = try TempHome()
        state = try Sandbox()
        store = try StateStore(root: state.root.path(percentEncoded: false), lease: lease)
        memory = MemoryStore(store: store, clock: ManualClock(epoch))
        self.local = local
        self.claude = claude
        let hand = hand
        quota = ClaudeReadQuota(limit: quotaLimit, now: { hand.now })
        self.conditions = Mutex(conditions)
    }

    /// Sleeps are recorded and move the hand clock; none takes real time beyond a yield.
    var sleep: FileScanner.Sleep {
        { [self] d in
            sleeps.withLock { $0.append(d) }
            hand.advance(d)
            try Task.checkCancellation()
            await Task.yield()
        }
    }

    func scanner() -> FileScanner {
        let reader = FileFactReader(memory: memory, local: local, claude: claude,
                                    budget: LocalFileBudget(counter: FakeTokenCounter()), quota: quota,
                                    turns: turns, clock: ManualClock(epoch), sleep: sleep, log: logs.function)
        let hand = hand
        return FileScanner(home: home.root, stateRoot: state.root, store: store,
                           extractors: TextExtractors([extractor]), reader: reader, quota: quota, turns: turns,
                           probe: probe,
                           conditions: { [self] in
                               conditions.withLock { $0.isEmpty ? PowerConditions() : $0.removeFirst() }
                           },
                           clock: ManualClock(epoch), now: { hand.now }, sleep: sleep, log: logs.function)
    }

    var facts: [MemoryFact] { memory.loadFacts()?.facts ?? [] }
    var savedIndex: FileIndex? { FileIndexStore(store: store).load() }

    func entry(_ relative: String) -> FileIndexEntry? {
        savedIndex?.entries[FileScanner.key(home.url(relative))]
    }

    func remove() {
        home.remove()
        state.remove()
    }
}

@Suite("File scanner: index, pacing, lease, logs (D-51 P3)", .timeLimit(.minutes(1)))
struct FileScannerTests {
    @Test func aPassReadsEachDocumentAndRecordsItInTheIndex() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("The user keeps bees."), .reply("NONE")))
        defer { rig.remove() }
        let bees = try rig.home.write("Documents/bees.md", "Hive notes for the summer.")
        try rig.home.write("Documents/notes.txt", "Shopping: oats.")
        let summary = await rig.scanner().pass()
        #expect(summary.completed && summary.documents == 2 && summary.readOnDevice == 2)
        let digest = sha256(try Data(contentsOf: bees))
        #expect(rig.facts.map(\.text) == ["The user keeps bees."])
        #expect(rig.facts.first?.source == "file:" + digest)
        let entry = try #require(rig.entry("Documents/bees.md"))
        #expect(entry.digest == digest && entry.status == .read && entry.facts == 1 && entry.size == 26)
        #expect(entry.lastRead == epoch)
        #expect(rig.entry("Documents/notes.txt")?.status == .read)
        #expect(rig.entry("Documents/notes.txt")?.facts == 0)
    }

    @Test func unchangedFilesAreNeverReadTwiceEvenAfterARestart() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE"), .reply("NONE")))
        defer { rig.remove() }
        try rig.home.write("Documents/a.md", "Alpha.")
        try rig.home.write("Documents/b.txt", "Beta.")
        let scanner = rig.scanner()
        _ = await scanner.pass()
        let again = await scanner.pass()
        #expect(again.unchanged == 2 && again.readOnDevice == 0)
        let restarted = await rig.scanner().pass()                     // a new scanner loads the index
        #expect(restarted.unchanged == 2 && restarted.readOnDevice == 0)
        #expect(rig.local.calls.count == 2)
        #expect(rig.extractor.paths.sorted() == ["a.md", "b.txt"])
    }

    @Test func aChangedFileIsReadAgainAndATouchedOneIsNot() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE"), .reply("NONE"), .reply("The user moved to York.")))
        defer { rig.remove() }
        let changed = try rig.home.write("Documents/plan.md", "Moving soon.")
        let touched = try rig.home.write("Documents/same.txt", "Unchanged words.")
        let scanner = rig.scanner()
        _ = await scanner.pass()
        try Data("Moving to York in May.".utf8).write(to: changed)
        let later = Date(timeIntervalSince1970: epoch + 86_400)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: touched.path(percentEncoded: false))
        let second = await scanner.pass()
        #expect(second.readOnDevice == 1 && second.unchanged == 1)
        #expect(rig.local.calls.count == 3)
        #expect(rig.entry("Documents/plan.md")?.digest == sha256(Data("Moving to York in May.".utf8)))
        #expect(rig.entry("Documents/same.txt")?.mtime == epoch + 86_400)  // the touch is recorded
        #expect(rig.facts.map(\.text) == ["The user moved to York."])
    }

    @Test func aDatalessFileIsNeverOpenedOrRead() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE")))
        defer { rig.remove() }
        let evicted = try rig.home.write("Library/Mobile Documents/com~apple~CloudDocs/evicted.md", "Only in iCloud.")
        try rig.home.write("Library/Mobile Documents/com~apple~CloudDocs/here.md", "On the Mac.")
        rig.probe.dataless(evicted)
        let summary = await rig.scanner().pass()
        #expect(summary.documents == 1 && summary.walkSkipped[.notDownloaded] == 1)
        #expect(rig.extractor.paths == ["here.md"])
        #expect(rig.entry("Library/Mobile Documents/com~apple~CloudDocs/evicted.md") == nil)
    }

    @Test func aCopyOfADocumentAlreadyReadIsNotReadAgain() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("The user keeps bees.")))
        defer { rig.remove() }
        try rig.home.write("Documents/bees.md", "Hive notes.")
        try rig.home.write("Desktop/bees copy.md", "Hive notes.")
        let summary = await rig.scanner().pass()
        #expect(summary.readOnDevice == 1 && summary.duplicates == 1)
        #expect(rig.local.calls.count == 1)
        #expect(rig.entry("Documents/bees.md")?.status == .duplicate)      // Desktop sorts first
        #expect(rig.entry("Desktop/bees copy.md")?.status == .read)
    }

    @Test func withoutTheLeaseNothingIsReadOrWritten() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("The user keeps bees.")), lease: HandLease(false))
        defer { rig.remove() }
        try rig.home.write("Documents/bees.md", "Hive notes.")
        let summary = await rig.scanner().pass()
        #expect(!summary.completed && summary.documents == 0)
        #expect(rig.local.calls.isEmpty && rig.extractor.paths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.state.root.path(percentEncoded: false) + "/memory"))
    }

    @Test func losingTheLeaseMidPassStopsIt() async throws {
        let lease = HandLease(true)
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE"), .reply("NONE")), lease: lease)
        defer { rig.remove() }
        try rig.home.write("Documents/a.md", "Alpha.")
        try rig.home.write("Documents/b.md", "Beta.")
        let reader = FileFactReader(memory: rig.memory, local: HookWriter(inner: rig.local) { lease.set(false) },
                                    claude: rig.claude, budget: LocalFileBudget(counter: FakeTokenCounter()),
                                    quota: rig.quota, turns: rig.turns, clock: ManualClock(epoch), log: { _ in })
        let scanner = FileScanner(home: rig.home.root, stateRoot: rig.state.root, store: rig.store,
                                  extractors: TextExtractors([rig.extractor]), reader: reader, quota: rig.quota,
                                  turns: rig.turns, probe: rig.probe, clock: ManualClock(epoch),
                                  sleep: rig.sleep, log: rig.logs.function)
        let summary = await scanner.pass()                               // the lease goes during the first read
        #expect(!summary.completed)
        #expect(rig.local.calls.count == 1)
        #expect(rig.extractor.paths == ["a.md"])
        #expect(rig.logs.all.contains("files: index not saved (no lease)"))
    }

    @Test func itBacksOffWhileTheMacIsHotOrInLowPowerMode() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE")),
                              conditions: [PowerConditions(thermal: .serious), PowerConditions(lowPowerMode: true),
                                           PowerConditions(thermal: .critical), PowerConditions(thermal: .fair)])
        defer { rig.remove() }
        try rig.home.write("Documents/a.md", "Alpha.")
        let summary = await rig.scanner().pass()
        #expect(summary.readOnDevice == 1)
        let sleeps = rig.sleeps.withLock { $0 }
        #expect(Array(sleeps.prefix(3)) == Array(repeating: FileScanner.backoffInterval, count: 3))
        #expect(rig.logs.all.contains("files: paused (thermal state serious or Low Power Mode)"))
        #expect(rig.logs.all.contains("files: resumed"))
        #expect(PowerConditions(thermal: .fair).allowsBackgroundWork)
    }

    @Test func filesWaitingForClaudeAreReadAsTheHourFreesUp() async throws {
        let rig = try ScanRig(claude: ScriptedWriter(.reply("The user studies law."), .reply("The user sings.")),
                              quotaLimit: 1)
        defer { rig.remove() }
        let big = String(repeating: "Lecture notes and more words. ", count: 1000)   // 30,000 characters
        try rig.home.write("Documents/law.txt", big)
        try rig.home.write("Documents/music.txt", big + "Choir.")
        let scanner = rig.scanner()
        let summary = await scanner.pass()
        #expect(summary.readByClaude == 1 && summary.waiting == 1)
        #expect(rig.entry("Documents/music.txt")?.status == .waiting)
        try await scanner.readWaiting(before: rig.hand.now.advanced(by: FileScanner.rewalkInterval))
        #expect(rig.claude.calls.count == 2)
        #expect(rig.entry("Documents/music.txt")?.status == .read)
        #expect(rig.sleeps.withLock { $0 }.contains { $0 > .seconds(3000) })   // it waited for the hour
        #expect(Set(rig.facts.map(\.text)) == ["The user studies law.", "The user sings."])
    }

    @Test func aFailedReadIsTriedAgainOnTheNextPass() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.fail(.localFailed("busy")), .reply("NONE")))
        defer { rig.remove() }
        try rig.home.write("Documents/a.md", "Alpha.")
        let scanner = rig.scanner()
        #expect(await scanner.pass().failed == 1)
        #expect(rig.entry("Documents/a.md")?.status == .failed)
        #expect(await scanner.pass().readOnDevice == 1)
        #expect(rig.entry("Documents/a.md")?.status == .read)
    }

    @Test func filesNoLongerFoundLeaveTheIndex() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE"), .reply("NONE")))
        defer { rig.remove() }
        let gone = try rig.home.write("Documents/old.md", "Old.")
        try rig.home.write("Documents/keep.md", "Keep.")
        let scanner = rig.scanner()
        _ = await scanner.pass()
        try FileManager.default.removeItem(at: gone)
        let summary = await scanner.pass()
        #expect(summary.removed == 1)
        #expect(rig.savedIndex?.entries.count == 1)
    }

    @Test func logsHoldCountsAndDigestsButNoPathTextOrFact() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("The user keeps bees.")))
        defer { rig.remove() }
        try rig.home.write("Documents/Private bees.md", "Hive notes, secret apiary location.")
        _ = await rig.scanner().pass()
        let lines = rig.logs.all
        #expect(!lines.isEmpty)
        let home = rig.home.root.path(percentEncoded: false)
        for line in lines {
            #expect(!line.contains(home) && !line.contains("Private bees") && !line.contains("Documents"))
            #expect(!line.contains("Hive notes") && !line.contains("keeps bees"))
        }
        #expect(lines.contains { $0.hasPrefix("files: pass 1 done") && $0.contains("1 read on-device") })
    }

    @Test func startRunsAPassAndStopEndsTheLoopPromptly() async throws {
        let rig = try ScanRig(local: ScriptedWriter(.reply("NONE")))
        defer { rig.remove() }
        try rig.home.write("Documents/a.md", "Alpha.")
        let reader = FileFactReader(memory: rig.memory, local: rig.local, claude: rig.claude,
                                    budget: LocalFileBudget(counter: FakeTokenCounter()), quota: rig.quota,
                                    turns: rig.turns, clock: ManualClock(epoch), log: { _ in })
        // Short real sleeps, and the six hours between passes a real (cancellable) wait.
        let scanner = FileScanner(home: rig.home.root, stateRoot: rig.state.root, store: rig.store,
                                  extractors: TextExtractors([rig.extractor]), reader: reader, quota: rig.quota,
                                  turns: rig.turns, probe: rig.probe, clock: ManualClock(epoch),
                                  sleep: { d in
                                      try await Task.sleep(for: d >= .seconds(3600) ? d : .milliseconds(1),
                                                           clock: .suspending)
                                  }, log: rig.logs.function)
        scanner.start()
        scanner.start()                                                   // once only
        let clock = SuspendingClock()
        let t0 = clock.now
        while rig.savedIndex?.entries.isEmpty != false {
            try await Task.sleep(for: .milliseconds(5))
            #expect(t0.duration(to: clock.now) < .seconds(20))
        }
        let stopping = clock.now
        await scanner.stop()
        #expect(stopping.duration(to: clock.now) < .seconds(2))
        #expect(rig.entry("Documents/a.md")?.status == .read)
        #expect(rig.logs.all.filter { $0.hasPrefix("files: scanner started") }.count == 1)
        scanner.start()                                                   // nothing after stop
        try await Task.sleep(for: .milliseconds(20))
        #expect(rig.local.calls.count == 1)
    }
}

/// Runs `onCall` as each call starts, then defers to `inner`.
private final class HookWriter: PersonaLLM {
    private let inner: ScriptedWriter
    private let onCall: @Sendable () -> Void

    init(inner: ScriptedWriter, onCall: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onCall = onCall
    }

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        onCall()
        return try await inner.complete(system: system, user: user, timeout: timeout)
    }
}
