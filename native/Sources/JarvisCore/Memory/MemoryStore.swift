import Foundation
import Synchronization

/// The typed face of `memory/` (D-51, P2): the append-only archive and the compiled facts.
/// Every write goes through the lease-holding `StateStore`, so nothing is written without the
/// lease. Message and fact text is never logged; callers log counts only.
///
/// P6 (DEV-P6-02, proposed): every successful facts write is followed by `MemoryBackups`' hourly
/// copy, and so is every save of personality.json and profile.json on the same `StateStore` and
/// (P6b) every archive append. A
/// write that would drop more than `dropLimit` facts, or more than `dropShare` of them, is
/// refused and logged, unless it removes exactly the ids forget_memory was given. Forgotten facts
/// go to the forgotten bin first (DEV-P6-03), and `checkAtLaunch` repairs or flags the files.
public final class MemoryStore: Sendable {
    /// The mass-deletion guard: a write may drop at most this many facts...
    public static let dropLimit = 10
    /// ...and at most this share of them.
    public static let dropShare = 0.1

    private let store: StateStore
    private let clock: any JarvisClock
    private let timeZone: TimeZone
    private let factsLock = Mutex(())                  // one facts read-modify-write at a time
    private let log: @Sendable (String) -> Void
    /// The hourly copies of facts.json, personality.json and profile.json.
    public let backups: MemoryBackups

    public init(store: StateStore, clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .current,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
        let backups = MemoryBackups(store: store, clock: clock, timeZone: timeZone, log: log)
        self.backups = backups
        store.onSave { [weak backups] f, data in
            guard let backups, let file = BackedUpFile(f) else { return }
            backups.afterWrite(file, data: data)
        }
    }

    // MARK: - Archive

    /// Appends one message, stamped now. False when the lease is not held or the write failed.
    /// P6b: a successful append is followed by the hourly backup of the whole archive.
    @discardableResult
    public func archive(_ text: String, role: MemoryRole, channel: String) -> Bool {
        let entry = ArchiveEntry(timestamp: clock.now(), timeZone: timeZone, channel: channel,
                                 role: role, text: text)
        guard store.appendLine(entry.line, to: .archive) else { return false }
        let store = store
        backups.afterAppend(.archive) { store.read(.archive) }
        return true
    }

    /// The whole archive lines after byte `offset`, and the offset just past the last of them
    /// (a torn final line is left for next time). An offset past the end means the archive was
    /// replaced, so reading starts over. Lines that do not parse are skipped.
    public func archive(after offset: Int) -> (entries: [ArchiveEntry], end: Int) {
        let read = archiveLines(after: offset)
        return (read.entries, read.end)
    }

