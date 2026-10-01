import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// P6 part 4 (DEV-P6-05, proposed): the one-time import, on the synthetic Python-era state in a
/// temp folder (`PythonEraFixture`: two Python sessions, one native session, paired and junk
/// lines, and the three state files). The writers are scripted; the batches go through P2's
/// real compile, validator and merge. Every name is invented.
@Suite("P6 Python-era import", .timeLimit(.minutes(1)))
struct PythonImportTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let now: Double = 1_790_582_400                          // 2026-09-28 08:00 UTC

    struct Boom: Error {}

    /// Answers from what the transcript holds and records each one; a transcript holding one of
    /// `failing` throws.
    final class Writer: AttributedWriting, PersonaLLM {
        private let state = Mutex<(calls: [String], failing: Set<String>)>(([], []))
        let author: AttributedText.Author
        init(_ author: AttributedText.Author) { self.author = author }
        var calls: [String] { state.withLock { $0.calls } }
        func fail(on marks: Set<String>) { state.withLock { $0.failing = marks } }

        func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
            AttributedText(text: try await complete(system: system, user: user, timeout: timeout), author: author)
        }

        func complete(system: String, user: String, timeout: Duration) async throws -> String {
            let failing = state.withLock { s -> Set<String> in
                s.calls.append(user)
                return s.failing
            }
            if failing.contains(where: { user.contains($0) }) { throw Boom() }
            #expect(system == FactExtraction.system)
            var lines: [String] = []
            if user.contains("cello") { lines.append("The user is learning the cello.") }
            if user.contains("night shifts") {
                lines += ["The user works night shifts at the Fernwick Infirmary.", "Wren is a cousin."]
            }
            if user.contains("tea without sugar") { lines.append("The user takes tea without sugar.") }
            if user.contains("marathon") { lines.append("The user is training for a marathon in October.") }
            if user.contains("bakery") { lines.append("The user wants to know when the Fernwick bakery opens.") }
            if user.contains("misheard") { lines.append("The user's town is spelled Fernwick.") }
            return lines.isEmpty ? "NONE" : lines.joined(separator: "\n")
        }
    }

    final class IDs: Sendable {
        private let n = Mutex(0)
        func next() -> String { n.withLock { $0 += 1; return "fact-\($0)" } }
    }

    struct Rig {
        let sb: Sandbox
        let clock = ManualClock(PythonImportTests.now)
        let store: StateStore
        let memory: MemoryStore
        let onDevice = Writer(.local)
        let claude = Writer(.claude)
        let logs = LogRecorder()
        let ids = IDs()

        init(withFiles: Bool = true) throws {
            sb = try Sandbox()
            if withFiles {
                try sb.write("logs/jarvis.log", PythonEraFixture.log)
                try sb.write("history.json", PythonEraFixture.history)
                try sb.write("knowledge.json", PythonEraFixture.knowledge)
                try sb.write("corrections.json", PythonEraFixture.corrections)
                let fm = FileManager.default
                try fm.setAttributes([.modificationDate: PythonEraFixture.historyModified],
                                     ofItemAtPath: sb.root.appending(path: "history.json").path(percentEncoded: false))
                try fm.setAttributes([.modificationDate: PythonEraFixture.knowledgeModified],
                                     ofItemAtPath: sb.root.appending(path: "knowledge.json").path(percentEncoded: false))
                try fm.setAttributes([.modificationDate: PythonEraFixture.knowledgeModified],
                                     ofItemAtPath: sb.root.appending(path: "corrections.json").path(percentEncoded: false))
            }
            store = try StateStore(root: sb.root.path(percentEncoded: false), lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: PythonImportTests.utc, log: { _ in })
        }

        /// `fits` decides the route; the Claude route is `ClaudeAlone` over the scripted writer.
        func importer(fits: @escaping @Sendable (String) async -> Bool = { _ in true }) -> PythonImport {
            let ids = ids
            let compiler = FactCompiler(memory: memory, writer: onDevice, vectors: FactVectors(embedding: nil),
                                        clock: clock, makeID: { ids.next() }, log: { _ in })
            return PythonImport(store: store, memory: memory, compiler: compiler,
                                claudeAlone: ClaudeAlone(claude: claude), fits: fits, clock: clock,
                                timeZone: PythonImportTests.utc, log: logs.function)
        }

        var facts: [MemoryFact] { memory.loadFacts()?.facts ?? [] }
        var progress: JSONObject? {
            store.read(.pythonImport).flatMap { try? PyJSON.loads($0) }?.objectValue
        }
    }

    @Test func theSyntheticStateIsImportedOnceWithDatedSources() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        let summary = await rig.importer().run()
        #expect(summary.batches == 5 && summary.compiled == 5 && summary.failed == 0 && summary.complete)
        #expect(summary.added == 6 && summary.updated == 0 && summary.dropped == 1)   // "Wren is a cousin."
        #expect(summary.skipped == [.oneWord: 3, .garbled: 3, .empty: 1, .unpaired: 2])
        #expect(Dictionary(uniqueKeysWithValues: rig.facts.map { ($0.text, $0.source) }) == [
            "The user is learning the cello.": "python:2026-06-10",
            "The user works night shifts at the Fernwick Infirmary.": "python:2026-06-10",
            "The user's town is spelled Fernwick.": "python:2026-06-11",
            "The user takes tea without sugar.": "python:2026-06-12",
            "The user is training for a marathon in October.": "python:2026-08-01",
            "The user wants to know when the Fernwick bakery opens.": "python:2026-08-02",
        ])
        #expect(rig.facts.allSatisfy { $0.isAboutUser && $0.by == .local })
        // Every batch went on-device; none held the native session, the lines before the first
        // banner, an ignored voice or a junk line.
        #expect(rig.onDevice.calls.count == 5 && rig.claude.calls.isEmpty)
        for never in ["Ashgrove", "native pair", "bees", "Wren", "upbeat", "???", "Thanks", "\u{FFFD}", "hello"] {
            #expect(!rig.onDevice.calls.contains { $0.contains(never) }, "\(never)")
        }
        #expect(rig.onDevice.calls.first?.hasPrefix("Conversation on 2026-06-10:\nUser: Jarvis, I've started") == true)
        // Progress and completion.
        let progress = try #require(rig.progress)
        #expect(progress["completed"] == .double(Self.now))
        #expect(progress["batches"] == .int(5) && progress["done"]?.arrayValue?.count == 5)
        #expect(progress["added"] == .int(6))
        // One line per batch and a summary, with no fact or message text.
        #expect(rig.logs.lines == [
            "memory: kept 8 Python-era message(s) word for word in memory/archive-python.jsonl",
            "memory: importing Python memory in 5 batch(es); 9 heard line(s) skipped (1 empty, 3 one word, 3 garbled, 2 unanswered)",
            "memory: Python import batch 1 of 5 (log, 2026-06-10, on-device): 2 new fact(s), 0 updated, 1 line(s) dropped",
            "memory: Python import batch 2 of 5 (corrections, 2026-06-11, on-device): 1 new fact(s), 0 updated, 0 line(s) dropped",
            "memory: Python import batch 3 of 5 (log, 2026-06-12, on-device): 1 new fact(s), 0 updated, 0 line(s) dropped",
            "memory: Python import batch 4 of 5 (history, 2026-08-01, on-device): 1 new fact(s), 0 updated, 0 line(s) dropped",
            "memory: Python import batch 5 of 5 (knowledge, 2026-08-02, on-device): 1 new fact(s), 0 updated, 0 line(s) dropped",
            "memory: Python import complete: 5 batch(es) (5 now, 0 earlier), 6 fact(s) added, 0 updated, 1 line(s) dropped; "
                + "9 heard line(s) skipped (1 empty, 3 one word, 3 garbled, 2 unanswered)",
        ])
        // Never twice.
        let again = await rig.importer().run()
        #expect(again.alreadyDone && again.complete && again.compiled == 0)
        #expect(rig.onDevice.calls.count == 5 && rig.facts.count == 6)
        #expect(rig.logs.lines.last == "memory: Python memory was imported on 2026-09-28 (5 batch(es), 6 fact(s) added, 0 updated); nothing to do")
    }

    /// A crash or a failed batch: the next run does only the batches not yet finished.
    @Test func itResumesWithOnlyTheUnfinishedBatches() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        rig.onDevice.fail(on: ["tea without sugar"])
        let first = await rig.importer().run()
        #expect(first.compiled == 4 && first.failed == 1 && !first.complete)
        #expect(rig.progress?["completed"] == .null && rig.progress?["done"]?.arrayValue?.count == 4)
        #expect(rig.logs.lines.contains("memory: Python import batch 3 of 5 (log, 2026-06-12, on-device) not compiled "
                                        + "(both writers failed); the next run tries it again"))
        #expect(rig.logs.lines.last?.hasPrefix("memory: Python import incomplete, 1 batch(es) not compiled: ") == true)
        rig.onDevice.fail(on: [])
        let second = await rig.importer().run()
        #expect(second.compiled == 1 && second.resumed == 4 && second.failed == 0 && second.complete)
        #expect(rig.onDevice.calls.count == 6)                                  // 5, then the one left
        #expect(rig.facts.count == 6)
        #expect(rig.progress?["completed"] == .double(Self.now) && rig.progress?["added"] == .int(6))
    }

    /// Progress lost after the facts were saved: the rerun's duplicates merge, nothing is added twice.
    @Test func aRepeatedBatchAddsNothingTwice() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        _ = await rig.importer().run()
        try FileManager.default.removeItem(atPath: rig.store.path(.pythonImport))
        let again = await rig.importer().run()
        #expect(again.compiled == 5 && again.added == 0 && again.updated == 6)
        #expect(rig.facts.count == 6)
    }

    /// A batch that does not fit the on-device model goes to Claude alone, redacted.
    @Test func aBatchThatDoesNotFitGoesToClaudeAlone() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        let summary = await rig.importer(fits: { !$0.contains("misheard") }).run()
        #expect(summary.complete && summary.added == 6)
        #expect(rig.claude.calls.count == 1 && rig.onDevice.calls.count == 4)
        #expect(rig.facts.first { $0.source == "python:2026-06-11" }?.by == .claude)
        #expect(rig.logs.lines.contains("memory: Python import batch 2 of 5 (corrections, 2026-06-11, Claude): "
                                        + "1 new fact(s), 0 updated, 0 line(s) dropped"))
        let secret = "Conversation on 2026-06-11:\nUser: my password is invented-hunter-2"
        _ = try await ClaudeAlone(claude: rig.claude).write(system: FactExtraction.system, user: secret, timeout: .seconds(1))
        #expect(rig.claude.calls.last == Redactor.redacted(secret))
        #expect(rig.claude.calls.last?.contains("invented-hunter-2") == false)
    }

    // MARK: - P6b: the Python conversations, word for word

    /// The fixture's four paired exchanges, as archive-python.jsonl keeps them.
    static let pairs: [(Double, String, MemoryRole, String)] = [
        (1_781_082_900, "2026-06-10", .user, "Jarvis, I've started learning the cello this summer"),
        (1_781_082_900, "2026-06-10", .jarvis, "Splendid, sir. Shall I warn the neighbours?"),
        (1_781_082_900, "2026-06-10", .user, "what's the weather like in Fernwick"),
        (1_781_082_900, "2026-06-10", .jarvis, "Mild and grey, sir."),
        (1_781_082_900, "2026-06-10", .user, "I work night shifts at the Fernwick Infirmary"),
        (1_781_082_900, "2026-06-10", .jarvis, "Noted, sir. Coffee on standby."),
        (1_781_294_400, "2026-06-12", .user, "I prefer my tea without sugar these days"),
        (1_781_294_400, "2026-06-12", .jarvis, "As you wish, sir."),
    ]
    static let kept = pairs.map { ArchiveEntry(timestamp: $0.0, date: $0.1, channel: "voice (Python)", role: $0.2, text: $0.3) }

    /// Each paired exchange of the log is kept word for word in archive-python.jsonl, with its
    /// session's date and start time (09:15 and 20:00 UTC) on the channel "voice (Python)", and
    /// python-import.json records it. The backups and search_memory cover the file; the chat
    /// compile never reads it. A rerun writes nothing twice.
    @Test func thePairedExchangesAreKeptWordForWordOnce() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        let summary = await rig.importer().run()
        #expect(summary.complete && summary.archived == 8)
        let bytes = try #require(rig.store.read(.pythonArchive))
        #expect(bytes == Data(Self.kept.map { $0.line + "\n" }.joined().utf8))
        #expect(rig.progress?["archived"] == .double(Self.now) && rig.progress?["archived_messages"] == .int(8))
        #expect(rig.memory.backups.newestReadable(.pythonArchive)?.entries == 8)

        #expect(rig.memory.archivedMessages() == Self.kept)
        let recall = MemoryRecall(memory: rig.memory, vectors: FactVectors(embedding: nil))
        #expect(recall.searchConversations("cello").map(\.text) == ["Jarvis, I've started learning the cello this summer"])

        #expect(rig.memory.archive("I am learning the viola as well.", role: .user, channel: "text"))
        let chat = FactCompiler(memory: rig.memory, writer: rig.onDevice, vectors: FactVectors(embedding: nil),
                                clock: rig.clock, log: { _ in })
        #expect(await chat.compile() == .compiled(added: 0, updated: 0, dropped: 0))
        #expect(rig.onDevice.calls.count == 6)                         // the import's five, then the chat
        #expect(rig.onDevice.calls.last == "Conversation on 2026-09-28:\nUser: I am learning the viola as well.")

        rig.clock.advance(3_600)
        let again = await rig.importer().run()
        #expect(again.alreadyDone && again.complete && again.archived == 0)
        #expect(rig.store.read(.pythonArchive) == bytes)
        #expect(rig.onDevice.calls.count == 6)
    }

    /// A run that completed before P6b left python-import.json without the archive record: the
    /// next run keeps the exchanges and compiles nothing again; the one after does neither.
    @Test func aRunCompletedBeforeTheArchiveKeepsTheExchangesWithoutCompilingAgain() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        _ = await rig.importer().run()
        let p6 = JSONObject(try #require(rig.progress).members.filter { !$0.key.hasPrefix("archived") })
        #expect(rig.store.write(Data(PyJSON.dumps(.object(p6), indent: 1).utf8), to: .pythonImport))
        try FileManager.default.removeItem(atPath: rig.store.path(.pythonArchive))
        rig.clock.advance(60)
        let again = await rig.importer().run()
        #expect(again.alreadyDone && again.complete && again.compiled == 0 && again.archived == 8)
        #expect(rig.onDevice.calls.count == 5 && rig.facts.count == 6)
        #expect(rig.store.read(.pythonArchive) == Data(Self.kept.map { $0.line + "\n" }.joined().utf8))
        #expect(rig.progress?["archived"] == .double(Self.now + 60) && rig.progress?["completed"] == .double(Self.now))
        let third = await rig.importer().run()
        #expect(third.alreadyDone && third.archived == 0 && rig.onDevice.calls.count == 5)
    }

    /// An archive that cannot be written (a folder in its place here) leaves the run incomplete,
    /// though every batch compiled, so a rerun writes it.
    @Test func anArchiveThatCannotBeWrittenLeavesTheRunIncomplete() async throws {
        let rig = try Rig()
        defer { rig.sb.remove() }
        try FileManager.default.createDirectory(atPath: rig.store.path(.pythonArchive), withIntermediateDirectories: true)
        let summary = await rig.importer().run()
        #expect(summary.archiveFailed && !summary.complete && summary.failed == 0)
        #expect(rig.progress?["archived"] == .null)
        #expect(rig.logs.lines.first == "memory: memory/archive-python.jsonl not written; run JARVIS "
            + "--import-python-memory again to keep the Python conversations")
        try FileManager.default.removeItem(atPath: rig.store.path(.pythonArchive))
        let again = await rig.importer().run()
        #expect(again.alreadyDone && again.complete && again.archived == 8)
    }

    /// A new install has no Python-era data: nothing to import, and it is marked done.
    @Test func noPythonDataMeansNothingToImport() async throws {
        let rig = try Rig(withFiles: false)
        defer { rig.sb.remove() }
        let summary = await rig.importer().run()
        #expect(summary.batches == 0 && summary.complete && rig.onDevice.calls.isEmpty)
        #expect(rig.logs.lines == ["memory: no Python-era conversations to import; nothing skipped"])
        #expect(rig.progress?["completed"] == .double(Self.now))
        #expect(rig.facts.isEmpty)
    }
}
