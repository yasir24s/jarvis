import Foundation
import JarvisCore
import Synchronization

/// W1: JARVIS's search database, `memory/web/index.sqlite`, one SQLite file (the system
/// `SQLite3` module, FTS5) under the state root, owner-only. Part 7c's index of the conversations
/// and the task journal lives in it (`MemoryIndex`), and so does part 3's web memory. It is opened
/// on first use, and only while the lease is held. One that cannot be read is put aside as
/// `index.sqlite.damaged-<unix seconds>` and started again: the conversations are indexed again
/// from their files. Logs carry counts and SQLite's messages, never row text.
public final class MemoryDatabase: Sendable {
    public static let relativePath = "memory/web/index.sqlite"

    public let path: String
    private let mayWrite: @Sendable () -> Bool
    private let now: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private let connection = Mutex<SQLiteConnection?>(nil)

    public init(root: String, mayWrite: @escaping @Sendable () -> Bool,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        path = root.isEmpty || root.hasSuffix("/") ? root + Self.relativePath : root + "/" + Self.relativePath
        self.mayWrite = mayWrite
        self.now = now
        self.log = log
    }

    /// On `memory`'s state root, under its lease.
    public convenience init(memory: MemoryStore, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.init(root: memory.root, mayWrite: { memory.mayWrite }, now: now, log: log)
    }

    /// The database's folder, `memory/web/`.
    public var directory: String { (path as NSString).deletingLastPathComponent }

    /// Runs `body` on the open connection, under the lock. nil without the lease, when the
    /// database cannot be opened, or when `body` throws (logged).
    func with<T>(_ body: (SQLiteConnection) throws -> T) -> T? {
        guard mayWrite() else { return nil }
        return connection.withLock { open -> T? in
            if open == nil { open = opened() }
            guard let db = open else { return nil }
            do {
                return try body(db)
            } catch {
                log("memory: the search index failed (\(error))")
                return nil
            }
        }
    }

    /// Opens the file and creates the tables. A file that will not open or take the schema is
    /// put aside once and a new one made.
    private func opened() -> SQLiteConnection? {
        let fm = FileManager.default
        do {
            for dir in [(directory as NSString).deletingLastPathComponent, directory] where !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
            }
        } catch {
            log("memory: memory/web/ not created: \(error)")
            return nil
        }
        for attempt in 0..<2 {
            do {
                let db = try SQLiteConnection.open(path)
                try db.exec(Self.schema)
                return db
            } catch {
                guard attempt == 0, fm.fileExists(atPath: path) else {
                    log("memory: the search index cannot be opened (\(error))")
                    return nil
                }
                let aside = path + ".damaged-\(Int64(now().rounded(.down)))"
                try? fm.moveItem(atPath: path, toPath: aside)
                for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: path + suffix) }
                log("memory: the search index could not be read (\(error)); put aside, starting a new one")
            }
        }
        return nil
    }

    /// Every table, created when missing. `indexed`, `lines` and `line_words` are part 7c's;
    /// the `web_` ones are part 3's.
    static let schema = """
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        CREATE TABLE IF NOT EXISTS indexed (
            file TEXT PRIMARY KEY, offset INTEGER NOT NULL, count INTEGER NOT NULL,
            head BLOB NOT NULL, tail BLOB NOT NULL);
        CREATE TABLE IF NOT EXISTS lines (
            id INTEGER PRIMARY KEY, file TEXT NOT NULL, ord INTEGER NOT NULL,
            timestamp REAL NOT NULL, line BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS lines_by_file ON lines (file, ord);
        CREATE VIRTUAL TABLE IF NOT EXISTS line_words USING fts5 (
            words, tokenize = 'ascii', content = '', contentless_delete = 1);
        CREATE TABLE IF NOT EXISTS web_pages (
            id INTEGER PRIMARY KEY, url TEXT NOT NULL UNIQUE, requested TEXT NOT NULL, title TEXT NOT NULL,
            read_at REAL NOT NULL, source TEXT NOT NULL, query TEXT, text TEXT, bytes INTEGER NOT NULL,
            summary TEXT NOT NULL DEFAULT '', points TEXT NOT NULL DEFAULT '[]', summarized_by TEXT,
            vector BLOB, compacted INTEGER NOT NULL DEFAULT 0, packed BLOB);
        CREATE INDEX IF NOT EXISTS web_pages_by_read ON web_pages (read_at);
        CREATE INDEX IF NOT EXISTS web_pages_by_requested ON web_pages (requested);
        CREATE TABLE IF NOT EXISTS web_aliases (url TEXT PRIMARY KEY, page INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS web_passes (
            id INTEGER PRIMARY KEY, started REAL NOT NULL, ended REAL NOT NULL, opened INTEGER NOT NULL,
            stored INTEGER NOT NULL, stopped TEXT NOT NULL);
        CREATE VIRTUAL TABLE IF NOT EXISTS web_words USING fts5 (
            title, summary, points, body, tokenize = 'porter unicode61', content = '', contentless_delete = 1);
        """
}

