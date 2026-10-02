import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// W1 part 7c: the conversations and the task journal in the FTS5 index (memory/web/index.sqlite),
/// kept up to date by byte offset. Search through it finds what a scan of the files finds, in the
/// same order; it reads only new bytes; a rewritten file is indexed again; without the lease it
/// is not used; a damaged database is put aside. Sandboxed roots and invented text only.
@Suite("W1 memory index", .timeLimit(.minutes(2)))
struct MemoryIndexTests {
    static let utc = TimeZone(identifier: "UTC")!

    struct Rig {
        let sandbox: Sandbox
        let clock = ManualClock(1_790_000_000)
        let memory: MemoryStore
        let logs = LogRecorder()
        let database: MemoryDatabase
        let index: MemoryIndex

        init(lease: HandLease? = nil) throws {
            sandbox = try Sandbox()
            let store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: lease, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: MemoryIndexTests.utc)
            let clock = clock
            database = MemoryDatabase(memory: memory, now: { clock.now() }, log: logs.function)
            index = MemoryIndex(database: database, memory: memory)
        }

        var scan: MemoryRecall { MemoryRecall(memory: memory, vectors: FactVectors(embedding: nil)) }
        var indexed: MemoryRecall { MemoryRecall(memory: memory, vectors: FactVectors(embedding: nil), index: index) }
        func path(_ f: MemoryFile) -> String { memory.path(f) }
        func size(_ f: MemoryFile) -> Int { FileManager.default.contents(atPath: path(f))?.count ?? 0 }
    }

    /// A deterministic corpus: words in mixed case, with endings, accents, other scripts and
    /// digits; many messages share a timestamp, so ties are broken by order.
    static let vocabulary = ["Leeds", "moving", "moved", "cat", "cats", "café", "Café", "Zoë", "naïve", "東京",
                             "straße", "1990s", "garden", "gardening", "plan", "plans", "Amira", "tea", "e\u{301}te",
                             "the", "and", "sir", "JARVIS", "co-op", "x", "ab", "studies", "study", "piano"]

    static func corpus(_ rig: Rig) {
        var seed: UInt64 = 0x5EED
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        func sentence() -> String {
            (0..<(1 + next(6))).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: next(3) == 0 ? ", " : " ")
        }
        for k in 0..<240 {
            rig.clock.set(1_790_000_000 + Double(k / 3))            // three messages a second
            #expect(rig.memory.archive(sentence(), role: k % 2 == 0 ? .user : .jarvis, channel: "text"))
        }
        let python = (0..<60).map { k in
            ArchiveEntry(timestamp: 1_781_082_900 + Double(k / 4), date: "2026-06-10", channel: "voice (Python)",
                         role: k % 2 == 0 ? .user : .jarvis, text: sentence())
        }
        #expect(rig.memory.writePythonArchive(python))
        for k in 0..<80 {
            rig.clock.set(1_790_100_000 + Double(k / 2))
            let args = JSONObject([.init(key: "path", value: .string("~/Invented/" + sentence()))])
            #expect(rig.memory.journal(tool: ["run_command", "read_file", "get_time"][k % 3], outcome: .ran, args: args,
                                       reply: k % 3 == 1 ? nil : sentence()))
        }
    }

    static let queries = ["Leeds", "moving to Leeds", "cats", "café", "CAFÉ", "Zoë naïve", "東京", "straße garden",
                          "1990s", "plans gardening", "Amira tea cat", "e\u{301}te", "the and sir", "co-op", "piano study",
                          "run_command", "Invented", "read file", "nothing matches this", "", "x ab", "studies"]

    @Test func theIndexFindsWhatTheFilesFindInTheSameOrder() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        Self.corpus(rig)
        let scan = rig.scan, indexed = rig.indexed
        for query in Self.queries {
            #expect(indexed.searchConversations(query) == scan.searchConversations(query), "conversations: \(query)")
            #expect(indexed.searchJournal(query) == scan.searchJournal(query), "journal: \(query)")
            let best = indexed.searchConversations(query, limit: 3), scanned = scan.searchConversations(query, limit: 3)
            #expect(best.best == scanned.best && best.total == scanned.total, "best 3: \(query)")
            let calls = indexed.searchJournal(query, limit: 3), read = scan.searchJournal(query, limit: 3)
            #expect(calls.best == read.best && calls.total == read.total, "best 3 calls: \(query)")
        }
        #expect(!scan.searchConversations("Leeds").isEmpty && !scan.searchJournal("Invented").isEmpty)
        #expect(rig.index.indexed(.archive)?.count == 240 && rig.index.indexed(.pythonArchive)?.count == 60
                && rig.index.indexed(.journal)?.count == 80)
        let mode = try FileManager.default.attributesOfItem(atPath: rig.database.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    /// Each refresh reads from where the last one stopped: only the new whole lines are indexed,
    /// and a torn last line waits until it is whole.
    @Test func eachRefreshIndexesOnlyTheNewLines() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        for k in 0..<3 { #expect(rig.memory.archive("Invented message \(k) about Leeds.", role: .user, channel: "text")) }
        #expect(rig.index.refresh() == 3)
        #expect(rig.index.indexed(.archive)?.offset == rig.size(.archive))
        #expect(rig.index.refresh() == 0)
        #expect(rig.memory.archive("A fourth about Leeds.", role: .user, channel: "text"))
        #expect(rig.memory.journal(tool: "get_time", outcome: .ran, args: JSONObject(), reply: "It is noon in Leeds."))
        #expect(rig.index.refresh() == 2)

        let line = ArchiveEntry(timestamp: 1_790_000_100, date: "2026-09-21", channel: "text", role: .user,
                                text: "A torn line about Leeds.").line + "\n"
        let handle = try #require(FileHandle(forWritingAtPath: rig.path(.archive)))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8.prefix(20)))
        #expect(rig.index.refresh() == 0)                                  // half a line: not yet
        try handle.write(contentsOf: Data(line.utf8.dropFirst(20)))
        try handle.close()
        #expect(rig.index.refresh() == 1)
        #expect(rig.indexed.searchConversations("Leeds").count == 5)
        #expect(rig.indexed.searchConversations("Leeds") == rig.scan.searchConversations("Leeds"))
    }

    /// A file that shrank, or whose indexed bytes changed (a restore, a rewrite), is indexed again
    /// from the start, and what it no longer holds is no longer found.
    @Test func aRewrittenFileIsIndexedAgain() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        for k in 0..<4 { #expect(rig.memory.archive("Invented message \(k) about Leeds.", role: .user, channel: "text")) }
        #expect(rig.indexed.searchConversations("Leeds").count == 4)
        let two = (0..<2).map {
            ArchiveEntry(timestamp: 1_790_000_000, date: "2026-09-21", channel: "text", role: .user,
                         text: "Rewritten \($0) about York.").line + "\n"
        }.joined()
        try Data(two.utf8).write(to: URL(fileURLWithPath: rig.path(.archive)))
        #expect(rig.indexed.searchConversations("Leeds").isEmpty)
        #expect(rig.indexed.searchConversations("York").map(\.text) == ["Rewritten 1 about York.", "Rewritten 0 about York."])
        #expect(rig.index.indexed(.archive)?.count == 2)

        // The same size, other bytes at the start: indexed again too.
        let same = two.replacingOccurrences(of: "Rewritten 0", with: "Different 0")
        #expect(same.utf8.count == two.utf8.count)
        try Data(same.utf8).write(to: URL(fileURLWithPath: rig.path(.archive)))
        #expect(rig.indexed.searchConversations("York").map(\.text) == ["Rewritten 1 about York.", "Different 0 about York."])
    }

    /// Without the lease nothing is written, not even the database: the search reads the files.
    @Test func withoutTheLeaseTheIndexIsNotUsed() throws {
        let lease = HandLease(true)
        let rig = try Rig(lease: lease)
        defer { rig.sandbox.remove() }
        for k in 0..<3 { #expect(rig.memory.archive("Invented message \(k) about Leeds.", role: .user, channel: "text")) }
        lease.set(false)
        #expect(rig.index.refresh() == nil)
        #expect(rig.index.messages(sharing: ["leed"]) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.database.path))
        #expect(rig.indexed.searchConversations("Leeds").count == 3)        // from the files
    }

    /// A database that cannot be read is put aside and a new one built from the files.
    @Test func aDamagedDatabaseIsPutAsideAndRebuilt() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        for k in 0..<3 { #expect(rig.memory.archive("Invented message \(k) about Leeds.", role: .user, channel: "text")) }
        try FileManager.default.createDirectory(atPath: rig.database.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 4096).write(to: URL(fileURLWithPath: rig.database.path))
        #expect(rig.indexed.searchConversations("Leeds").count == 3)
        #expect(rig.index.indexed(.archive)?.count == 3)
        let aside = rig.database.path + ".damaged-1790000000"
        #expect(FileManager.default.contents(atPath: aside) == Data(repeating: 0x42, count: 4096))
        #expect(rig.logs.lines.contains { $0.hasPrefix("memory: the search index could not be read (") })
    }

    @Test func theMatchExpressionQuotesEachWord() {
        #expect(MemoryIndex.matchExpression(["leed", "cat"]) == #""cat" OR "leed""#)
        #expect(MemoryIndex.matchExpression(["a\"b"]) == #""a""b""#)
    }

    /// The timing the brief asks for: a 50,000-message archive searched by reading the files and
    /// through the index, as search_memory asks (the best 10 and the total). Words are drawn
    /// from 3,000 with a skew, so some are in most messages and some in a few. Gated: runs only
    /// with JARVIS_PERF=1, and prints its numbers.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_PERF"] == "1"))
    func timeAFiftyThousandMessageArchive() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        var seed: UInt64 = 42
        func uniform() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var lines = ""
        for k in 0..<50_000 {
            let words = (0..<12).map { _ in "term\(Int(pow(uniform(), 3) * 3_000))" }
            let text = "Message \(k): " + words.joined(separator: " ") + ", and so on, sir."
            lines += ArchiveEntry(timestamp: 1_760_000_000 + Double(k * 60), date: "2026-01-01", channel: "text",
                                  role: k % 2 == 0 ? .user : .jarvis, text: text).line + "\n"
        }
        try FileManager.default.createDirectory(atPath: (rig.path(.archive) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(lines.utf8).write(to: URL(fileURLWithPath: rig.path(.archive)))
        let clock = ContinuousClock()
        let build = clock.measure { _ = rig.index.refresh() }
        let scan = rig.scan, indexed = rig.indexed
        var report: [String] = []
        for query in ["term1 term2", "term40", "term900", "term2990", "nothing like this"] {
            var before: (best: [ArchiveEntry], total: Int) = ([], 0)
            var after: (best: [ArchiveEntry], total: Int) = ([], 0)
            let files = clock.measure { before = scan.searchConversations(query, limit: 10) }
            let index = clock.measure { after = indexed.searchConversations(query, limit: 10) }
            #expect(after.best == before.best && after.total == before.total, "\(query)")
            report.append("\"\(query)\" \(before.total) hits: files \(files), index \(index)")
        }
        let mb = Double(rig.size(.archive)) / 1_048_576
        let db = ["", "-wal"].map { (try? FileManager.default.attributesOfItem(atPath: rig.database.path + $0)[.size] as? NSNumber)?
            .doubleValue ?? 0 }.reduce(0, +) / 1_048_576
        print("W1-7c timing: 50000 messages, \(String(format: "%.1f", mb)) MB archive, index \(String(format: "%.1f", db)) MB with its WAL, "
              + "first build \(build); " + report.joined(separator: "; "))
    }
}
