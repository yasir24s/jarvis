import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

// P6 part 2 (DEV-P6-02 and DEV-P6-03, proposed): memory that can't be lost. The hourly
// owner-only backups of facts.json, personality.json and profile.json and their rotation, the
// mass-deletion guard, the forgotten bin, and the launch check. Sandboxed roots and invented
// notes only; the real ~/jarvis state is never read.

private let epoch: Double = 1790582400                         // 2026-09-28 08:00:00 UTC
private let utc = TimeZone(identifier: "UTC")!

private func rootPath(_ s: Sandbox) -> String {
    var p = s.root.path(percentEncoded: false)
    while p.hasSuffix("/") { p.removeLast() }
    return p
}

private func bytes(_ p: String) -> Data? { FileManager.default.contents(atPath: p) }

private func fact(_ n: Int, at t: Double = epoch) -> MemoryFact {
    MemoryFact(id: "fact-\(n)", text: "The user owns invented thing number \(n).",
               source: MemoryFact.conversationSource, created: t, updated: t, by: .local)
}

private func mode(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
}

/// Collects log lines.
private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ s: String) { lines.withLock { $0.append(s) } }
}

private struct Rig {
    let sb: Sandbox
    let clock: ManualClock
    let store: StateStore
    let memory: MemoryStore
    let lines = Lines()

    init(lease: HandLease? = nil) throws {
        sb = try Sandbox()
        clock = ManualClock(epoch)
        store = try StateStore(root: rootPath(sb), lease: lease, clock: clock)
        let lines = lines
        memory = MemoryStore(store: store, clock: clock, timeZone: utc, log: { lines.add($0) })
    }

    var backupDir: String { rootPath(sb) + "/memory/backups" }
    func backupNames() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: backupDir)) ?? []).sorted() }
    func path(_ relative: String) -> String { rootPath(sb) + "/" + relative }

    /// Writes `n` invented facts.
    @discardableResult
    func write(_ n: Int) -> Bool {
        memory.updateFacts { $0.facts = (0..<n).map { fact($0) }; return true }
    }
}

@Suite("P6 memory that can't be lost")
struct MemoryPermanenceTests {
    // MARK: - Backups

