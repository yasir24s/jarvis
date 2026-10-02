import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// MEM1 part 2: the on-device model can change memory too. forget_memory, correct_memory and
/// restore_memory are in its catalog, ranked in by relevance like the rest, and the gateway's
/// rules for them hold for a local origin as for Claude's: the mass-deletion guard, the
/// forgotten bin and taint by source.
@Suite("MEM1 part 2: the on-device model's memory tools", .timeLimit(.minutes(1)))
struct LocalMemoryToolsTests {
    @Test func theCatalogHasAllFourMemoryTools() {
        let names = LocalToolset.catalog.map(\.name)
        for name in ["search_memory", "forget_memory", "correct_memory", "restore_memory"] {
            #expect(names.contains(name))
        }
        // Not pinned: only relevance brings the three that change memory in.
        #expect(LocalToolset.pinned == ["get_time", "web_search", "search_memory"])
        #expect(Set(LocalToolset.core21).isDisjoint(with: ["forget_memory", "correct_memory", "restore_memory"]))
    }

    @Test("a request to forget, correct or bring back a note ranks that tool in",
          arguments: [("forget that I have a sister", "forget_memory"),
                      ("bring back the notes you forgot", "restore_memory"),
                      ("that note is wrong, correct it: my sister is called Ana", "correct_memory")])
    func rankedIn(_ text: String, _ tool: String) async {
        let s = await LocalToolRankerTests.select(text)
        #expect(s.tier == .ranked)
        #expect(s.names.contains(tool), "\(tool) is not among \(s.names)")
        #expect(s.tools.count < LocalToolset.catalog.count)
    }

    /// The assembled gateway, called as the on-device model's tools call it (`DynamicTool`:
    /// origin `.model(.local)`), on a sandboxed memory folder.
    struct Rig {
        let dir: ShortTempDir
        let harness: CoreHarness
        let memory: MemoryStore
        let assembly: BrainAssembly

        init(facts: [MemoryFact]) async throws {
            dir = try ShortTempDir()
            harness = try CoreHarness(research: NullCounter())
            memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch))
            #expect(memory.updateFacts { $0.facts = facts; return true })
            assembly = BrainAssembly(
                core: harness.core, research: NullCounter(), config: ClaudeConfig(environment: [:]), environment: [:],
                runDirectory: dir.url.appending(path: "run", directoryHint: .isDirectory),
                claudeWorkingDirectory: dir.url.appending(path: "claude-cwd", directoryHint: .isDirectory),
                claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) }, personaWriter: ScriptedWriter(),
                memory: memory, factWriter: nil, embedding: MemoryWiringTests.TableEmbedding(table: [:]),
                textAuthenticator: FakeAuthenticator(answer: false), online: { false }, log: { _, _ in })
            try await assembly.start()
        }

        func local(_ name: String, _ members: [(String, JSONValue)], tainted: Bool = false) async -> ToolCallResult {
            await assembly.gateway.call(name, JSONObject(members.map { .init(key: $0.0, value: $0.1) }),
                                        turn: TurnContext(channel: .voice, startTainted: tainted), origin: .model(.local))
        }

        var facts: [MemoryFact] { memory.loadFacts()?.facts ?? [] }

        func remove() async {
            await assembly.stop()
            harness.remove()
            dir.remove()
        }
    }

    static func note(_ n: Int, _ text: String) -> MemoryFact {
        MemoryFact(id: "3f2a9c1e-0000-4000-8000-00000000000\(n)", text: text, source: "conversation",
                   created: CoreHarness.epoch, updated: CoreHarness.epoch + Double(n), by: .local)
    }

    static let sister = note(1, "The user has a sister.")
    static let leeds = note(2, "The user lives in Leeds.")
    static let bees = note(3, "The user keeps bees.")

    @Test func theMassDeletionGuardHoldsForALocalOrigin() async throws {
        let rig = try await Rig(facts: [Self.sister, Self.leeds, Self.bees])
        // By a phrase, one note of three is more than a forget takes at once: nothing moves.
        let refused = await rig.local("forget_memory", [("query", .string("has a sister"))])
        #expect(refused.text == "Forgetting 1 note of 3 by a phrase is more than I remove at once, so nothing was removed. "
                + "Use search_memory, then forget them by id.")
        #expect(rig.facts == [Self.sister, Self.leeds, Self.bees])
        // By id it goes, into the forgotten bin, and restore_memory brings it back.
        let removed = await rig.local("forget_memory", [("ids", .array([.string(Self.sister.id)]))])
        #expect(removed.text.hasPrefix("Removed 1 note:\n"))
        #expect(rig.facts == [Self.leeds, Self.bees])
        #expect(rig.memory.loadForgotten()?.entries.map(\.fact.id) == [Self.sister.id])
        let restored = await rig.local("restore_memory", [("ids", .array([.string(Self.sister.id)]))])
        #expect(!restored.isError && restored.record.outcome == .ran)
        #expect(rig.facts.map(\.id).contains(Self.sister.id))
        await rig.remove()
    }

    @Test func aTaintedLocalTurnCannotChangeMemory() async throws {
        let rig = try await Rig(facts: [Self.sister])
        let forget = await rig.local("forget_memory", [("ids", .array([.string(Self.sister.id)]))], tainted: true)
        #expect(forget.text == TaintPolicy.blockedTextLocal)
        let correct = await rig.local("correct_memory", [("id", .string(Self.sister.id)),
                                                         ("text", .string("The user has a brother."))], tainted: true)
        #expect(correct.text == TaintPolicy.blockedTextLocal)
        #expect(rig.facts == [Self.sister])
        await rig.remove()
    }
}
