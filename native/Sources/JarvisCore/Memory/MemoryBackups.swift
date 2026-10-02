import Foundation
import Synchronization

// P6 (DEV-P6-02, proposed): memory that can't be lost. Owner-only copies of facts.json,
// personality.json and profile.json in memory/backups/, at most one an hour per file, so a bad
// write, a wipe or a damaged file can be undone. personality.json and profile.json are shared
// with Python: they are copied byte for byte and their own format never changes. P6b: the
// conversation archive too, copied whole after an append, the Python-era archive after the
// import writes it, and the task journal after an append. Logs carry file names and counts only,
// never what the files hold.
//
// W1 part 7c: the three append-only files are backed up as segments of new bytes instead of
// whole copies: `<file>-seg-<start>-<end>-<unix seconds>.jsonl` holds the file's bytes from
// `start` to `end`, at most one an hour. The segments from 0, end to start, are the file.
// Past `segmentLimit` they are merged into one; a file that is no longer an append of its
// segments (rewritten, or shrunk) has them put aside as `<segment>.kept`, never removed, and
// starts again from 0. A first segment from 0 retires P6b's whole copies that it contains.

/// A file the backups cover.
public enum BackedUpFile: String, CaseIterable, Sendable {
    case facts
    case personality
    case profile
    case archive                    // P6b: memory/archive.jsonl, append-only
    case pythonArchive = "archive-python" // P6b: memory/archive-python.jsonl, written once
    case journal                    // P6b: memory/journal.jsonl, append-only

    /// The file's path under the state root.
    public var relativePath: String {
        switch self {
        case .facts: MemoryFile.facts.rawValue
        case .personality: StateFile.personality.rawValue
        case .profile: StateFile.profile.rawValue
        case .archive: MemoryFile.archive.rawValue
        case .pythonArchive: MemoryFile.pythonArchive.rawValue
        case .journal: MemoryFile.journal.rawValue
        }
    }

    /// W1 part 7c: an append-only file, backed up in segments of new bytes.
    public var isSegmented: Bool {
        switch self {
        case .archive, .pythonArchive, .journal: true
        case .facts, .personality, .profile: false
        }
    }

    /// The extension of its copies: the file's own.
    public var fileExtension: String {
        switch self {
        case .facts, .personality, .profile: "json"
        case .archive, .pythonArchive, .journal: "jsonl"
        }
    }

    /// The backed-up file for a shared state file, if it is one.
    public init?(_ f: StateFile) {
        switch f {
        case .personality: self = .personality
        case .profile: self = .profile
        default: return nil
        }
    }

    /// How many entries the bytes hold, nil when they cannot be read as this file: facts.json's
    /// facts; personality.json's core lines and learned notes; profile.json's facts; an
    /// archive's messages (nil when it has lines and not one of them is a message); the journal's
    /// calls (likewise).
    public func entries(in data: Data) -> Int? {
        switch self {
        case .journal:
            let lines = data.split(separator: 0x0A)
            let calls = lines.filter { JournalEntry(line: Data($0)) != nil }.count
            return calls == 0 && !lines.isEmpty ? nil : calls
        case .archive, .pythonArchive:
            let lines = data.split(separator: 0x0A)
            let messages = lines.filter { ArchiveEntry(line: Data($0)) != nil }.count
            return messages == 0 && !lines.isEmpty ? nil : messages
        case .facts:
            return FactsFile(data: data)?.facts.count
        case .personality:
            guard case .object(let p)? = try? PyJSON.loads(data) else { return nil }
            return (p["core"]?.arrayValue?.count ?? 0) + (p["learned"]?.arrayValue?.count ?? 0)
        case .profile:
            guard case .object(let p)? = try? PyJSON.loads(data) else { return nil }
            return p["facts"]?.objectValue?.count ?? 0
        }
    }
}

