import Foundation
@testable import JarvisCore
import JarvisTestSupport
import Testing

/// U1 part 5: the persona and prompt sources are files read for every turn, never kept for the
/// life of the process. Each is edited by hand between two turns of one CoreState, and the edit
/// is in the second turn's prompt.
@Suite("U1 persona and prompt sources are read for each turn")
struct LivePersonaSourcesTests {
    static func core(_ sb: Sandbox) throws -> CoreState {
        CoreState(store: try StateStore(root: sb.root.path(percentEncoded: false), lease: nil),
                  clock: ManualClock(1_000), research: RecordingCounter(), frontApp: BlankFrontApp())
    }

    static func object(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(JSONObject(members.map { JSONObject.Member(key: $0.0, value: $0.1) }))
    }

    @Test func aHandEditedPersonalityIsInTheNextTurn() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let core = try Self.core(sb)
        let line = "Gardening: knows the user's roses by name."
        #expect(!(try await core.beginTurn("What's on today?", online: true).system.contains(line)))
        let file = Self.object([("core", .array([.string(line)])), ("learned", .array([]))])
        try sb.write("personality.json", PyJSON.dumps(file, indent: 1))
        #expect(try await core.beginTurn("What's on today?", online: true).system.contains(line))
    }

    @Test func aHandEditedProfileIsInTheNextTurn() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let core = try Self.core(sb)
        #expect(!(try await core.beginTurn("What's on today?", online: true).system.contains("Earl Grey")))
        let fact = Self.object([("value", .string("Earl Grey")), ("updated", .double(900))])
        try sb.write("profile.json", PyJSON.dumps(Self.object([("facts", Self.object([("favourite_tea", fact)]))]),
                                                  indent: 1))
        let prompt = try await core.beginTurn("What's on today?", online: true)
        #expect(prompt.system.contains("What you know about the user — favourite_tea: Earl Grey"))
    }

    @Test func aHandEditedKnowledgeTopicIsInTheNextTurn() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let core = try Self.core(sb)
        #expect(!(try await core.beginTurn("What's on today?", online: true).system.contains("Pruned in March.")))
        let topic = Self.object([("summary", .string("Pruned in March.")), ("updated", .double(900))])
        try sb.write("knowledge.json", PyJSON.dumps(Self.object([("topics", Self.object([("roses", topic)])),
                                                                 ("queue", .array([]))]), indent: 1))
        let prompt = try await core.beginTurn("What's on today?", online: true)
        #expect(prompt.system.contains("Recently learned — roses: Pruned in March."))
    }

    /// The base system prompt is code and the CHANGELOG.md path, never the file's text, so
    /// nothing in it can go stale while JARVIS runs.
    @Test func theBasePromptReadsNoFileSoNothingInItCanGoStale() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        try sb.write("CHANGELOG.md", "first changelog text")
        let store = try StateStore(root: sb.root.path(percentEncoded: false), lease: nil)
        let core = CoreState(store: store, clock: ManualClock(1_000), research: RecordingCounter(), frontApp: BlankFrontApp())
        let base = SystemPrompt.base(changelogPath: StateStore.join(store.root, "CHANGELOG.md"))
        let before = try await core.beginTurn("What's on today?", online: true)
        try sb.write("CHANGELOG.md", "second changelog text")
        let after = try await core.beginTurn("What's on today?", online: true)
        #expect(before.system.hasPrefix(base) && after.system.hasPrefix(base))
        #expect(!before.system.contains("changelog text") && !after.system.contains("changelog text"))
    }
}
