import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// D-51 P2, piece 5: BrainAssembly with a memory store archives each exchange, compiles facts
/// after the personality distillation when a typed dismissal ends the conversation, and
/// recalls them into the next turn's prompt. Fakes stand in for the writers, the embedder and
/// the brains; nothing here runs a model or `claude`.
@Suite("P2 memory wiring in BrainAssembly", .timeLimit(.minutes(1)))
struct MemoryWiringTests {
    static let fact = "The user's sister is called Amira."

    /// Answers every compile with `reply` as the on-device draft, recording each transcript.
    final class FakeFactWriter: AttributedWriting {
        private let users = Mutex<[String]>([])
        let reply: String
        init(_ reply: String) { self.reply = reply }
        var transcripts: [String] { users.withLock { $0 } }
        func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
            users.withLock { $0.append(user) }
            return AttributedText(text: reply, author: .local)
        }
    }

    struct TableEmbedding: SentenceEmbedding {
        let table: [String: [Double]]
        func vector(for sentence: String) -> [Double]? { table[sentence] }
    }

    static func assembly(core: CoreState, memory: MemoryStore?, personaWriter: any PersonaLLM,
                         factWriter: (any AttributedWriting)?, local: FakeLocalBrain, dir: URL) -> BrainAssembly {
        BrainAssembly(core: core, research: NullCounter(), config: ClaudeConfig(environment: [:]), environment: [:],
                      runDirectory: dir.appending(path: "run", directoryHint: .isDirectory),
                      claudeWorkingDirectory: dir.appending(path: "claude-cwd", directoryHint: .isDirectory),
                      claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                      localBrain: { _ in local }, personaWriter: personaWriter,
                      memory: memory, factWriter: factWriter,
                      embedding: TableEmbedding(table: ["Is Amira coming over?": [1, 0], Self.fact: [1, 0]]),
                      textAuthenticator: FakeAuthenticator(answer: false), online: { false }, log: { _, _ in })
    }

    @Test func aConversationIsArchivedCompiledAndRecalled() async throws {
        let harness = try CoreHarness(research: NullCounter(), files: ["history.json": DismissalTurnTests.fourTurns])
        defer { harness.remove() }
        let memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch),
                                 timeZone: TimeZone(identifier: "UTC")!)
        let persona = ScriptedWriter(.reply("The user enjoys a dry joke."))
        let facts = FakeFactWriter(Self.fact)
        let local = FakeLocalBrain(.reply("How lovely, sir."))
        let assembly = Self.assembly(core: harness.core, memory: memory, personaWriter: persona, factWriter: facts,
                                     local: local, dir: harness.sandbox.root)
        assembly.personality.start()
        defer { assembly.personality.stop() }

        _ = await assembly.coordinator.submit(UserInput(text: "My sister Amira is visiting next week", channel: .text),
                                              sink: RecordingSink())
        #expect(memory.archive(after: 0).entries.map(\.text) == ["My sister Amira is visiting next week", "How lovely, sir."])
        let first = try #require(await local.calls.first)
        #expect(!first.system.contains(MemoryRecall.localHeader))                // nothing known yet

        #expect(await assembly.coordinator.submit(UserInput(text: "That's all, JARVIS.", channel: .text),
                                                  sink: RecordingSink()) == .dismissed(Dismissal.reply))
        try await waitUntil("the compiled fact to be saved") { memory.loadFacts()?.facts.map(\.text) == [Self.fact] }
        #expect(harness.sandbox.personalityNotes() == ["The user enjoys a dry joke"])     // the distillation ran too
        #expect(persona.calls.map(\.system) == [PersonaDistill.distillSystem])
        #expect(facts.transcripts == ["Conversation on 2026-09-28:\nUser: My sister Amira is visiting next week\n"
            + "JARVIS: How lovely, sir.\nUser: That's all, JARVIS.\nJARVIS: Always a pleasure, sir."])

        _ = await assembly.coordinator.submit(UserInput(text: "Is Amira coming over?", channel: .text), sink: RecordingSink())
        let recalled = try #require(await local.calls.last?.system)
        let block = MemoryRecall.localHeader + "\n- " + Self.fact
        let addendum = try #require(recalled.range(of: ChannelAddendum.textChat))
        let memoryAt = try #require(recalled.range(of: block))
        let preamble = try #require(recalled.range(of: "\n\nRecent conversation:"))
        #expect(addendum.upperBound == memoryAt.lowerBound && memoryAt.upperBound == preamble.lowerBound)
    }

    @Test func withoutAMemoryStoreNothingIsKept() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let local = FakeLocalBrain(.reply("Local reply, sir."))
        let assembly = Self.assembly(core: harness.core, memory: nil, personaWriter: ScriptedWriter(),
                                     factWriter: nil, local: local, dir: harness.sandbox.root)
        #expect(assembly.facts == nil && assembly.recall == nil)
        _ = await assembly.coordinator.submit(UserInput(text: "My sister Amira is visiting", channel: .text),
                                              sink: RecordingSink())
        #expect(!harness.sandbox.exists("memory"))
        #expect(await local.calls.count == 1)
    }

    /// With no fact writer given, the assembly builds its own collaborative one over P1's writers.
    @Test func theDefaultFactWriterIsBuiltWithTheMemory() throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let assembly = Self.assembly(core: harness.core, memory: MemoryStore(store: harness.store),
                                     personaWriter: ScriptedWriter(), factWriter: nil,
                                     local: FakeLocalBrain(.reply("x")), dir: harness.sandbox.root)
        #expect(assembly.facts != nil && assembly.recall != nil)
    }
}
