import Foundation
import JarvisCore
import Synchronization

/// W1 part 3: every page JARVIS reads, kept and indexed, in the search database
/// (memory/web/index.sqlite). One row a page, under its canonical URL: the URL asked for, the
/// title, when it was read, why (a background pass or a user's search, with the query or topic),
/// the full text, an on-device summary with up to five key points (pending until
/// `summarizePending` writes them), and a sentence vector of the title and summary (NLEmbedding,
/// as P2's facts). Title, summary, points and text are indexed in a contentless FTS5 table
/// (porter stemming) for `search`. Nothing here ever reaches facts.json or the archive: what
/// JARVIS reads is never a fact about the user. Logs carry counts and hosts, never text.
public final class WebMemory: Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case background
        case search
    }

    /// A page waiting for its summary.
    public struct Pending: Sendable, Equatable {
        public let id: Int64
        public let title: String
        public let text: String
    }

    /// A stored page, as tests and the budget read it.
    public struct Stored: Sendable, Equatable {
        public let id: Int64
        public let url: String
        public let requested: String
        public let title: String
        public let readAt: Double
        public let source: String
        public let query: String?
        public let text: String?
        public let summary: String
        public let points: [String]
        public let summarizedBy: String?
        public let compacted: Bool
    }

    /// Key points kept per page, and the length of each.
    public static let pointLimit = 5
    public static let pointLength = 200
    public static let summaryLength = 600
    /// A search's candidates, before ranking.
    static let candidateLimit = 200

    private let database: MemoryDatabase
    private let embedding: (any SentenceEmbedding)?
    private let clock: any JarvisClock
    private let timeZone: TimeZone
    private let afterWrite: @Sendable () -> Void
    private let log: @Sendable (String) -> Void

    /// - Parameter afterWrite: called after each write to the store (part 6: the memory budget).
    public init(database: MemoryDatabase, embedding: (any SentenceEmbedding)?, clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .current, afterWrite: @escaping @Sendable () -> Void = {},
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.database = database
        self.embedding = embedding
        self.clock = clock
        self.timeZone = timeZone
        self.afterWrite = afterWrite
        self.log = log
    }

    // MARK: - Writing

    /// Whether a page is stored under this canonical URL (the background pass skips it).
    public func has(_ canonicalURL: String) -> Bool {
        database.with { db -> Bool in
            let s = try db.prepare("SELECT 1 FROM web_pages WHERE url = ?").bind(.text(canonicalURL))
            return try s.step()
        } ?? false
    }

    /// Stores `page` under its canonical URL, read now, its summary pending. A page already
    /// stored there is replaced (read again), and its old summary kept only when the text is the
    /// same. Returns the row's id, nil when the store cannot be written.
    @discardableResult
    public func store(_ page: ReadPage, source: Source, query: String? = nil) -> Int64? {
        let now = clock.now()
        let id = database.with { db -> Int64 in
            try db.transaction { () throws -> Int64 in
                let old = try db.prepare("SELECT id, text FROM web_pages WHERE url = ?").bind(.text(page.canonicalURL))
                var keepSummary = false
                var id: Int64?
                if try old.step() {
                    id = old.int(0)
                    keepSummary = !old.isNull(1) && old.text(1) == page.text
                }
                if let id {
                    try db.prepare("""
                        UPDATE web_pages SET requested = ?, title = ?, read_at = ?, source = ?, query = ?, text = ?,
                        bytes = ?, compacted = 0, packed = NULL\(keepSummary ? "" : ", summary = '', points = '[]', summarized_by = NULL, vector = NULL")
                        WHERE id = ?
                        """).bind(.text(page.requested), .text(page.title), .double(now), .text(source.rawValue),
                                  query.map(SQLiteValue.text) ?? .null, .text(page.text), .int(Int64(page.text.utf8.count)),
                                  .int(id)).run()
                } else {
                    try db.prepare("""
                        INSERT INTO web_pages (url, requested, title, read_at, source, query, text, bytes)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """).bind(.text(page.canonicalURL), .text(page.requested), .text(page.title), .double(now),
                                  .text(source.rawValue), query.map(SQLiteValue.text) ?? .null, .text(page.text),
                                  .int(Int64(page.text.utf8.count))).run()
                    id = db.lastInsertRowID
                }
                let rowID = id!
                try Self.reindex(rowID, db)
                return rowID
            }
        }
        if id != nil { afterWrite() }
        return id
    }

    /// Up to `limit` pages still waiting for a summary, oldest first (only pages that still
    /// hold their text).
    public func pending(limit: Int) -> [Pending] {
        database.with { db -> [Pending] in
            let s = try db.prepare("""
                SELECT id, title, text FROM web_pages WHERE summarized_by IS NULL AND text IS NOT NULL
                ORDER BY read_at, id LIMIT ?
                """).bind(.int(Int64(limit)))
            var out: [Pending] = []
            while try s.step() { out.append(Pending(id: s.int(0), title: s.text(1), text: s.text(2))) }
            return out
        } ?? []
    }

    /// Writes a page's summary and key points (at most five, each cut), redacted, with its
    /// vector; false when the page is gone or the store cannot be written.
    @discardableResult
    public func setSummary(_ id: Int64, _ summary: PageSummary) -> Bool {
        let text = Py.prefix(Redactor.redact(Py.strip(summary.summary)).text, Self.summaryLength)
        let points = summary.points.prefix(Self.pointLimit).map {
            Py.prefix(Redactor.redact(Py.strip($0)).text, Self.pointLength)
        }.filter { !$0.isEmpty }
        let pointsJSON = PyJSON.dumps(.array(points.map(JSONValue.string)), ensureASCII: false)
        let done = database.with { db -> Bool in
            let title = try db.prepare("SELECT title FROM web_pages WHERE id = ?").bind(.int(id))
            guard try title.step() else { return false }
            let vector = embedding?.vector(for: title.text(0) + ". " + text).map(Self.blob)
            try db.transaction {
                try db.prepare("UPDATE web_pages SET summary = ?, points = ?, summarized_by = ?, vector = ? WHERE id = ?")
                    .bind(.text(text), .text(pointsJSON), .text(summary.by), vector.map(SQLiteValue.blob) ?? .null, .int(id))
                    .run()
                try Self.reindex(id, db)
            }
            return true
        } ?? false
        if done { afterWrite() }
        return done
    }

    /// Summarises up to `limit` pending pages, oldest first, calling `beforeEach` before each
    /// (the caller waits there while the user is busy; a throw stops the run). Returns how many
    /// were summarised. A page the summariser fails on is left pending.
    public func summarizePending(limit: Int, with summarizer: any PageSummarizing,
                                 beforeEach: @Sendable () async throws -> Void = {}) async -> Int {
        var done = 0
        for page in pending(limit: limit) {
            do {
                try await beforeEach()
                let summary = try await summarizer.summarize(title: page.title, text: page.text)
                if setSummary(page.id, summary) { done += 1 }
            } catch is CancellationError {
                break
            } catch {
                log("web memory: a page was not summarised (\(String(describing: type(of: error))))")
            }
        }
        return done
    }

    // MARK: - Reading

    /// The pages that match `query` (its words of three letters or more, less common function
    /// words), best first: FTS5's bm25 over title, summary, key points and text, plus the
    /// cosine of the query's vector and the page's where both exist; then the newest. When no
    /// word matches, the pages closest in meaning (cosine at least `meaningThreshold`). The best
    /// `limit`, and how many match in all.
    public func search(_ query: String, limit: Int) -> (best: [WebMemoryHit], total: Int) {
        let words = Self.queryWords(query)
        guard !words.isEmpty else { return ([], 0) }
        let queryVector = embedding?.vector(for: query)
        return database.with { db -> (best: [WebMemoryHit], total: Int) in
            var scored: [(id: Int64, score: Double, readAt: Double)] = []
            let s = try db.prepare("""
                SELECT w.rowid, bm25(web_words, 4.0, 2.0, 2.0, 1.0), p.read_at, p.vector
                FROM web_words AS w JOIN web_pages AS p ON p.id = w.rowid
                WHERE web_words MATCH ? ORDER BY 2 LIMIT \(Self.candidateLimit)
                """).bind(.text(MemoryIndex.matchExpression(words)))
            var best = 0.0
            var rows: [(Int64, Double, Double, Data)] = []
            while try s.step() {
                rows.append((s.int(0), s.double(1), s.double(2), s.blob(3)))
                best = min(best, s.double(1))
            }
            for (id, rank, readAt, vector) in rows {
                let keyword = best < 0 && rank < 0 ? rank / best : 1
                let meaning = queryVector.flatMap { q in Self.vector(vector).flatMap { FactVectors.cosine(q, $0) } } ?? 0
                scored.append((id, keyword + max(0, meaning), readAt))
            }
            if scored.isEmpty, let q = queryVector {
                let all = try db.prepare("SELECT id, read_at, vector FROM web_pages WHERE vector IS NOT NULL")
                while try all.step() {
                    if let v = Self.vector(all.blob(2)), let c = FactVectors.cosine(q, v), c >= Self.meaningThreshold {
                        scored.append((all.int(0), c, all.double(1)))
                    }
                }
            }
            scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.readAt > $1.readAt }
            var hits: [WebMemoryHit] = []
            let one = try db.prepare("""
                SELECT url, title, read_at, summary, points, source, substr(coalesce(text, ''), 1, 400), compacted, packed
                FROM web_pages WHERE id = ?
                """)
            for row in scored.prefix(limit) {
                one.bind(.int(row.id))
                guard try one.step() else { continue }
                var title = one.text(1), summary = one.text(3).isEmpty ? Py.strip(one.text(6)) : one.text(3)
                var points = (try? PyJSON.loads(one.blob(4)))?.arrayValue?.compactMap(\.stringValue) ?? []
                if one.int(7) != 0, let kept = Self.unpack(one.blob(8)) { (title, summary, points) = kept }
                hits.append(WebMemoryHit(url: one.text(0), title: title, readAt: one.double(2),
                                         date: Self.date(one.double(2), timeZone: timeZone), summary: summary,
                                         points: points, source: one.text(5)))
            }
            return (hits, scored.count)
        } ?? ([], 0)
    }

    /// Below this cosine a page is not a match by meaning alone.
    public static let meaningThreshold = 0.6

    /// The stored page under a canonical URL (tests, the budget's log).
    public func page(_ canonicalURL: String) -> Stored? {
        database.with { db -> Stored? in
            let s = try db.prepare("""
                SELECT id, url, requested, title, read_at, source, query, text, summary, points, summarized_by, compacted,
                packed FROM web_pages WHERE url = ?
                """).bind(.text(canonicalURL))
            guard try s.step() else { return nil }
            var title = s.text(3), summary = s.text(8)
            var points = (try? PyJSON.loads(s.blob(9)))?.arrayValue?.compactMap(\.stringValue) ?? []
            if s.int(11) != 0, let kept = Self.unpack(s.blob(12)) { (title, summary, points) = kept }
            return Stored(id: s.int(0), url: s.text(1), requested: s.text(2), title: title, readAt: s.double(4),
                          source: s.text(5), query: s.isNull(6) ? nil : s.text(6), text: s.isNull(7) ? nil : s.text(7),
                          summary: summary, points: points, summarizedBy: s.isNull(10) ? nil : s.text(10),
                          compacted: s.int(11) != 0)
        } ?? nil
    }

    /// Whether the store can be used now (the lease is held and the database opens).
    public var isAvailable: Bool { database.with { _ in true } ?? false }

    /// Whether a page was read from this URL, as asked for or as its canonical URL (W1 part 5:
    /// the background pass does not open a feed item it has read).
    public func hasRead(_ url: String) -> Bool {
        database.with { db -> Bool in
            let s = try db.prepare("""
                SELECT 1 FROM web_pages WHERE url = ?1 OR requested = ?1
                UNION ALL SELECT 1 FROM web_aliases WHERE url = ?1 LIMIT 1
                """).bind(.text(url))
            return try s.step()
        } ?? false
    }

    /// Notes that `url` led to the page already kept under `canonicalURL`, so it is not opened
    /// again (W1 part 5). False when there is no such page.
    @discardableResult
    public func alias(_ url: String, to canonicalURL: String) -> Bool {
        database.with { db -> Bool in
            try db.prepare("INSERT OR IGNORE INTO web_aliases (url, page) SELECT ?, id FROM web_pages WHERE url = ?")
                .bind(.text(url), .text(canonicalURL)).run()
            return db.changes > 0
        } ?? false
    }

    /// W1 part 5: notes one background pass.
    public func recordPass(started: Double, ended: Double, opened: Int, stored: Int, stopped: String) {
        _ = database.with { db in
            try db.prepare("INSERT INTO web_passes (started, ended, opened, stored, stopped) VALUES (?, ?, ?, ?, ?)")
                .bind(.double(started), .double(ended), .int(Int64(opened)), .int(Int64(stored)), .text(stopped)).run()
        }
    }

    /// When the last background pass began, nil before the first.
    public func lastPassStarted() -> Double? {
        database.with { db -> Double? in
            let s = try db.prepare("SELECT max(started) FROM web_passes")
            return try s.step() && !s.isNull(0) ? s.double(0) : nil
        } ?? nil
    }

    /// How many pages are stored.
    public var count: Int {
        database.with { db -> Int in
            let s = try db.prepare("SELECT count(*) FROM web_pages")
            return try s.step() ? Int(s.int(0)) : 0
        } ?? 0
    }

    // MARK: - Compaction (W1 part 6)

    /// Compacts the oldest pages that still hold their text, at most `limit`, and only as many as
    /// it takes for their text to reach `textBytes` when given (always at least one): the text is
    /// dropped, and the title, summary and key points are kept compressed (zlib) beside the URL,
    /// still found by a search. A page with no summary yet gets its first sentences as one.
    /// Returns the pages compacted and the bytes of text dropped. Writes no budget check of its own.
    public func compactOldest(_ limit: Int, upTo textBytes: Int? = nil) -> (pages: Int, textBytes: Int) {
        database.with { db -> (pages: Int, textBytes: Int) in
            let oldest = try db.prepare("""
                SELECT id, title, summary, points, text, summarized_by FROM web_pages
                WHERE compacted = 0 AND text IS NOT NULL ORDER BY read_at, id LIMIT ?
                """).bind(.int(Int64(limit)))
            var rows: [(Int64, String, String, [String], String, Bool)] = []
            var total = 0
            while try oldest.step() {
                let points = (try? PyJSON.loads(oldest.blob(3)))?.arrayValue?.compactMap(\.stringValue) ?? []
                rows.append((oldest.int(0), oldest.text(1), oldest.text(2), points, oldest.text(4), oldest.isNull(5)))
                total += oldest.text(4).utf8.count
                if let textBytes, total >= textBytes { break }
            }
            var dropped = 0
            try db.transaction {
                for (id, title, summary, points, text, pending) in rows {
                    let kept = pending || summary.isEmpty ? LeadSummarizer.lead(text) : summary
                    let packed = Self.pack(title: title, summary: kept, points: points)
                    try db.prepare("DELETE FROM web_words WHERE rowid = ?").bind(.int(id)).run()
                    try db.prepare("INSERT INTO web_words (rowid, title, summary, points, body) VALUES (?, ?, ?, ?, '')")
                        .bind(.int(id), .text(title), .text(kept), .text(points.joined(separator: " "))).run()
                    try db.prepare("""
                        UPDATE web_pages SET text = NULL, title = '', summary = '', points = '[]', packed = ?, compacted = 1,
                        bytes = 0, summarized_by = coalesce(summarized_by, 'lead') WHERE id = ?
                        """).bind(.blob(packed), .int(id)).run()
                    dropped += text.utf8.count
                }
            }
            return (rows.count, dropped)
        } ?? (0, 0)
    }

    /// Gives the database's free pages back to the disk: the FTS index merged (dropping what the
    /// compacted texts left in it), then the incremental vacuum and the WAL cut back.
    public func reclaim() {
        _ = database.with { db in
            try db.exec("""
                INSERT INTO web_words (web_words) VALUES ('optimize');
                PRAGMA incremental_vacuum;
                PRAGMA wal_checkpoint(TRUNCATE);
                """)
        }
    }

    /// Pages still holding their text, and that text's size.
    public func uncompacted() -> (pages: Int, textBytes: Int) {
        database.with { db -> (pages: Int, textBytes: Int) in
            let s = try db.prepare("SELECT count(*), coalesce(sum(bytes), 0) FROM web_pages WHERE compacted = 0 AND text IS NOT NULL")
            return try s.step() ? (Int(s.int(0)), Int(s.int(1))) : (0, 0)
        } ?? (0, 0)
    }

    static func pack(title: String, summary: String, points: [String]) -> Data {
        let json = PyJSON.dumps(.object(JSONObject([
            .init(key: "title", value: .string(title)), .init(key: "summary", value: .string(summary)),
            .init(key: "points", value: .array(points.map(JSONValue.string))),
        ])), ensureASCII: false)
        let raw = Data(json.utf8)
        return (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw
    }

    static func unpack(_ data: Data) -> (title: String, summary: String, points: [String])? {
        let raw = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
        guard case .object(let o)? = try? PyJSON.loads(raw) else { return nil }
        return (o["title"]?.stringValue ?? "", o["summary"]?.stringValue ?? "",
                o["points"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    // MARK: - Helpers

    /// The words a web search looks for: lower-cased runs of letters and digits, three or more
    /// long, less `MemoryRecall`'s function words. Stemming is FTS5's (porter).
    static func queryWords(_ query: String) -> Set<String> {
        Set(Py.lower(query).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            .filter { $0.count >= 3 && !MemoryRecall.stopWords.contains($0) })
    }

    /// Rewrites a page's row in the FTS index from the stored columns.
    static func reindex(_ id: Int64, _ db: SQLiteConnection) throws {
        try db.prepare("DELETE FROM web_words WHERE rowid = ?").bind(.int(id)).run()
        try db.prepare("""
            INSERT INTO web_words (rowid, title, summary, points, body)
            SELECT id, title, summary, points, coalesce(text, '') FROM web_pages WHERE id = ?
            """).bind(.int(id)).run()
    }

    static func date(_ t: Double, timeZone: TimeZone) -> String {
        PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: t), timeZone: timeZone)
    }

    /// A vector as little-endian Float32s.
    static func blob(_ v: [Double]) -> Data {
        var data = Data(capacity: v.count * 4)
        for x in v { withUnsafeBytes(of: Float32(x).bitPattern.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func vector(_ data: Data) -> [Double]? {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        return stride(from: 0, to: data.count, by: 4).map { i in
            let bits = data[data.startIndex + i..<data.startIndex + i + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            return Double(Float32(bitPattern: UInt32(littleEndian: bits)))
        }
    }
}

/// A page's summary and key points, and who wrote them ("local": the on-device model; "lead":
/// the page's own first sentences, when the model cannot).
public struct PageSummary: Sendable, Equatable {
    public let summary: String
    public let points: [String]
    public let by: String

    public init(summary: String, points: [String], by: String) {
        self.summary = summary
        self.points = points
        self.by = by
    }
}

/// What summarises a page for the web memory.
public protocol PageSummarizing: Sendable {
    func summarize(title: String, text: String) async throws -> PageSummary
}