/// The rotation in memory/backups/: `<file>-<unix seconds>.json` (`.jsonl` for an archive), at
/// most one an hour per file, the newest `hourlyKept` and the newest of each of the last
/// `dailyKept` days kept. A copy put aside by the launch check (`.kept.json`, `.unreadable`) is
/// never rotated out.
public final class MemoryBackups: Sendable {
    public static let folder = "memory/backups"
    public static let interval: Double = 3600
    public static let hourlyKept = 48
    public static let dailyKept = 30

    private let store: StateStore
    private let clock: any JarvisClock
    private let timeZone: TimeZone
    private let log: @Sendable (String) -> Void
    private let lock = Mutex(())

    public init(store: StateStore, clock: any JarvisClock, timeZone: TimeZone,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    public var directory: String { StateStore.join(store.root, Self.folder) }

    /// A rotating backup's name.
    public static func name(_ file: BackedUpFile, stamp: Int64) -> String {
        "\(file.rawValue)-\(stamp).\(file.fileExtension)"
    }

    /// The stamp in a rotating backup's name; nil for any other name.
    public static func stamp(_ name: String, of file: BackedUpFile) -> Int64? {
        let head = file.rawValue + "-", tail = "." + file.fileExtension
        guard name.hasPrefix(head), name.hasSuffix(tail), name.count > head.count + tail.count else { return nil }
        let digits = name.dropFirst(head.count).dropLast(tail.count)
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int64(digits)
    }

    /// The rotating backups of `file`, newest first.
    public func stamps(_ file: BackedUpFile) -> [Int64] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { Self.stamp($0, of: file) }.sorted(by: >)
    }

    /// The bytes of one rotating backup.
    public func read(_ file: BackedUpFile, stamp: Int64) -> Data? {
        AtomicFile.read(StateStore.join(directory, Self.name(file, stamp: stamp)))
    }

    /// The newest backup of `file` whose bytes read as that file, with its stamp and entry count.
    /// W1 part 7c: for an append-only file, its segments joined (stamped with the newest of
    /// them) when they read; else its newest whole copy, as P6b took them.
    public func newestReadable(_ file: BackedUpFile) -> (stamp: Int64, data: Data, entries: Int)? {
        if file.isSegmented, case let chain = chain(file), let last = chain.last,
           let data = joined(file, chain), let n = file.entries(in: data) {
            return (chain.map(\.stamp).max() ?? last.stamp, data, n)
        }
        for stamp in stamps(file) {
            if let data = read(file, stamp: stamp), let n = file.entries(in: data) { return (stamp, data, n) }
        }
        return nil
    }

    /// After a successful write of `file` as `data`: a copy when there is none from the last
    /// hour, then the rotation. False when no copy was due or it could not be written. W1 part
    /// 7c: for an append-only file, a segment of the bytes past its last one instead.
    @discardableResult
    public func afterWrite(_ file: BackedUpFile, data: Data) -> Bool {
        lock.withLock { _ in
            guard file.isSegmented else { return copyIfDue(file) { data } }
            return segmentIfDue(file, size: data.count) { range in
                range.upperBound <= data.count ? data.subdata(in: range) : nil
            }
        }
    }

    /// P6b: after an append to `file` (an append-only file at `path`). W1 part 7c: a segment of
    /// the bytes it gained since its last one, when one is due; only those bytes, and the last
    /// segment's (to check the file is still an append of them), are read. False when none was
    /// due, or the file could not be read or the segment written.
    @discardableResult
    public func afterAppend(_ file: BackedUpFile, path: String) -> Bool {
        lock.withLock { _ in
            guard let handle = FileHandle(forReadingAtPath: path) else { return false }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return false }
            return segmentIfDue(file, size: Int(size)) { range in
                guard (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil,
                      let bytes = try? handle.read(upToCount: range.count), bytes.count == range.count
                else { return nil }
                return bytes
            }
        }
    }

    // MARK: - Segments (W1 part 7c)

    /// Past this many segments, they are merged into one.
    public static let segmentLimit = 48

