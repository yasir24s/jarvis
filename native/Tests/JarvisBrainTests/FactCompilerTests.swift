import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// D-51 P2, piece 3: at a conversation's end the collaborative writers extract facts from the
/// archive since the last compile; the validator drops the bad lines; duplicates (normalised,
/// or embedding cosine at or above 0.9) refresh a fact instead of adding one; each fact records
/// its writer; and nothing is written when both writers fail or the lease is gone.
@Suite("P2 fact compile", .timeLimit(.minutes(1)))
struct FactCompilerTests {
    static let epoch: Double = 1_790_582_400
    static let utc = TimeZone(identifier: "UTC")!

    final class IDs: Sendable {
        private let n = Mutex(0)
        func next() -> String { n.withLock { $0 += 1; return "fact-\($0)" } }
    }

    /// Vectors by exact text; anything else has none.
    struct TableEmbedding: SentenceEmbedding {
        let table: [String: [Double]]
        func vector(for sentence: String) -> [Double]? { table[sentence] }
    }

    /// A lease the test flips by hand.
    final class FlagLease: StateLease {
        private let held: Mutex<Bool>
        init(_ held: Bool) { self.held = Mutex(held) }
        var isHeld: Bool { held.withLock { $0 } }
        func set(_ h: Bool) { held.withLock { $0 = h } }
    }