    /// `archive(after:)` with, for each entry, the byte offset just past its line (P6b: the
    /// compile moves `compiled_through` on after each batch it finishes).
    public func archiveLines(after offset: Int) -> (entries: [ArchiveEntry], ends: [Int], end: Int) {
        guard let handle = FileHandle(forReadingAtPath: store.path(.archive)) else { return ([], [], 0) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], [], 0) }
        let start = offset >= 0 && UInt64(offset) <= size ? UInt64(offset) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return ([], [], Int(start)) }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], [], Int(start)) }
        let whole = data[data.startIndex...lastNewline]
        var entries: [ArchiveEntry] = [], ends: [Int] = []
        for line in whole.split(separator: 0x0A) {
            guard let entry = ArchiveEntry(line: Data(line)) else { continue }
            entries.append(entry)
            ends.append(Int(start) + whole.distance(from: whole.startIndex, to: line.endIndex) + 1)
        }
        return (entries, ends, Int(start) + whole.count)
    }

    /// The archives search_memory reads (P6b), in this order.
    public static let searchedArchives: [MemoryFile] = [.archive]

    /// P6b: every message in `searchedArchives`, each file's oldest first. Lines that do not
    /// parse, and a torn final line, are skipped.
    public func archivedMessages() -> [ArchiveEntry] {
        Self.searchedArchives.flatMap { file -> [ArchiveEntry] in
            guard let data = store.read(file) else { return [] }
            return data.split(separator: 0x0A).compactMap { ArchiveEntry(line: Data($0)) }
        }
    }

    // MARK: - Facts

    /// The facts file: empty when there is none yet, nil when one exists and cannot be read
    /// (it is then never overwritten, so a damaged file loses nothing).
    public func loadFacts() -> FactsFile? {
        guard let data = store.read(.facts) else {
            return FileManager.default.fileExists(atPath: store.path(.facts)) ? nil : FactsFile()
        }
        return FactsFile(data: data)
    }

    /// Loads the facts, lets `body` change them, and saves them atomically when it returns
    /// true. False when the file is unreadable, `body` declined, or the save was refused
    /// (including by the mass-deletion guard, `writeFacts`).
    @discardableResult
    public func updateFacts(_ body: (inout FactsFile) -> Bool) -> Bool {
        writeFacts(body) == .saved
    }

    /// What a facts write did.
    public enum FactsWrite: Sendable, Equatable {
        case saved
        case declined                        // `body` returned false
        case unreadable                      // facts.json exists and does not parse: left as it is
        case refused(dropped: Int, of: Int)  // the mass-deletion guard
        case notSaved                        // no lease, or the write failed
    }

    /// `updateFacts` with its outcome. The guard counts the entries on disk that the new file
    /// no longer has (by id; an entry the loader could not read counts as dropped), less the
    /// ids in `allowed` (forget_memory's own ids), and refuses more than `dropLimit` or more
    /// than `dropShare` of the entries. A saved write is followed by the hourly backup.
    public func writeFacts(allowingRemovalOf allowed: Set<String> = [],
                           _ body: (inout FactsFile) -> Bool) -> FactsWrite {
        factsLock.withLock { _ in
            guard var file = loadFacts() else {
                log("memory: facts.json unreadable; left as it is")
                return .unreadable
            }
            guard body(&file) else { return .declined }
            return save(file, allowing: allowed)
        }
    }

    /// The guard, the write and the backup; under `factsLock`.
    private func save(_ file: FactsFile, allowing allowed: Set<String>) -> FactsWrite {
        if let refusal = refusal(file, allowing: allowed) { return refusal }
        let data = file.data
        guard store.write(data, to: .facts) else { return .notSaved }
        backups.afterWrite(.facts, data: data)
        return .saved
    }

    /// The mass-deletion guard's verdict on writing `file` (logged when it refuses); nil = go ahead.
    private func refusal(_ file: FactsFile, allowing allowed: Set<String>) -> FactsWrite? {
        let onDisk = store.read(.facts).map(FactsFile.entryIDs) ?? []
        let kept = Set(file.facts.map(\.id))
        let dropped = onDisk.filter { id in id.map { !kept.contains($0) && !allowed.contains($0) } ?? true }.count
        guard dropped > Self.dropLimit || Double(dropped) > Self.dropShare * Double(onDisk.count) else { return nil }
        log("memory: a facts write that would drop \(dropped) of \(onDisk.count) facts was refused")
        return .refused(dropped: dropped, of: onDisk.count)
    }

    // MARK: - Forgetting and restoring (P6)

    /// The forgotten bin, with entries past `ForgottenFile.keptFor` left out: empty when there
    /// is none, nil when one exists and cannot be read.
    public func loadForgotten() -> ForgottenFile? {
        guard let data = store.read(.forgotten) else {
            return FileManager.default.fileExists(atPath: store.path(.forgotten)) ? nil : ForgottenFile()
        }
        return ForgottenFile(data: data)?.purged(now: clock.now())
    }

    /// What `forget` and `restore` did.
    public enum MoveOutcome: Sendable, Equatable {
        case moved([MemoryFact])
        case nothing                         // nothing was picked
        case unreadable                      // facts.json or forgotten.json does not parse
        case refused(dropped: Int, of: Int)  // the mass-deletion guard
        case notSaved                        // no lease, or a write failed
    }

    /// forget_memory's removal: `pick` chooses facts (by index) from the loaded file, and they
    /// move to the forgotten bin, stamped now. The bin is written first, so a failed facts write
    /// loses nothing (the bin is then put back as it was). `byIDs` (forget_memory given ids)
    /// exempts the picked facts from the mass-deletion guard; nothing else is exempt.
    public func forget(byIDs: Bool, _ pick: (FactsFile) -> Set<Int>) -> MoveOutcome {
        factsLock.withLock { _ in
            guard let file = loadFacts() else { return .unreadable }
            guard let bin = loadForgotten() else {
                log("memory: forgotten.json unreadable; nothing forgotten")
                return .unreadable
            }
            let picked = pick(file).filter { file.facts.indices.contains($0) }
            guard !picked.isEmpty else { return .nothing }
            let removed = picked.sorted().map { file.facts[$0] }
            var after = file
            after.facts = file.facts.indices.filter { !picked.contains($0) }.map { file.facts[$0] }
            let allowed = byIDs ? Set(removed.map(\.id)) : []
            if case .refused(let d, let n)? = refusal(after, allowing: allowed) { return .refused(dropped: d, of: n) }
            var newBin = bin
            newBin.entries += removed.map { ForgottenFile.Entry(fact: $0, forgotten: clock.now()) }
            let before = store.read(.forgotten)
            guard store.write(newBin.data, to: .forgotten) else { return .notSaved }
            guard save(after, allowing: allowed) == .saved else {
                // Put the bin back as it was: the facts are still in facts.json.
                if let before {
                    store.write(before, to: .forgotten)
                } else {
                    try? FileManager.default.removeItem(atPath: store.path(.forgotten))
                }
                return .notSaved
            }
            return .moved(removed)
        }
    }

    /// restore_memory's return: `pick` chooses entries (by index) from the bin, and their facts
    /// go back into facts.json as they were (a fact whose id is there already is not added
    /// twice), then leave the bin. facts.json is written first, so a failed bin write leaves the
    /// fact in both places and loses nothing.
    public func restore(_ pick: (ForgottenFile) -> Set<Int>) -> MoveOutcome {
        factsLock.withLock { _ in
            guard var file = loadFacts() else { return .unreadable }
            guard let bin = loadForgotten() else { return .unreadable }
            let picked = pick(bin).filter { bin.entries.indices.contains($0) }
            guard !picked.isEmpty else { return .nothing }
            let back = picked.sorted().map { bin.entries[$0].fact }
            let present = Set(file.facts.map(\.id))
            file.facts += back.filter { !present.contains($0.id) }
            let outcome = save(file, allowing: [])
            guard outcome == .saved else {
                if case .refused(let d, let n) = outcome { return .refused(dropped: d, of: n) }
                return .notSaved
            }
            let left = ForgottenFile(entries: bin.entries.indices.filter { !picked.contains($0) }.map { bin.entries[$0] })
            if !store.write(left.data, to: .forgotten) {
                log("memory: \(back.count) restored fact(s) are still listed in forgotten.json")
            }
            return .moved(back)
        }
    }

    // MARK: - The launch check (P6)

    /// What the launch check found for one file.
    public enum LaunchFinding: Sendable, Equatable {
        case fine                                       // readable, and not shrunk against its newest backup
        case restored(stamp: Int64)                     // was unreadable: the newest readable backup put back
        case unreadableWithoutBackup                    // unreadable, and no readable backup: left as it is
        case shrank(from: Int, to: Int, stamp: Int64)   // kept as it is, and so is that backup
    }

    /// Run once at launch, before anything writes. For facts.json, personality.json,
    /// profile.json and (P6b) the archive: an unreadable file (empty, damaged, or not that file's
    /// shape; for the archive, lines of which not one is a message) is replaced by its newest
    /// readable backup and logged, its bytes put aside as `<file>-<now>.unreadable`. A file
    /// holding more than `dropShare` fewer entries than its newest backup, beyond the facts
    /// forgotten since that backup, is logged as a warning and both are kept: the backup is put
    /// aside as `<file>-<stamp>.kept.json` (`.kept.jsonl` for the archive), out of the rotation.
    /// A missing file counts as empty.
    /// Then the forgotten bin drops what is past 30 days, and each readable file that has no
    /// backup from the last hour gets one. Shared files are copied byte for byte.
    @discardableResult
    public func checkAtLaunch() -> [BackedUpFile: LaunchFinding] {
        factsLock.withLock { _ in
            var report: [BackedUpFile: LaunchFinding] = [:]
            for file in BackedUpFile.allCases { report[file] = check(file) }
            purgeForgotten()
            for file in BackedUpFile.allCases {
                if case .restored? = report[file] { continue }
                if let data = AtomicFile.read(path(file)), file.entries(in: data) != nil {
                    backups.afterWrite(file, data: data)
                }
            }
            return report
        }
    }

    private func path(_ file: BackedUpFile) -> String {
        StateStore.join(store.root, file.relativePath)
    }

    private func check(_ file: BackedUpFile) -> LaunchFinding {
        let name = file.relativePath
        let exists = FileManager.default.fileExists(atPath: path(file))
        let data = AtomicFile.read(path(file))
        let entries = data.flatMap(file.entries)
        if exists && entries == nil {
            guard let backup = backups.newestReadable(file) else {
                log("memory: \(name) is unreadable and has no readable backup; left as it is")
                return .unreadableWithoutBackup
            }
            if let data, !data.isEmpty {
                backups.keepAside(data, name: "\(file.rawValue)-\(Int64(clock.now().rounded(.down))).unreadable")
            }
            let restored = switch file {
            case .facts: store.write(backup.data, to: .facts)
            case .personality: store.restore(.personality, bytes: backup.data)
            case .profile: store.restore(.profile, bytes: backup.data)
            case .archive: store.write(backup.data, to: .archive)
            }
            guard restored else {
                log("memory: \(name) is unreadable and its backup could not be put back; left as it is")
                return .unreadableWithoutBackup
            }
            log("memory: \(name) was unreadable; restored the backup from \(when(backup.stamp)) "
                + "(\(backup.entries) entries)")
            return .restored(stamp: backup.stamp)
        }
        guard let newest = backups.newestReadable(file) else { return .fine }
        let current = entries ?? 0
        let forgotten = file == .facts ? forgottenCount(since: Double(newest.stamp)) : 0
        let unexplained = newest.entries - current - forgotten
        guard Double(unexplained) > Self.dropShare * Double(newest.entries) else { return .fine }
        let aside = "\(file.rawValue)-\(newest.stamp).kept.\(file.fileExtension)"
        let kept = backups.keepAside(newest.data, name: aside)
        log("memory: WARNING \(name) holds \(current) entries, \(newest.entries - current) fewer than the backup "
            + "from \(when(newest.stamp)) (\(newest.entries)), with \(forgotten) forgotten since; both kept"
            + (kept ? " (the backup as \(aside))" : ""))
        return .shrank(from: newest.entries, to: current, stamp: newest.stamp)
    }

    /// The forgotten bin's entries forgotten at or after `t`.
    private func forgottenCount(since t: Double) -> Int {
        guard let data = store.read(.forgotten), let bin = ForgottenFile(data: data) else { return 0 }
        return bin.entries.filter { $0.forgotten >= t }.count
    }

    /// Drops the bin's entries past `ForgottenFile.keptFor`.
    private func purgeForgotten() {
        guard let data = store.read(.forgotten) else { return }
        guard let bin = ForgottenFile(data: data) else {
            log("memory: forgotten.json unreadable; left as it is")
            return
        }
        let kept = bin.purged(now: clock.now())
        guard kept.entries.count < bin.entries.count else { return }
        if store.write(kept.data, to: .forgotten) {
            log("memory: \(bin.entries.count - kept.entries.count) forgotten fact(s) past 30 days dropped")
        }
    }

    /// A backup's stamp as local time, for the log.
    private func when(_ stamp: Int64) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(stamp)))
    }
}