/// W1 part 7c: archives that scale. `archive.jsonl`, `archive-python.jsonl` and `journal.jsonl`
/// in the search database, kept up to date by byte offset: each refresh reads only the bytes a
/// file gained since the last one, whole lines only. A file that shrank, or whose first or last
/// indexed bytes changed (a restore, a rewrite), is indexed again from the start.
///
/// Each entry is stored with its line, and the content words `MemoryRecall` ranks by
/// (`contentWords`), space-separated, in a contentless FTS5 table (only the index is kept) with
/// the `ascii` tokenizer. A content word
/// is letters and digits only, lowercased, so it is exactly one token there, and a phrase query
/// for each query word finds exactly the entries that share it. They are ranked as `MemoryRecall`
/// ranks a scan of the files, so search_memory's answers do not change, and only the lines shown
/// are read back.
public final class MemoryIndex: Sendable {
    /// The files indexed, with the rank `MemoryRecall` breaks ties by (the order
    /// `MemoryStore.searchedArchives` lists them in, then the journal on its own).
    static let files: [MemoryFile] = MemoryStore.searchedArchives + [.journal]
    /// At most this many bytes are read and committed at a time.
    public static let chunkBytes = 4 << 20
    /// How many bytes at each end of what was indexed are kept to notice a rewrite.
    static let fingerprintBytes = 256

    private let database: MemoryDatabase
    private let path: @Sendable (MemoryFile) -> String

    public init(database: MemoryDatabase, memory: MemoryStore) {
        self.database = database
        path = { memory.path($0) }
    }

    /// Indexes what each file gained since the last refresh. Returns the entries added, nil when
    /// the index cannot be used (no lease, or the database failed).
    @discardableResult
    public func refresh() -> Int? {
        var added = 0
        for file in Self.files {
            guard let n = refresh(file) else { return nil }
            added += n
        }
        return added
    }

    /// The archived messages sharing at least one of `words` (content words), ranked as
    /// `MemoryRecall` ranks a scan of the files: the most shared words first, then the newest,
    /// then the later in `MemoryStore.archivedMessages()`. The best `limit` (all when nil), and
    /// how many match in all; nil when the index cannot be used. Brought up to date first. Only
    /// the lines returned are read and parsed.
    public func messages(sharing words: Set<String>, limit: Int? = nil) -> (best: [ArchiveEntry], total: Int)? {
        guard !words.isEmpty else { return ([], 0) }
        guard refresh() != nil else { return nil }
        guard let found = best(sharing: words, in: MemoryStore.searchedArchives, limit: limit) else { return nil }
        return (found.lines.compactMap { ArchiveEntry(line: $0) }, found.total)
    }

    /// The journal's calls sharing at least one of `words`, ranked the same way (the journal is
    /// one file); nil when the index cannot be used.
    public func journal(sharing words: Set<String>, limit: Int? = nil) -> (best: [JournalEntry], total: Int)? {
        guard !words.isEmpty else { return ([], 0) }
        guard refresh() != nil else { return nil }
        guard let found = best(sharing: words, in: [.journal], limit: limit) else { return nil }
        return (found.lines.compactMap { JournalEntry(line: $0) }, found.total)
    }

