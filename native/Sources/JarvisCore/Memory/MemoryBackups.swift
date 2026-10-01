import Foundation
import Synchronization

// P6 (DEV-P6-02, proposed): memory that can't be lost. Owner-only copies of facts.json,
// personality.json and profile.json in memory/backups/, at most one an hour per file, so a bad
// write, a wipe or a damaged file can be undone. personality.json and profile.json are shared
// with Python: they are copied byte for byte and their own format never changes. Logs carry
// file names and counts only, never what the files hold.

/// A file the backups cover.
public enum BackedUpFile: String, CaseIterable, Sendable {
    case facts
    case personality
    case profile

    /// The file's path under the state root.
    public var relativePath: String {
        switch self {
        case .facts: MemoryFile.facts.rawValue
        case .personality: StateFile.personality.rawValue
        case .profile: StateFile.profile.rawValue
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
    /// facts; personality.json's core lines and learned notes; profile.json's facts.
    public func entries(in data: Data) -> Int? {
        switch self {
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

/// The rotation in memory/backups/: `<file>-<unix seconds>.json`, at most one an hour per file,
/// the newest `hourlyKept` and the newest of each of the last `dailyKept` days kept. A copy put
/// aside by the launch check (`.kept.json`, `.unreadable`) is never rotated out.
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
        "\(file.rawValue)-\(stamp).json"
    }

    /// The stamp in a rotating backup's name; nil for any other name.
    public static func stamp(_ name: String, of file: BackedUpFile) -> Int64? {
        let head = file.rawValue + "-", tail = ".json"
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
    public func newestReadable(_ file: BackedUpFile) -> (stamp: Int64, data: Data, entries: Int)? {
        for stamp in stamps(file) {
            if let data = read(file, stamp: stamp), let n = file.entries(in: data) { return (stamp, data, n) }
        }
        return nil
    }

    /// After a successful write of `file` as `data`: a copy when there is none from the last
    /// hour, then the rotation. False when no copy was due or it could not be written.
    @discardableResult
    public func afterWrite(_ file: BackedUpFile, data: Data) -> Bool {
        lock.withLock { _ in
            let now = clock.now()
            let existing = stamps(file)
            if let newest = existing.first, now - Double(newest) < Self.interval, Double(newest) <= now { return false }
            let stamp = Int64(now.rounded(.down))
            guard writeCopy(data, name: Self.name(file, stamp: stamp)) else { return false }
            let keep = Self.kept([stamp] + existing, timeZone: timeZone)
            for old in existing where !keep.contains(old) {
                try? FileManager.default.removeItem(atPath: StateStore.join(directory, Self.name(file, stamp: old)))
            }
            return true
        }
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
