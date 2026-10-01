import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// BrainRouter.process (plan §3.9) with fake brains on a Sandbox-backed CoreState. The prompt
/// oracle is a second CoreState run on the same root first (`CoreHarness.oracle`, which then
/// restores every file): `beginTurn` is deterministic, so its `TurnPrompt` is the one the
/// router's CoreState builds.
@Suite("M3 brain router (plan 3.9)")
struct BrainRouterTests {
    static let enabled = ClaudeConfig(environment: [:])
    static let disabled = ClaudeConfig(environment: ["JARVIS_USE_CLAUDE": "0"])
    static let text = "what time is it"
    static let interactions = "bump \(ResearchKey.interactions)+1"
    static let interactionsText = "bump \(ResearchKey.interactionsText)+1"
    static let localBackend = "backend \(LocalBrain.backendName)"

    struct Rig {
        let harness: CoreHarness
        let events: EventLog
        let claude: FakeClaudeBrain
        let local: FakeLocalBrain
        let router: BrainRouter
        let logs: LogRecorder

        init(claude reply: String?, local outcome: LocalOutcome = .reply("Local reply, sir."),
             config: ClaudeConfig = BrainRouterTests.enabled, files: [String: String]? = nil) throws {
            events = EventLog()
            let research = EventCounter(events)
            if let files {
                harness = try CoreHarness(research: research, files: files)
            } else {
                harness = try CoreHarness(research: research)
            }
            claude = FakeClaudeBrain(reply: reply, events: events)
            local = FakeLocalBrain(outcome, events: events)
            logs = LogRecorder()
            router = BrainRouter(core: harness.core, config: config, claude: claude, local: local,
                                 backend: EventBackend(events), research: research, log: logs.function)
        }

        func run(_ channel: Channel = .voice, online: Bool = true) async -> String {
            await router.process(BrainRouterTests.text, online: online, channel: channel,
                                 turn: TurnContext(channel: channel), sink: RecordingSink())
        }

        /// The saved history.json, parsed.
        func savedTurns() throws -> [JSONValue] {
            let text = try #require(harness.historyFile())
            return try #require(PyJSON.loads(Data(text.utf8)).arrayValue)
        }
    }

    /// The seed's turns as the store saves them (json.dumps' separators).
    static func seedAsSaved() throws -> String {
        PyJSON.dumps(try PyJSON.loads(Data(CoreHarness.seedHistory.utf8)))
    }

    /// The prompt oracle on the rig's own root, with its sanity checks.
    static func oracle(_ rig: Rig, online: Bool = true) async throws -> (head: CoreState.TurnPrompt, preamble: String) {
        let (head, preamble) = try await rig.harness.oracle(text, online: online)
        try #require(!preamble.isEmpty, "the seed must give a non-empty preamble")
        try #require(Array(head.claudeSystem.utf8) == Array((head.system + preamble).utf8))
        return (head, preamble)
    }

    // MARK: - §3.9 order and the Claude gate

    @Test func claudeReplyWhenEnabledAndOnline() async throws {
        let rig = try Rig(claude: "It is nine o'clock, sir.")
        defer { rig.harness.remove() }
        #expect(await rig.run() == "It is nine o'clock, sir.")
        // beginTurn (steps 1-9) bumps first; the driver, not the router, reports "claude".
        #expect(rig.events.events == [Self.interactions, "claude"])
        #expect(await rig.local.calls.isEmpty)
        let turns = try rig.savedTurns()
        #expect(turns.count == 4)
        #expect(turns.last?.objectValue?.string("role") == "assistant")
        #expect(turns.last?.objectValue?.string("content") == "It is nine o'clock, sir.")
    }

    @Test(arguments: [nil, ""] as [String?])
    func claudeNilOrEmptyFallsBackToLocal(_ reply: String?) async throws {
        let rig = try Rig(claude: reply)
        defer { rig.harness.remove() }
        #expect(await rig.run() == "Local reply, sir.")
        #expect(rig.events.events == [Self.interactions, "claude", Self.localBackend, "local"])
        let claudeCall = try #require(await rig.claude.calls.first)
        let localCall = try #require(await rig.local.calls.first)
        #expect(Array(localCall.system.utf8) == Array(claudeCall.system.utf8))
        #expect(localCall.user == Self.text && claudeCall.user == Self.text)
        #expect(try rig.savedTurns().last?.objectValue?.string("content") == "Local reply, sir.")
    }

    @Test func disabledNeverCallsClaude() async throws {
        let rig = try Rig(claude: "unused", config: Self.disabled)
        defer { rig.harness.remove() }
        #expect(await rig.run() == "Local reply, sir.")
        #expect(rig.events.events == [Self.interactions, Self.localBackend, "local"])
        #expect(await rig.claude.calls.isEmpty)
    }

    @Test func offlineNeverCallsClaude() async throws {
        let rig = try Rig(claude: "unused")
        defer { rig.harness.remove() }
        #expect(await rig.run(online: false) == "Local reply, sir.")
        #expect(rig.events.events == [Self.interactions, Self.localBackend, "local"])
        #expect(await rig.claude.calls.isEmpty)
    }