    /// How many entries of `file` are indexed, and up to which byte (for tests and the log).
    public func indexed(_ file: MemoryFile) -> (count: Int, offset: Int)? {
        database.with { db -> (count: Int, offset: Int) in
            let s = try db.prepare("SELECT count, offset FROM indexed WHERE file = ?").bind(.text(file.rawValue))
            return try s.step() ? (Int(s.int(0)), Int(s.int(1))) : (0, 0)
        }
    }

    /// The words an entry is found by: `MemoryRecall`'s content words of the message, or of a
    /// call's tool, arguments and reply.
    static func words(of line: Data, in file: MemoryFile) -> (timestamp: Double, words: Set<String>)? {
        if file == .journal {
            guard let e = JournalEntry(line: line) else { return nil }
            return (e.timestamp, MemoryRecall.contentWords(e.tool + " " + e.args + " " + (e.reply ?? "")))
        }
        guard let e = ArchiveEntry(line: line) else { return nil }
        return (e.timestamp, MemoryRecall.contentWords(e.text))
    }

    /// One query word per phrase, OR-ed: `"leeds" OR "sister"`.
    static func matchExpression(_ words: Set<String>) -> String {
        words.sorted().map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " OR ")
    }

    // MARK: - Reading the index

    private struct Candidate {
        let id: Int64
        let shared: Int
        let timestamp: Double
        let rank: Int
        let order: Int
    }

    /// Ranks every entry of `files` that shares a word: one FTS5 query per word counts the shared
    /// words by rowid, one more reads each candidate's time and place; then only the best
    /// `limit` lines are read.
    private func best(sharing words: Set<String>, in files: [MemoryFile], limit: Int?) -> (lines: [Data], total: Int)? {
        database.with { db -> (lines: [Data], total: Int) in
            var shared: [Int64: Int] = [:]
            let one = try db.prepare("SELECT rowid FROM line_words WHERE line_words MATCH ?")
            for word in words {
                one.bind(.text(Self.matchExpression([word])))
                while try one.step() { shared[one.int(0), default: 0] += 1 }
            }
            guard !shared.isEmpty else { return ([], 0) }
            let marks = files.map { _ in "?" }.joined(separator: ", ")
            let s = try db.prepare("""
                SELECT l.id, l.timestamp, l.file, l.ord FROM line_words AS w JOIN lines AS l ON l.id = w.rowid
                WHERE line_words MATCH ? AND l.file IN (\(marks))
                """)
            let values: [SQLiteValue] = [.text(Self.matchExpression(words))] + files.map { .text($0.rawValue) }
            s.bind(values)
            let ranks = Dictionary(uniqueKeysWithValues: files.enumerated().map { ($1.rawValue, $0) })
            var candidates: [Candidate] = []
            while try s.step() {
                let id = s.int(0)
                guard let n = shared[id], n > 0 else { continue }
                candidates.append(Candidate(id: id, shared: n, timestamp: s.double(1), rank: ranks[s.text(2)] ?? 0,
                                            order: Int(s.int(3))))
            }
            candidates.sort { a, b in
                if a.shared != b.shared { return a.shared > b.shared }
                if a.timestamp != b.timestamp { return a.timestamp > b.timestamp }
                return (a.rank, a.order) > (b.rank, b.order)
            }
            let line = try db.prepare("SELECT line FROM lines WHERE id = ?")
            var lines: [Data] = []
            for c in candidates.prefix(limit ?? candidates.count) {
                line.bind(.int(c.id))
                if try line.step() { lines.append(line.blob(0)) }
            }
            return (lines, candidates.count)
        }
    }

    // MARK: - Indexing by byte offset

    private struct Mark {
        var offset: Int
        var count: Int
        var head: Data
        var tail: Data
    }

    /// Indexes `file` from its stored offset to its last whole line, a chunk per transaction.
    private func refresh(_ file: MemoryFile) -> Int? {
        var added = 0
        while true {
            guard let step = database.with({ db in try self.indexChunk(file, db) }) else { return nil }
            added += step.added
            if step.done { return added }
        }
    }

    /// One chunk: checks the file still holds what was indexed (else starts it over), then
    /// indexes up to `chunkBytes` of new whole lines.
    private func indexChunk(_ file: MemoryFile, _ db: SQLiteConnection) throws -> (added: Int, done: Bool) {
        let handle = FileHandle(forReadingAtPath: path(file))
        defer { try? handle?.close() }
        let size = Int((try? handle?.seekToEnd()) ?? 0)
        var mark = try self.mark(file, db) ?? Mark(offset: 0, count: 0, head: Data(), tail: Data())
        if mark.offset > 0 {
            let unchanged = size >= mark.offset
                && read(handle, at: 0, count: mark.head.count) == mark.head
                && read(handle, at: mark.offset - mark.tail.count, count: mark.tail.count) == mark.tail
            if !unchanged {
                try reset(file, db)
                mark = Mark(offset: 0, count: 0, head: Data(), tail: Data())
            }
        }
        guard size > mark.offset, let handle else { return (0, true) }
        var length = min(Self.chunkBytes, size - mark.offset)
        var data = read(handle, at: mark.offset, count: length) ?? Data()
        while data.lastIndex(of: 0x0A) == nil, mark.offset + length < size {   // one line longer than a chunk
            length = min(length * 2, size - mark.offset)
            data = read(handle, at: mark.offset, count: length) ?? Data()
        }
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return (0, true) }   // a torn line only
        let whole = data[data.startIndex...lastNewline]
        let added = try db.transaction { () throws -> Int in
            let insertLine = try db.prepare("INSERT INTO lines (file, ord, timestamp, line) VALUES (?, ?, ?, ?)")
            let insertWords = try db.prepare("INSERT INTO line_words (rowid, words) VALUES (?, ?)")
            var n = 0
            for line in whole.split(separator: 0x0A) {
                let bytes = Data(line)
                guard let found = Self.words(of: bytes, in: file) else { continue }
                try insertLine.bind(.text(file.rawValue), .int(Int64(mark.count + n)), .double(found.timestamp),
                                    .blob(bytes)).run()
                try insertWords.bind(.int(db.lastInsertRowID), .text(found.words.sorted().joined(separator: " "))).run()
                n += 1
            }
            let offset = mark.offset + whole.count
            let head = read(handle, at: 0, count: min(Self.fingerprintBytes, offset)) ?? Data()
            let tailCount = min(Self.fingerprintBytes, offset)
            let tail = read(handle, at: offset - tailCount, count: tailCount) ?? Data()
            try db.prepare("""
                INSERT INTO indexed (file, offset, count, head, tail) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (file) DO UPDATE SET offset = excluded.offset, count = excluded.count,
                head = excluded.head, tail = excluded.tail
                """).bind(.text(file.rawValue), .int(Int64(offset)), .int(Int64(mark.count + n)), .blob(head),
                          .blob(tail)).run()
            return n
        }
        return (added, mark.offset + whole.count >= size)
    }

    private func mark(_ file: MemoryFile, _ db: SQLiteConnection) throws -> Mark? {
        let s = try db.prepare("SELECT offset, count, head, tail FROM indexed WHERE file = ?").bind(.text(file.rawValue))
        guard try s.step() else { return nil }
        return Mark(offset: Int(s.int(0)), count: Int(s.int(1)), head: s.blob(2), tail: s.blob(3))
    }

    private func reset(_ file: MemoryFile, _ db: SQLiteConnection) throws {
        try db.transaction {
            try db.prepare("DELETE FROM line_words WHERE rowid IN (SELECT id FROM lines WHERE file = ?)")
                .bind(.text(file.rawValue)).run()
            try db.prepare("DELETE FROM lines WHERE file = ?").bind(.text(file.rawValue)).run()
            try db.prepare("DELETE FROM indexed WHERE file = ?").bind(.text(file.rawValue)).run()
        }
    }

    private func read(_ handle: FileHandle?, at offset: Int, count: Int) -> Data? {
        guard let handle else { return count == 0 ? Data() : nil }
        guard count > 0 else { return Data() }
        guard offset >= 0, (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
        return (try? handle.read(upToCount: count)) ?? Data()
    }
}
