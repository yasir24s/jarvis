import Foundation
import JarvisCore
import Synchronization

/// The volume the memory folder is on: its total capacity (`volumeTotalCapacityKey`) and the
/// space free on it, in bytes. Tests pass a fake volume.
public protocol VolumeProbing: Sendable {
    func capacity() -> (total: Int64, available: Int64)?
}

/// The volume holding `path`, read when asked (it may change size, or be another disk). Free
/// space is what the system says an app can use for important data, which counts purgeable
/// space; when that is unknown, the plain free space.
public struct LiveVolume: VolumeProbing {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func capacity() -> (total: Int64, available: Int64)? {
        var url = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)), url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
        }
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                              .volumeAvailableCapacityForImportantUsageKey,
                                                              .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return (Int64(total), available)
    }
}

/// W1 part 6, the storage rule: all of JARVIS's memory (`memory/`: conversations, facts, the
/// journal, the backups, the search database and its web pages) may use at most `capShare`
/// (10%) of the volume's total capacity, however big or small the drive, and the free space on
/// the volume must stay at or above `floorShare` (3%) of it. At either limit, the oldest web
/// pages are compacted first (`WebMemory.compactOldest`: the text dropped, the summary, key
/// points and URL kept compressed), a batch at a time, until both hold again or no page is left
/// to compact. Conversations, facts, the journal and the backups are never compacted away: when
/// only they remain over the limit, a warning is logged and nothing is removed.
///
/// Checked after every write to the web store and at launch. Each compaction is logged, with
/// sizes only.
public final class MemoryBudget: Sendable {
    public static let capShare = 0.10
    public static let floorShare = 0.03
    /// At most this many pages are compacted between measurements (fewer when their text
    /// already covers what is over).
    public static let batch = 20

    /// One check, in bytes.
    public struct Check: Sendable, Equatable {
        public let total: Int64
        public let available: Int64
        public let used: Int64
        public let cap: Int64
        public let floor: Int64
        public let compacted: Int
        public let freed: Int64
        /// Both limits hold after the check.
        public let within: Bool
    }

    private let folder: String
    private let volume: any VolumeProbing
    private let web: WebMemory
    private let usage: @Sendable () -> Int64
    private let log: @Sendable (String) -> Void
    private let lock = Mutex(())

    /// - Parameters:
    ///   - folder: the memory folder (`<state root>/memory`), measured whole.
    ///   - usage: its size; nil means the files' allocated size on disk. Tests may pass their own.
    public init(folder: String, volume: any VolumeProbing, web: WebMemory, usage: (@Sendable () -> Int64)? = nil,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.folder = folder
        self.volume = volume
        self.web = web
        self.usage = usage ?? { MemoryBudget.size(of: folder) }
        self.log = log
    }

    /// The memory folder of `memory`'s state root, on its own volume.
    public convenience init(memory: MemoryStore, web: WebMemory,
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        let folder = (memory.root.hasSuffix("/") ? memory.root : memory.root + "/") + "memory"
        self.init(folder: folder, volume: LiveVolume(path: folder), web: web, log: log)
    }

    /// Measures, and compacts the oldest pages while over either limit. One check at a time.
    @discardableResult
    public func check() -> Check? {
        lock.withLock { _ in
            guard let space = volume.capacity() else { return nil }
            let cap = Int64(Double(space.total) * Self.capShare)
            let floor = Int64(Double(space.total) * Self.floorShare)
            var used = usage(), available = space.available
            var compacted = 0
            var freed: Int64 = 0
            while used > cap || available < floor {
                let need = max(used - cap, floor - available)          // what the oldest pages' text should cover
                let step = web.compactOldest(Self.batch, upTo: Int(clamping: need))
                guard step.pages > 0 else { break }
                web.reclaim()
                compacted += step.pages
                let before = used
                used = usage()
                let gain = max(0, before - used)
                freed += gain
                available = volume.capacity()?.available ?? available
            }
            let within = used <= cap && available >= floor
            if compacted > 0 {
                log("memory: compacted \(compacted) web page(s), oldest first (\(Self.mb(freed)) freed): memory/ uses "
                    + "\(Self.mb(used)) of a \(Self.mb(cap)) cap (10% of \(Self.mb(space.total))); \(Self.mb(available)) "
                    + "free, floor \(Self.mb(floor))")
            }
            if !within {
                log("memory: WARNING over the storage rule with no web page left to compact: memory/ uses "
                    + "\(Self.mb(used)) of a \(Self.mb(cap)) cap; \(Self.mb(available)) free, floor \(Self.mb(floor)); "
                    + "conversations, facts, the journal and backups are kept")
            }
            return Check(total: space.total, available: available, used: used, cap: cap, floor: floor,
                         compacted: compacted, freed: freed, within: within)
        }
    }

    /// A folder's files' allocated size on disk, all the way down.
    public static func size(of folder: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys)
        else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walk {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}

/// Holds the budget the web memory checks after each write, set once both exist (the budget
/// compacts the web memory, so neither can be made with the other).
public final class BudgetHook: Sendable {
    private let budget = Mutex<MemoryBudget?>(nil)

    public init() {}

    public func set(_ value: MemoryBudget) { budget.withLock { $0 = value } }

    /// The check, when the budget is set.
    public func check() {
        let current = budget.withLock { $0 }
        current?.check()
    }
}
