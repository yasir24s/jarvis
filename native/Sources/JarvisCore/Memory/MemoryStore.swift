import Foundation
import Synchronization

/// The typed face of `memory/` (D-51, P2): the append-only archive and the compiled facts.
/// Every write goes through the lease-holding `StateStore`, so nothing is written without the
/// lease. Message and fact text is never logged; callers log counts only.
public final class MemoryStore: Sendable {
    private let store: StateStore
    private let clock: any JarvisClock
    private let timeZone: TimeZone
    private let factsLock = Mutex(())                  // one facts read-modify-write at a time

    public init(store: StateStore, clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .current) {
        self.store = store
        self.clock = clock
        self.timeZone = timeZone
    }

    // MARK: - Archive

    /// Appends one message, stamped now. False when the lease is not held or the write failed.
    @discardableResult
    public func archive(_ text: String, role: MemoryRole, channel: String) -> Bool {
        let entry = ArchiveEntry(timestamp: clock.now(), timeZone: timeZone, channel: channel,
                                 role: role, text: text)
        return store.appendLine(entry.line, to: .archive)
    }

    /// The whole archive lines after byte `offset`, and the offset just past the last of them
    /// (a torn final line is left for next time). An offset past the end means the archive was
    /// replaced, so reading starts over. Lines that do not parse are skipped.
    public func archive(after offset: Int) -> (entries: [ArchiveEntry], end: Int) {
        guard let handle = FileHandle(forReadingAtPath: store.path(.archive)) else { return ([], 0) }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return ([], 0) }
        let start = offset >= 0 && UInt64(offset) <= size ? UInt64(offset) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return ([], Int(start)) }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], Int(start)) }
        let whole = data[data.startIndex...lastNewline]
        let entries = whole.split(separator: 0x0A).compactMap { ArchiveEntry(line: Data($0)) }
        return (entries, Int(start) + whole.count)
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
    /// true. False when the file is unreadable, `body` declined, or the save was refused.
    @discardableResult
    public func updateFacts(_ body: (inout FactsFile) -> Bool) -> Bool {
        factsLock.withLock { _ in
            guard var file = loadFacts() else {
                JarvisLog.log("memory: facts.json unreadable; left as it is", category: .state)
                return false
            }
            guard body(&file) else { return false }
            return store.write(file.data, to: .facts)
        }
    }
}