    /// An attributed writer that waits on `hold` and then answers `text` as the on-device draft.
    struct HeldWriter: AttributedWriting {
        let hold: Hold
        let text: String
        func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
            await hold.enter()
            return AttributedText(text: text, author: .local)
        }
    }

    struct Rig {
        let sandbox: Sandbox
        let store: StateStore
        let clock = ManualClock(FactCompilerTests.epoch)
        let memory: MemoryStore
        let ids = IDs()
        let logs = LogRecorder()

        init(lease: (any StateLease)? = nil) throws {
            sandbox = try Sandbox()
            store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: lease, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: FactCompilerTests.utc)
        }

        func converse(_ messages: [(MemoryRole, String)]) {
            for (role, text) in messages { #expect(memory.archive(text, role: role, channel: "text")) }
        }

        func compiler(local: ScriptedWriter, claude: ScriptedWriter,
                      embedding: (any SentenceEmbedding)? = nil) -> FactCompiler {
            let writer = CollaborativePersonaLLM(local: local, claude: claude, validator: FactExtraction.passesCheck,
                                                 name: "Memory writer", log: logs.function)
            return compiler(writer: writer, embedding: embedding)
        }

        func compiler(writer: any AttributedWriting, embedding: (any SentenceEmbedding)? = nil) -> FactCompiler {
            let ids = ids
            return FactCompiler(memory: memory, writer: writer, vectors: FactVectors(embedding: embedding),
                                clock: clock, makeID: { ids.next() }, log: logs.function)
        }

        var facts: [MemoryFact] { memory.loadFacts()?.facts ?? [] }
        var archiveSize: Int { (try? Data(contentsOf: URL(fileURLWithPath: store.path(.archive))))?.count ?? -1 }
        func factsBytes() -> Data? { FileManager.default.contents(atPath: store.path(.facts)) }
    }

    static let conversation: [(MemoryRole, String)] = [
        (.user, "My sister Amira just moved to Leeds. Also my password is hunter2, don't tell anyone."),
        (.jarvis, "Noted, sir. I shall keep that to myself."),
        (.user, "that's all, JARVIS"),
        (.jarvis, "Always a pleasure, sir."),
    ]

    static let transcript = """
        Conversation on 2026-09-28:
        User: My sister Amira just moved to Leeds. Also my password is hunter2, don't tell anyone.
        JARVIS: Noted, sir. I shall keep that to myself.
        User: that's all, JARVIS
        JARVIS: Always a pleasure, sir.
        """

    static func fact(_ id: String, _ text: String, _ by: FactWriter, created: Double = epoch,
                     updated: Double = epoch) -> MemoryFact {
        MemoryFact(id: id, text: text, source: "conversation", created: created, updated: updated, by: by)
    }

    // MARK: - Extract and validate

    @Test func aConversationBecomesValidatedFactsByTheOnDeviceDraft() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let draft = "The user's sister is called Amira.\nThe user's password is hunter2.\n- The user's sister lives in Leeds."
        let local = ScriptedWriter(.reply(draft)), claude = ScriptedWriter(.fail(.offline))

        let outcome = await rig.compiler(local: local, claude: claude).compile()

        #expect(outcome == .compiled(added: 2, updated: 0, dropped: 1))
        #expect(local.calls == [.init(system: FactExtraction.system, user: Self.transcript, timeout: .seconds(120))])
        #expect(claude.calls.map(\.user) == [CollaborativePersonaLLM.improveRequest(user: Self.transcript, draft: draft)])
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister is called Amira.", .local),
                              Self.fact("fact-2", "The user's sister lives in Leeds.", .local)])
        #expect(rig.memory.loadFacts()?.compiledThrough == rig.archiveSize)
        #expect(rig.logs.lines == ["Memory writer: on-device draft (offline).",
                                   "memory: compiled 4 message(s): 2 new fact(s), 0 updated, 1 line(s) dropped"])
        #expect(!rig.logs.lines.joined().contains("Amira") && !rig.logs.lines.joined().contains("hunter2"))
    }

    /// Claude's improvement replaces the draft; a fact the draft also had is `both`, one only
    /// Claude wrote is `claude`, and a draft line Claude left out is gone.
    @Test func claudesImprovementIsTakenAndEachFactAttributed() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let local = ScriptedWriter(.reply("The user's sister is Amira.\nThe user is called Amira."))
        let claude = ScriptedWriter(.reply("The user's sister is Amira!\nThe user's sister lives in Leeds."))

        #expect(await rig.compiler(local: local, claude: claude).compile() == .compiled(added: 2, updated: 0, dropped: 0))
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister is Amira!", .both),
                              Self.fact("fact-2", "The user's sister lives in Leeds.", .claude)])
        #expect(rig.logs.lines.first == "Memory writer: Claude, improving the on-device draft.")
    }

    @Test func claudesVersionThatFailsTheValidatorLeavesTheDraft() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let local = ScriptedWriter(.reply("The user's sister lives in Leeds."))
        let claude = ScriptedWriter(.reply("Here is what I found:\nhttps://example.com/amira"))

        #expect(await rig.compiler(local: local, claude: claude).compile() == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister lives in Leeds.", .local)])
        #expect(rig.logs.lines.first == "Memory writer: on-device draft (Claude's version failed the check).")
    }

    @Test func claudeAloneWhenTheOnDeviceModelFails() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let local = ScriptedWriter(.fail(.localUnavailable("modelNotReady")))
        let claude = ScriptedWriter(.reply("The user's sister lives in Leeds."))

        #expect(await rig.compiler(local: local, claude: claude).compile() == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(claude.calls.map(\.user) == [Self.transcript])
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister lives in Leeds.", .claude)])
    }

    @Test func noneAddsNothingButConsumesTheConversation() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let compiler = rig.compiler(local: ScriptedWriter(.reply("NONE")), claude: ScriptedWriter(.reply("NONE")))
        #expect(await compiler.compile() == .compiled(added: 0, updated: 0, dropped: 0))
        #expect(rig.memory.loadFacts() == FactsFile(compiledThrough: rig.archiveSize, facts: []))
        #expect(await compiler.compile() == .nothingNew)
    }

    // MARK: - Both fail: nothing written

    @Test func bothWritersFailingWritesNothing() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let first = rig.compiler(local: ScriptedWriter(.fail(.localUnavailable("modelNotReady"))),
                                 claude: ScriptedWriter(.fail(.offline)))
        #expect(await first.compile() == .writersFailed)
        #expect(rig.factsBytes() == nil)
        #expect(rig.logs.lines.last == "memory: facts not compiled (no writer: on-device model unavailable (modelNotReady); offline)")

        // With facts already there, a failed compile leaves every byte, offset included.
        let ok = rig.compiler(local: ScriptedWriter(.reply("The user's sister lives in Leeds.")),
                              claude: ScriptedWriter(.fail(.offline)))
        #expect(await ok.compile() == .compiled(added: 1, updated: 0, dropped: 0))
        let saved = try #require(rig.factsBytes())
        rig.converse([(.user, "I start at the new job on Monday."), (.jarvis, "Splendid, sir.")])
        let local = ScriptedWriter(.fail(.localFailed("FakeModelError")))
        let failing = rig.compiler(local: local, claude: ScriptedWriter(.fail(.claudeOff)))
        #expect(await failing.compile() == .writersFailed)
        #expect(rig.factsBytes() == saved)

        // The next compile reads the same conversation again.
        let retry = ScriptedWriter(.reply("NONE"))
        #expect(await rig.compiler(local: retry, claude: ScriptedWriter(.reply("NONE"))).compile()
            == .compiled(added: 0, updated: 0, dropped: 0))
        #expect(retry.calls.map(\.user) == local.calls.map(\.user))
        #expect(retry.calls.first?.user.contains("new job on Monday") == true)
    }

    // MARK: - Since the last compile

    @Test func onlyTheConversationSinceTheLastCompileIsRead() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        #expect(await rig.compiler(local: ScriptedWriter(.reply("NONE")), claude: ScriptedWriter(.reply("NONE")))
            .compile() == .compiled(added: 0, updated: 0, dropped: 0))
        rig.clock.set(Self.epoch + 86400)
        rig.converse([(.user, "I start at the new job on Monday."), (.jarvis, "Splendid, sir.")])
        let local = ScriptedWriter(.reply("The user starts a new job on Monday 5 October 2026."))
        #expect(await rig.compiler(local: local, claude: ScriptedWriter(.fail(.offline))).compile()
            == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(local.calls.map(\.user) == ["Conversation on 2026-09-29:\nUser: I start at the new job on Monday.\n"
            + "JARVIS: Splendid, sir."])
    }

    @Test func nothingNewFromTheUserAsksNoWriter() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let local = ScriptedWriter(), claude = ScriptedWriter()
        let compiler = rig.compiler(local: local, claude: claude)
        #expect(await compiler.compile() == .nothingNew)                     // no archive yet
        rig.converse([(.jarvis, "Good evening, sir.")])
        #expect(await compiler.compile() == .nothingNew)                     // JARVIS only
        #expect(local.calls.isEmpty && claude.calls.isEmpty)
        #expect(rig.factsBytes() == nil)
    }

    // MARK: - P6b: nothing is skipped

    /// 30 exchanges of about 640 characters: four batches' worth.
    static let longChat: [(MemoryRole, String)] = (0..<30).flatMap { k -> [(MemoryRole, String)] in
        [(.user, "Exchange \(k): " + String(repeating: "tea ", count: 75)),
         (.jarvis, "Reply \(k): " + String(repeating: "sir ", count: 75))]
    }

    /// Everything past the offset is compiled, oldest first, one writer call per batch: each
    /// transcript is a whole batch, none leaves a message out, and together they hold every
    /// message. The offset ends at the archive's end, so nothing is read twice.
    @Test func aLongArchiveIsCompiledInBatchesOldestFirst() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.longChat)
        let entries = rig.memory.archive(after: 0).entries
        let batches = FactExtraction.batches(entries)
        #expect(batches.map(\.count) == [18, 18, 18, 6])
        let local = ScriptedWriter(.reply("The user's sister lives in Leeds."), .reply("NONE"),
                                   .reply("The user keeps bees."), .reply("NONE"))
        let compiler = rig.compiler(local: local, claude: ScriptedWriter())
        #expect(await compiler.compile() == .compiled(added: 2, updated: 0, dropped: 0))

        #expect(local.calls.map(\.user) == batches.map { FactExtraction.transcript(Array(entries[$0])).text })
        for range in batches { #expect(FactExtraction.transcript(Array(entries[range])).omitted == 0) }
        let read = local.calls.map(\.user).joined(separator: "\n")
        for k in 0..<30 { #expect(read.contains("User: Exchange \(k): ") && read.contains("JARVIS: Reply \(k): ")) }
        #expect(rig.memory.loadFacts() == FactsFile(compiledThrough: rig.archiveSize, facts: [
            Self.fact("fact-1", "The user's sister lives in Leeds.", .local),
            Self.fact("fact-2", "The user keeps bees.", .local),
        ]))
        #expect(rig.logs.lines.last == "memory: compiled 60 message(s) in 4 batches: 2 new fact(s), 0 updated, "
            + "0 line(s) dropped")
        #expect(await compiler.compile() == .nothingNew)
    }

    /// A batch whose writers both fail ends the compile. The batch before it stays compiled,
    /// with the offset at its end; the next compile starts at the failed batch and finishes.
    @Test func aFailedBatchStopsTheCompileAndTheNextResumesThere() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.longChat)
        let read = rig.memory.archiveLines(after: 0)
        let batches = FactExtraction.batches(read.entries)
        let local = ScriptedWriter(.reply("The user's sister lives in Leeds."), .fail(.localFailed("FakeModelError")))
        #expect(await rig.compiler(local: local, claude: ScriptedWriter()).compile() == .writersFailed)
        #expect(local.calls.count == 2)
        #expect(rig.memory.loadFacts() == FactsFile(compiledThrough: read.ends[batches[0].upperBound - 1], facts: [
            Self.fact("fact-1", "The user's sister lives in Leeds.", .local),
        ]))
        #expect(rig.logs.lines.last == "memory: compiled 1 of 4 batches (1 new fact(s), 0 updated); "
            + "the next compile resumes at batch 2")

        let retry = ScriptedWriter(.reply("NONE"), .reply("The user keeps bees."), .reply("NONE"))
        #expect(await rig.compiler(local: retry, claude: ScriptedWriter()).compile()
            == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(retry.calls.map(\.user) == batches.dropFirst().map {
            FactExtraction.transcript(Array(read.entries[$0])).text
        })
        #expect(retry.calls.first?.user == local.calls.last?.user)          // the failed batch, read again
        #expect(rig.memory.loadFacts()?.compiledThrough == rig.archiveSize)
        #expect(rig.facts.map(\.text) == ["The user's sister lives in Leeds.", "The user keeps bees."])
    }

    // MARK: - Merge duplicates

    @Test func aDuplicateInALaterConversationRefreshesTheFact() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        #expect(await rig.compiler(local: ScriptedWriter(.reply("The user's sister lives in Leeds.")),
                                   claude: ScriptedWriter(.fail(.offline))).compile()
            == .compiled(added: 1, updated: 0, dropped: 0))
        rig.clock.set(Self.epoch + 3600)
        rig.converse([(.user, "Amira says hello from Leeds."), (.jarvis, "Do send my regards, sir.")])
        #expect(await rig.compiler(local: ScriptedWriter(.fail(.localUnavailable("modelNotReady"))),
                                   claude: ScriptedWriter(.reply("the user's sister lives in LEEDS"))).compile()
            == .compiled(added: 0, updated: 1, dropped: 0))
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister lives in Leeds.", .both,
                                        created: Self.epoch, updated: Self.epoch + 3600)])
    }

    /// Cosine exactly 0.9 merges ([5,5,5,5] against [7,5,5,1]: 90 / (10 * 10)); 0.8 does not.
    @Test func embeddingSimilarityAtOrAboveTheThresholdMerges() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let embedding = TableEmbedding(table: [
            "The user's sister lives in Leeds.": [5, 5, 5, 5],
            "The user's sister has a flat in Leeds.": [7, 5, 5, 1],             // 0.9
            "The user's sister studies in Leeds.": [7, 7, 1, 1],                // 0.8
        ])
        rig.converse(Self.conversation)
        #expect(await rig.compiler(local: ScriptedWriter(.reply("The user's sister lives in Leeds.")),
                                   claude: ScriptedWriter(.fail(.offline)), embedding: embedding).compile()
            == .compiled(added: 1, updated: 0, dropped: 0))
        rig.clock.set(Self.epoch + 60)
        rig.converse([(.user, "Amira's flat in Leeds is lovely, she studies there too."), (.jarvis, "Indeed, sir.")])
        let reply = "The user's sister has a flat in Leeds.\nThe user's sister studies in Leeds."
        #expect(await rig.compiler(local: ScriptedWriter(.reply(reply)), claude: ScriptedWriter(.fail(.offline)),
                                   embedding: embedding).compile()
            == .compiled(added: 1, updated: 1, dropped: 0))
        #expect(rig.facts == [Self.fact("fact-1", "The user's sister lives in Leeds.", .local, updated: Self.epoch + 60),
                              Self.fact("fact-2", "The user's sister studies in Leeds.", .local,
                                        created: Self.epoch + 60, updated: Self.epoch + 60)])
        #expect(FactVectors.cosine([5, 5, 5, 5], [7, 5, 5, 1]) == 0.9)
    }

    // MARK: - Lease, one at a time

    @Test func aCompileWithoutTheLeaseWritesNothing() async throws {
        let lease = FlagLease(true)
        let rig = try Rig(lease: lease)
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        lease.set(false)
        #expect(await rig.compiler(local: ScriptedWriter(.reply("The user's sister lives in Leeds.")),
                                   claude: ScriptedWriter(.fail(.offline))).compile() == .notSaved)
        #expect(rig.factsBytes() == nil)
        #expect(rig.logs.lines.last == "memory: facts not saved")
    }

    @Test func aSecondCompileWhileOneRunsIsRefused() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        let hold = Hold()
        let compiler = rig.compiler(writer: HeldWriter(hold: hold, text: "The user's sister lives in Leeds."))
        let first = Task { await compiler.compile() }
        await hold.waitUntilEntered()
        #expect(await compiler.compile() == .busy)
        await hold.open()
        #expect(await first.value == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(rig.facts.count == 1)
    }

    @Test func anUnreadableFactsFileIsLeftAlone() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        rig.converse(Self.conversation)
        try rig.sandbox.write("memory/facts.json", "{not json")
        let local = ScriptedWriter()
        #expect(await rig.compiler(local: local, claude: ScriptedWriter()).compile() == .unreadable)
        #expect(local.calls.isEmpty)
        #expect(rig.factsBytes() == Data("{not json".utf8))
    }
}