    @Test func aWriteIsCopiedAtMostOnceAnHourOwnerOnly() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(3))
        let first = MemoryBackups.name(.facts, stamp: Int64(epoch))
        #expect(rig.backupNames() == [first])
        #expect(bytes(rig.backupDir + "/" + first) == bytes(rig.path("memory/facts.json")))
        #expect(mode(rig.backupDir) == 0o700)
        #expect(mode(rig.backupDir + "/" + first) == 0o600)
        rig.clock.advance(3599)
        #expect(rig.write(4))
        #expect(rig.backupNames() == [first])                 // within the hour: no new copy
        rig.clock.advance(1)
        #expect(rig.write(5))
        let second = MemoryBackups.name(.facts, stamp: Int64(epoch + 3600))
        #expect(rig.backupNames() == [first, second])
        #expect(bytes(rig.backupDir + "/" + second) == bytes(rig.path("memory/facts.json")))
        #expect(rig.memory.backups.newestReadable(.facts)?.entries == 5)
    }

    @Test func aDeclinedOrRefusedWriteIsNotCopied() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(!rig.memory.updateFacts { $0.facts = [fact(1)]; return false })
        #expect(rig.backupNames().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: rig.path("memory")))
    }

    @Test func withoutTheLeaseNoCopyIsWritten() throws {
        let lease = HandLease(true)
        let rig = try Rig(lease: lease)
        defer { rig.sb.remove() }
        #expect(rig.write(2))
        rig.clock.advance(7200)
        lease.set(false)
        #expect(!rig.memory.backups.afterWrite(.facts, data: Data("{}".utf8)))
        #expect(rig.backupNames().count == 1)
        #expect(rig.lines.all.contains { $0.contains("not written: the lease is not held") })
    }

    /// The shared files are copied byte for byte after each save through the same StateStore,
    /// and their own bytes are exactly what the save wrote (their format never changes).
    @Test func personalityAndProfileSavesAreCopiedByteForByte() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        try PersonalityLogic.learn("The user likes a dry joke now and then", store: rig.store, now: epoch)
        try ProfileLogic.remember(key: "favourite tea", value: "invented oolong", store: rig.store, now: epoch)
        let personality = MemoryBackups.name(.personality, stamp: Int64(epoch))
        let profile = MemoryBackups.name(.profile, stamp: Int64(epoch))
        #expect(rig.backupNames() == [personality, profile])
        #expect(bytes(rig.backupDir + "/" + personality) == bytes(rig.store.path(.personality)))
        #expect(bytes(rig.backupDir + "/" + profile) == bytes(rig.store.path(.profile)))
        guard case .object(let p)? = rig.store.load(.personality) else {
            Issue.record("personality.json does not load")
            return
        }
        #expect(PyJSON.dumps(.object(p), indent: 1) == String(decoding: bytes(rig.store.path(.personality)) ?? Data(), as: UTF8.self))
        #expect(rig.memory.backups.newestReadable(.personality)?.entries == 9)    // 8 seed lines + 1 note
        #expect(rig.memory.backups.newestReadable(.profile)?.entries == 1)
    }

    /// The newest 48 hourly copies, and the newest copy of each of the newest 30 days.
    @Test func theRotationKeeps48HourlyAnd30Daily() {
        let start = Int64(epoch) - Int64(epoch) % 86_400               // a UTC midnight
        let stamps = (0..<2_400).map { start + Int64($0) * 3_600 }    // 100 days, hourly
        let kept = MemoryBackups.kept(stamps, timeZone: utc)
        let hourly = Set(stamps.suffix(48))
        let days = Dictionary(grouping: stamps) { $0 / 86_400 }
        let daily = Set(days.keys.sorted().suffix(30).compactMap { days[$0]?.max() })
        #expect(kept == hourly.union(daily))
        #expect(kept.count == 48 + 28)                                // the last two days are hourly already
        #expect(MemoryBackups.kept([], timeZone: utc).isEmpty)
    }

    /// Driven through writes: 60 hourly writes leave exactly what the rotation keeps.
    @Test func hourlyWritesAreRotatedOnDisk() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        for k in 0..<60 {
            #expect(rig.write(k + 1))
            rig.clock.advance(3_600)
        }
        let all = (0..<60).map { Int64(epoch) + Int64($0) * 3_600 }
        let want = MemoryBackups.kept(all, timeZone: utc).sorted(by: >)
        #expect(rig.memory.backups.stamps(.facts) == want)
        #expect(want.count < 60 && want.count >= 48)
    }

    // MARK: - The mass-deletion guard

    @Test func aWriteThatDropsMoreThanTenOrTenPercentIsRefused() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(200))
        let before = bytes(rig.path("memory/facts.json"))
        #expect(rig.memory.writeFacts { $0.facts.removeLast(11); return true } == .refused(dropped: 11, of: 200))
        #expect(bytes(rig.path("memory/facts.json")) == before)
        #expect(rig.lines.all.contains("memory: a facts write that would drop 11 of 200 facts was refused"))
        #expect(rig.memory.writeFacts { $0.facts.removeLast(10); return true } == .saved)   // 5%: allowed
        #expect(rig.memory.loadFacts()?.facts.count == 190)
        #expect(rig.memory.writeFacts { $0.facts = []; return true } == .refused(dropped: 190, of: 190))
    }

    @Test func inASmallMemoryTenPercentIsTheLimit() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(10))
        #expect(rig.memory.writeFacts { $0.facts.removeLast(2); return true } == .refused(dropped: 2, of: 10))
        #expect(rig.memory.writeFacts { $0.facts.removeLast(1); return true } == .saved)    // exactly 10%
        #expect(rig.memory.writeFacts { $0.facts.removeLast(1); return true } == .refused(dropped: 1, of: 9))
    }

    /// forget_memory by ids may remove any number: only the ids it names are exempt.
    @Test func aForgetByIdsIsTheOnlyException() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(20))
        #expect(rig.memory.forget(byIDs: false) { _ in Set(0..<15) } == .refused(dropped: 15, of: 20))
        #expect(rig.memory.loadFacts()?.facts.count == 20)
        #expect(rig.memory.loadForgotten()?.entries.isEmpty == true)
        guard case .moved(let gone) = rig.memory.forget(byIDs: true, { _ in Set(0..<15) }) else {
            Issue.record("forget by ids was not allowed")
            return
        }
        #expect(gone.map(\.id) == (0..<15).map { "fact-\($0)" })
        #expect(rig.memory.loadFacts()?.facts.map(\.id) == (15..<20).map { "fact-\($0)" })
        // Anything beyond the named ids still counts.
        #expect(rig.memory.writeFacts(allowingRemovalOf: ["fact-15"]) { $0.facts = []; return true }
                == .refused(dropped: 4, of: 5))
    }

    /// An entry the loader cannot read is not silently lost: the guard counts it as dropped.
    @Test func anEntryOfTheWrongShapeCountsAsDropped() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(5))
        var text = String(decoding: try #require(bytes(rig.path("memory/facts.json"))), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"facts\": [\n", with: "\"facts\": [\n  {\"id\": \"odd\", \"text\": 5},\n")
        try Data(text.utf8).write(to: URL(fileURLWithPath: rig.path("memory/facts.json")))
        #expect(rig.memory.loadFacts()?.facts.count == 5)
        #expect(rig.memory.writeFacts { $0.facts.append(fact(9)); return true } == .refused(dropped: 1, of: 6))
    }

    // MARK: - The forgotten bin

    @Test func aForgetIsKeptThirtyDaysAndCanBeRestored() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(3))
        #expect(rig.memory.forget(byIDs: true) { _ in [1] } == .moved([fact(1)]))
        let bin = try #require(rig.memory.loadForgotten())
        #expect(bin.entries == [ForgottenFile.Entry(fact: fact(1), forgotten: epoch)])
        #expect(mode(rig.path("memory/forgotten.json")) != nil)
        // Restoring puts it back as it was, and a fact already there by id is not added twice.
        #expect(rig.memory.restore { _ in [0] } == .moved([fact(1)]))
        #expect(rig.memory.loadFacts()?.facts == [fact(0), fact(2), fact(1)])
        #expect(rig.memory.loadForgotten()?.entries == [])
        #expect(rig.memory.forget(byIDs: true) { _ in [2] } == .moved([fact(1)]))
        #expect(rig.memory.updateFacts { $0.facts.append(fact(1)); return true })
        #expect(rig.memory.restore { _ in [0] } == .moved([fact(1)]))
        #expect(rig.memory.loadFacts()?.facts.filter { $0.id == "fact-1" }.count == 1)
    }

    @Test func afterThirtyDaysAForgetIsGone() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(30))
        _ = rig.memory.forget(byIDs: true) { _ in [0, 1] }
        rig.clock.advance(ForgottenFile.keptFor - 1)
        #expect(rig.memory.loadForgotten()?.entries.count == 2)
        rig.clock.advance(1)
        #expect(rig.memory.loadForgotten()?.entries.isEmpty == true)
        rig.memory.checkAtLaunch()                                     // the file itself is purged
        let raw = try #require(bytes(rig.path("memory/forgotten.json")))
        #expect(ForgottenFile(data: raw)?.entries.isEmpty == true)
        #expect(rig.lines.all.contains("memory: 2 forgotten fact(s) past 30 days dropped"))
    }

    /// Without the lease nothing moves: the bin is written first, and refused.
    @Test func withoutTheLeaseAForgetMovesNothing() throws {
        let lease = HandLease(true)
        let rig = try Rig(lease: lease)
        defer { rig.sb.remove() }
        #expect(rig.write(30))
        lease.set(false)
        #expect(rig.memory.forget(byIDs: true) { _ in [0] } == .notSaved)
        #expect(rig.memory.loadFacts()?.facts.count == 30)
        #expect(!FileManager.default.fileExists(atPath: rig.path("memory/forgotten.json")))
    }

    // MARK: - The launch check

    @Test func anUnreadableFactsFileIsRestoredFromTheNewestReadableBackup() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(4))
        let good = try #require(bytes(rig.path("memory/facts.json")))
        rig.clock.advance(7_200)
        #expect(rig.write(6))
        // The newest backup is damaged too: the one before it is used.
        let newest = rig.backupDir + "/" + MemoryBackups.name(.facts, stamp: Int64(epoch + 7_200))
        try Data("{\"compiled".utf8).write(to: URL(fileURLWithPath: newest))
        try Data("not json".utf8).write(to: URL(fileURLWithPath: rig.path("memory/facts.json")))
        rig.clock.advance(60)
        let report = rig.memory.checkAtLaunch()
        #expect(report[.facts] == .restored(stamp: Int64(epoch)))
        #expect(bytes(rig.path("memory/facts.json")) == good)
        #expect(rig.memory.loadFacts()?.facts.count == 4)
        let aside = rig.backupDir + "/facts-\(Int64(epoch + 7_260)).unreadable"
        #expect(bytes(aside) == Data("not json".utf8))
        #expect(mode(aside) == 0o600)
        #expect(rig.lines.all.contains("memory: memory/facts.json was unreadable; restored the backup from 2026-09-28 08:00 (4 entries)"))
    }

    @Test func anUnreadableFileWithNoBackupIsLeftAsItIs() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        try FileManager.default.createDirectory(atPath: rig.path("memory"), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: rig.path("memory/facts.json")))
        #expect(rig.memory.checkAtLaunch()[.facts] == .unreadableWithoutBackup)
        #expect(bytes(rig.path("memory/facts.json")) == Data("garbage".utf8))
    }

    /// More than 10% fewer facts than the newest backup, with no forget recorded: a warning,
    /// and both are kept (the backup put aside, out of the rotation; the file untouched).
    @Test func aShrinkWithoutAForgetIsLoggedAndBothAreKept() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(20))
        let backup = try #require(bytes(rig.path("memory/facts.json")))
        let shrunk = FactsFile(compiledThrough: 0, facts: (0..<15).map { fact($0) }).data
        #expect(rig.store.write(shrunk, to: .facts))                 // past the guard, as a bad writer would
        rig.clock.advance(60)
        let report = rig.memory.checkAtLaunch()
        #expect(report[.facts] == .shrank(from: 20, to: 15, stamp: Int64(epoch)))
        #expect(bytes(rig.path("memory/facts.json")) == shrunk)
        #expect(bytes(rig.backupDir + "/facts-\(Int64(epoch)).kept.json") == backup)
        #expect(rig.lines.all.contains { $0.hasPrefix("memory: WARNING memory/facts.json holds 15 entries, 5 fewer than the backup") })
        // The kept copy is not a rotating backup: the rotation never removes it.
        #expect(rig.memory.backups.stamps(.facts) == [Int64(epoch)])
    }

    @Test func aShrinkThatForgetsExplainIsFine() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.write(20))
        #expect(rig.memory.forget(byIDs: true) { _ in Set(0..<5) } != .notSaved)
        rig.clock.advance(60)
        #expect(rig.memory.checkAtLaunch()[.facts] == .fine)
        #expect(!rig.lines.all.contains { $0.contains("WARNING") })
    }

    @Test func anUnreadablePersonalityIsRestoredByteForByte() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        try PersonalityLogic.learn("The user likes a dry joke now and then", store: rig.store, now: epoch)
        let saved = try #require(bytes(rig.store.path(.personality)))
        try Data("{\"core\": [\"half".utf8).write(to: URL(fileURLWithPath: rig.store.path(.personality)))
        let report = rig.memory.checkAtLaunch()
        #expect(report[.personality] == .restored(stamp: Int64(epoch)))
        #expect(bytes(rig.store.path(.personality)) == saved)
        guard case .object(let p)? = rig.store.load(.personality) else {
            Issue.record("personality.json does not load after the restore")
            return
        }
        #expect(p.array("learned")?.count == 1)
    }

    /// A missing file whose backups hold entries counts as a shrink to nothing: logged, and the
    /// backup is kept aside.
    @Test func aMissingProfileWithABackupIsAShrink() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        for (k, v) in [("favourite tea", "invented oolong"), ("home town", "Invented Vale"), ("pet", "a gecko")] {
            try ProfileLogic.remember(key: k, value: v, store: rig.store, now: rig.clock.now())
            rig.clock.advance(3_600)
        }
        try FileManager.default.removeItem(atPath: rig.store.path(.profile))
        let last = Int64(epoch) + 7_200
        #expect(rig.memory.checkAtLaunch()[.profile] == .shrank(from: 3, to: 0, stamp: last))
        #expect(FileManager.default.fileExists(atPath: rig.backupDir + "/profile-\(last).kept.json"))
    }

    /// A new install: nothing to check, and the launch check creates no memory folder.
    @Test func aNewInstallsLaunchWritesNothing() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        let report = rig.memory.checkAtLaunch()
        #expect(report == Dictionary(uniqueKeysWithValues: BackedUpFile.allCases.map { ($0, .fine) }))
        #expect(!FileManager.default.fileExists(atPath: rig.path("memory")))
    }

    /// An install from before P6: the launch copies each readable file that has no backup yet.
    @Test func theFirstLaunchCopiesFilesThatHaveNoBackup() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        let facts = FactsFile(compiledThrough: 0, facts: [fact(1), fact(2)]).data
        #expect(rig.store.write(facts, to: .facts))
        #expect(rig.memory.checkAtLaunch()[.facts] == .fine)
        #expect(rig.backupNames() == [MemoryBackups.name(.facts, stamp: Int64(epoch))])
    }

    // MARK: - The archive (P6b)

    /// An archive append is followed by the hourly copy: the whole file, owner-only, named
    /// `.jsonl`, at most one an hour.
    @Test func archiveAppendsAreCopiedAtMostOnceAnHour() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        #expect(rig.memory.archive("I grow invented chillies.", role: .user, channel: "text"))
        let first = MemoryBackups.name(.archive, stamp: Int64(epoch))
        #expect(first == "archive-\(Int64(epoch)).jsonl")
        #expect(rig.backupNames() == [first])
        #expect(bytes(rig.backupDir + "/" + first) == bytes(rig.path("memory/archive.jsonl")))
        #expect(mode(rig.backupDir + "/" + first) == 0o600)
        rig.clock.advance(1_800)
        #expect(rig.memory.archive("Splendid, sir.", role: .jarvis, channel: "text"))
        #expect(rig.backupNames() == [first])                           // within the hour: no copy
        rig.clock.advance(1_800)
        #expect(rig.memory.archive("They are very hot.", role: .user, channel: "text"))
        let second = MemoryBackups.name(.archive, stamp: Int64(epoch) + 3_600)
        #expect(rig.backupNames() == [first, second])
        let copied = try #require(bytes(rig.backupDir + "/" + second))
        #expect(copied == bytes(rig.path("memory/archive.jsonl")))
        #expect(BackedUpFile.archive.entries(in: copied) == 3)
        #expect(MemoryBackups.stamp(second, of: .archive) == Int64(epoch) + 3_600)
        #expect(MemoryBackups.stamp(second, of: .facts) == nil)
    }

    /// Without the lease neither the message nor a copy is written.
    @Test func withoutTheLeaseNoArchiveCopyIsWritten() throws {
        let lease = HandLease(false)
        let rig = try Rig(lease: lease)
        defer { rig.sb.remove() }
        #expect(!rig.memory.archive("I grow invented chillies.", role: .user, channel: "text"))
        #expect(rig.backupNames().isEmpty)
    }

    /// An archive's entries are its messages; one with lines of which none is a message cannot be
    /// read, and an empty one holds none.
    @Test func anArchivesEntriesAreItsMessages() {
        let line = ArchiveEntry(timestamp: epoch, date: "2026-09-28", channel: "text", role: .user, text: "Hello.").line
        #expect(BackedUpFile.archive.entries(in: Data((line + "\n" + line + "\n").utf8)) == 2)
        #expect(BackedUpFile.archive.entries(in: Data((line + "\n{\"timestamp\": 17").utf8)) == 1)   // a torn end
        #expect(BackedUpFile.archive.entries(in: Data()) == 0)
        #expect(BackedUpFile.archive.entries(in: Data("not an archive\n".utf8)) == nil)
    }

    /// The launch check covers the archive like the others: a torn last line is fine; one that
    /// cannot be read is put back from the newest readable copy, its bytes kept aside; and more
    /// than 10% fewer messages than the newest copy is a warning, with both kept.
    @Test func theLaunchCheckCoversTheArchive() throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        for k in 0..<10 { #expect(rig.memory.archive("Invented message \(k).", role: .user, channel: "text")) }
        let archive = rig.path("memory/archive.jsonl")
        let good = try #require(bytes(archive))
        rig.clock.advance(3_600)
        #expect(rig.memory.checkAtLaunch()[.archive] == .fine)              // and a copy of all ten
        let copy = Int64(epoch) + 3_600
        #expect(rig.memory.backups.newestReadable(.archive)?.stamp == copy)
        #expect(rig.memory.backups.newestReadable(.archive)?.entries == 10)

        try (good + Data("{\"timestamp\": 17".utf8)).write(to: URL(fileURLWithPath: archive))
        #expect(rig.memory.checkAtLaunch()[.archive] == .fine)

        try Data("not an archive\n".utf8).write(to: URL(fileURLWithPath: archive))
        rig.clock.advance(60)
        #expect(rig.memory.checkAtLaunch()[.archive] == .restored(stamp: copy))
        #expect(bytes(archive) == good)
        #expect(bytes(rig.backupDir + "/archive-\(copy + 60).unreadable") == Data("not an archive\n".utf8))
        #expect(rig.lines.all.contains(
            "memory: memory/archive.jsonl was unreadable; restored the backup from 2026-09-28 09:00 (10 entries)"))

        let eight = good.split(separator: 0x0A).prefix(8).reduce(Data()) { $0 + Data($1) + Data([0x0A]) }
        try eight.write(to: URL(fileURLWithPath: archive))
        #expect(rig.memory.checkAtLaunch()[.archive] == .shrank(from: 10, to: 8, stamp: copy))
        #expect(bytes(archive) == eight)
        #expect(bytes(rig.backupDir + "/archive-\(copy).kept.jsonl") == good)
    }
}