    /// One segment: the file's bytes from `start` to `end`, taken at `stamp`.
    public struct Segment: Sendable, Equatable {
        public let start: Int
        public let end: Int
        public let stamp: Int64

        public init(start: Int, end: Int, stamp: Int64) {
            self.start = start
            self.end = end
            self.stamp = stamp
        }
    }

    /// A segment's name.
    public static func segmentName(_ file: BackedUpFile, _ segment: Segment) -> String {
        "\(file.rawValue)-seg-\(segment.start)-\(segment.end)-\(segment.stamp).\(file.fileExtension)"
    }

    /// The segment a name holds; nil for any other name.
    public static func segment(_ name: String, of file: BackedUpFile) -> Segment? {
        let head = file.rawValue + "-seg-", tail = "." + file.fileExtension
        guard name.hasPrefix(head), name.hasSuffix(tail) else { return nil }
        let parts = name.dropFirst(head.count).dropLast(tail.count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let start = Int(parts[0]), let end = Int(parts[1]), let stamp = Int64(parts[2]), start < end
        else { return nil }
        return Segment(start: start, end: end, stamp: stamp)
    }

    /// Every segment of `file` on disk, by start.
    public func segments(_ file: BackedUpFile) -> [Segment] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { Self.segment($0, of: file) }.sorted {
            ($0.start, $0.end, $0.stamp) < ($1.start, $1.end, $1.stamp)
        }
    }

    /// The segments that make up the file: from 0, each starting where the one before ended
    /// (the longest at each start), each file the size its name says.
    public func chain(_ file: BackedUpFile) -> [Segment] {
        let all = segments(file)
        var chain: [Segment] = [], at = 0
        while let next = all.filter({ $0.start == at && size(file, $0) == $0.end - $0.start })
            .max(by: { ($0.end, $0.stamp) < ($1.end, $1.stamp) }) {
            chain.append(next)
            at = next.end
        }
        return chain
    }

    /// The segments' bytes, joined; nil when one cannot be read.
    public func joined(_ file: BackedUpFile, _ chain: [Segment]) -> Data? {
        var data = Data()
        for segment in chain {
            guard let bytes = AtomicFile.read(StateStore.join(directory, Self.segmentName(file, segment))),
                  bytes.count == segment.end - segment.start
            else { return nil }
            data.append(bytes)
        }
        return data
    }

    private func size(_ file: BackedUpFile, _ segment: Segment) -> Int? {
        let path = StateStore.join(directory, Self.segmentName(file, segment))
        return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
    }

    /// The segment due after a write or an append, under `lock`: at most one an hour, holding
    /// the bytes from the end of the last segment to `size` (`read` gives a range of the file).
    /// When the file is no longer an append of its segments (smaller than they are, or its bytes
    /// over the last segment differ), they are put aside whole and it starts again from 0. Past
    /// `segmentLimit` segments, all are merged into one.
    private func segmentIfDue(_ file: BackedUpFile, size: Int, read: (Range<Int>) -> Data?) -> Bool {
        let now = clock.now()
        let all = segments(file)
        if let newest = all.map(\.stamp).max(), now - Double(newest) < Self.interval, Double(newest) <= now {
            return false
        }
        let stamp = Int64(now.rounded(.down))
        var chain = self.chain(file)
        if let last = chain.last {
            let kept = AtomicFile.read(StateStore.join(directory, Self.segmentName(file, last)))
            if size < last.end || read(last.start..<last.end) != kept {
                guard restart(file, all: all) else { return false }
                chain = []
            }
        } else if !all.isEmpty {
            guard restart(file, all: all) else { return false }    // pieces that do not start at 0
        }
        let start = chain.last?.end ?? 0
        guard size > start, let bytes = read(start..<size) else { return false }
        if chain.count + 1 > Self.segmentLimit, let old = joined(file, chain) {
            let merged = Segment(start: 0, end: size, stamp: stamp)
            guard writeCopy(old + bytes, name: Self.segmentName(file, merged)) else { return false }
            for segment in chain { remove(file, segment) }
            log("memory: \(file.relativePath) backup merged from \(chain.count + 1) segments into one")
            return true
        }
        let segment = Segment(start: start, end: size, stamp: stamp)
        guard writeCopy(bytes, name: Self.segmentName(file, segment)) else { return false }
        if start == 0 { retireWholeCopies(file, base: bytes) }
        return true
    }