    // MARK: - interactions_text

    @Test func interactionsTextOnlyForText() async throws {
        let voice = try Rig(claude: "Voice reply, sir.")
        defer { voice.harness.remove() }
        _ = await voice.run(.voice)
        #expect(voice.events.events.filter { $0.hasPrefix("bump ") } == [Self.interactions])

        let text = try Rig(claude: "Text reply, sir.")
        defer { text.harness.remove() }
        _ = await text.run(.text)
        #expect(text.events.events.filter { $0.hasPrefix("bump ") } == [Self.interactions, Self.interactionsText])
    }

    // MARK: - The prompt

    @Test func voicePromptIsClaudeSystemExactly() async throws {
        let rig = try Rig(claude: "Voice reply, sir.")
        defer { rig.harness.remove() }
        let (head, _) = try await Self.oracle(rig)
        _ = await rig.run(.voice)
        let call = try #require(await rig.claude.calls.first)
        #expect(Array(call.system.utf8) == Array(head.claudeSystem.utf8))
        #expect(Array(BrainRouter.prompt(head, channel: .voice).utf8) == Array(head.claudeSystem.utf8))
    }

    @Test func textPromptPutsTheAddendumBeforeThePreamble() async throws {
        let rig = try Rig(claude: nil)
        defer { rig.harness.remove() }
        let (head, preamble) = try await Self.oracle(rig)
        // P4: the self-knowledge comes first; with no recall neither brain is told of search_memory.
        let expected = head.system + SelfKnowledge.withoutMemoryTools + ChannelAddendum.textChat + preamble
        _ = await rig.run(.text)
        let claudeCall = try #require(await rig.claude.calls.first)
        let localCall = try #require(await rig.local.calls.first)
        #expect(Array(claudeCall.system.utf8) == Array(expected.utf8))
        #expect(Array(localCall.system.utf8) == Array(expected.utf8))
        #expect(localCall.channel == .text)
    }

    // MARK: - History

    enum Ending: String, CaseIterable, Sendable {
        case reply, emptyReply, stuck, failed
    }

    static func turn(_ role: String, _ content: String) -> JSONValue {
        .object(JSONObject([.init(key: "role", value: .string(role)), .init(key: "content", value: .string(content))]))
    }

    /// Python's four local-loop endings (jarvis.py 5086-5118): what the router returns, and
    /// what history.json then holds. History is saved in every case, and the router says
    /// nothing to the sink (the brain speaks its own fixed replies).
    @Test(arguments: Ending.allCases)
    func localEndingShapesHistory(_ ending: Ending) async throws {
        let spoken = "Spoken text for \(ending.rawValue), sir."
        let outcome: LocalOutcome = switch ending {
        case .reply: .reply(spoken)
        case .emptyReply: .emptyReply(spoken: spoken)
        case .stuck: .stuck(spoken: spoken)
        case .failed: .failed(spoken)
        }
        let rig = try Rig(claude: nil, local: outcome, config: Self.disabled)
        defer { rig.harness.remove() }
        let sink = RecordingSink()
        let reply = await rig.router.process(Self.text, online: true, channel: .voice,
                                             turn: TurnContext(channel: .voice), sink: sink)
        #expect(reply == spoken)
        #expect(await sink.sentences.isEmpty)

        let seed = try #require(PyJSON.loads(Data(CoreHarness.seedHistory.utf8)).arrayValue)
        let user = Self.turn("user", Self.text)
        let expected: [JSONValue] = switch ending {
        case .reply: seed + [user, Self.turn("assistant", spoken)]
        case .emptyReply: seed + [user, Self.turn("assistant", "")]
        case .stuck: seed + [user]
        case .failed: seed
        }
        #expect(try rig.savedTurns() == expected)
        #expect(await rig.harness.core.history.turns.map(JSONValue.object) == expected)
        if ending == .failed {
            // Same turns as the seed, but re-saved: the bytes now have json.dumps' spacing.
            #expect(rig.harness.historyFile() == (try Self.seedAsSaved()))
        }
    }

    /// A wrong-shaped state file: Python's turn raises before its `finally`, so nothing is said
    /// or saved and the main loop logs "Loop error: …".
    @Test func wrongShapedStateEndsTheTurnQuietly() async throws {
        let rig = try Rig(claude: "unused", files: ["history.json": CoreHarness.seedHistory,
                                                    "personality.json": #"{"core": ["butler"], "learned": 5}"#])
        defer { rig.harness.remove() }
        #expect(await rig.run() == "")
        #expect(await rig.claude.calls.isEmpty)
        #expect(await rig.local.calls.isEmpty)
        #expect(rig.logs.lines.count == 1)
        #expect(rig.logs.lines.first?.hasPrefix("Loop error: personality.json: ") == true)
        #expect(rig.harness.historyFile() == CoreHarness.seedHistory)   // not saved
    }

    // MARK: - Research keys

    /// The driver keeps its own constant (its file is not T3.5's to edit); it must equal the key.
    @Test func refusalCounterIsTheResearchKey() {
        #expect(ClaudeDriver.refusalFallbackCounter == ResearchKey.claudeRefusalFallback)
    }
}