    /// The file was rewritten: each of its segments is put aside as `<segment name>.kept`, out
    /// of the rotation and never removed (renamed, so nothing is copied). False without the lease.
    @discardableResult
    private func restart(_ file: BackedUpFile, all: [Segment]) -> Bool {
        guard store.mayWrite else { return false }
        for segment in all {
            let path = StateStore.join(directory, Self.segmentName(file, segment))
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".kept")
        }
        log("memory: \(file.relativePath) is no longer an append of its \(all.count) backup segment(s); "
            + "they are kept aside (.kept)")
        return true
    }

    /// P6b's whole copies of `file`, once a first segment holds the file from 0: each copy whose
    /// bytes begin `base` holds nothing the segment does not, and is removed. Any other is kept.
    private func retireWholeCopies(_ file: BackedUpFile, base: Data) {
        for stamp in stamps(file) {
            let path = StateStore.join(directory, Self.name(file, stamp: stamp))
            guard let copy = AtomicFile.read(path), copy.count <= base.count, base.prefix(copy.count) == copy else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private func remove(_ file: BackedUpFile, _ segment: Segment) {
        try? FileManager.default.removeItem(atPath: StateStore.join(directory, Self.segmentName(file, segment)))
    }

    /// The copy and the rotation, under `lock`.
    private func copyIfDue(_ file: BackedUpFile, _ data: () -> Data?) -> Bool {
        let now = clock.now()
        let existing = stamps(file)
        if let newest = existing.first, now - Double(newest) < Self.interval, Double(newest) <= now { return false }
        guard let data = data() else { return false }
        let stamp = Int64(now.rounded(.down))
        guard writeCopy(data, name: Self.name(file, stamp: stamp)) else { return false }
        let keep = Self.kept([stamp] + existing, timeZone: timeZone)
        for old in existing where !keep.contains(old) {
            try? FileManager.default.removeItem(atPath: StateStore.join(directory, Self.name(file, stamp: old)))
        }
        return true
    }

    /// The stamps the rotation keeps: the newest `hourlyKept`, and the newest of each of the
    /// newest `dailyKept` days (in `timeZone`).
    public static func kept(_ stamps: [Int64], timeZone: TimeZone) -> Set<Int64> {
        let newest = stamps.sorted(by: >)
        var keep = Set(newest.prefix(hourlyKept))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var days = Set<DateComponents>()
        for stamp in newest {
            let day = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: Double(stamp)))
            guard !days.contains(day) else { continue }
            guard days.count < dailyKept else { break }
            days.insert(day)
            keep.insert(stamp)
        }
        return keep
    }

    /// Puts `data` aside as `name` in the backups folder, never rotated out (the launch check's
    /// copies). False without the lease or on failure.
    @discardableResult
    public func keepAside(_ data: Data, name: String) -> Bool {
        lock.withLock { _ in writeCopy(data, name: name) }
    }

    /// Writes `data` as `name`: the folder owner-only (0700), the file 0600, atomically. Nothing
    /// is written without the lease.
    private func writeCopy(_ data: Data, name: String) -> Bool {
        guard store.mayWrite else {
            log("memory: backup \(name) not written: the lease is not held")
            return false
        }
        let fm = FileManager.default
        let memory = StateStore.join(store.root, "memory")
        do {
            for dir in [memory, directory] where !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            let path = StateStore.join(directory, name)
            if !fm.fileExists(atPath: path) {
                let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                close(fd)
            }
            try AtomicFile.write(data, to: path)            // keeps the target's 0600
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        } catch {
            log("memory: backup \(name) not written: \(error)")
            return false
        }
    }
}
