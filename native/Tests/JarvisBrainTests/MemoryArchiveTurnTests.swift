import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// D-51 P2, piece 2: TurnCoordinator archives every accepted exchange once its reply has gone
/// to the sink, on each path (brain, fast path, confirmation, typed dismissal), and nothing
/// for a refused turn. MemoryArchiver writes the two archive lines and logs counts only.
@Suite("P2 archive every exchange", .timeLimit(.minutes(1)))
struct MemoryArchiveTurnTests {
    /// Records each exchange into the same event log as the sink, so their order shows.
    final class EventArchive: ExchangeArchiving {
        let log: EventLog
        init(_ log: EventLog) { self.log = log }
        func record(user: String, reply: String, channel: Channel) {
            log.add("archive \(channel.rawValue) \(user) -> \(reply)")
        }
    }

    struct Rig {
        let harness: CoreHarness
        let events = EventLog()
        let claude: FakeClaudeBrain
        let fastPath: FakeFastPath
        let gate = ConfirmationGate()
        let sink: EventSink
        let coordinator: TurnCoordinator

        init(fastPath fast: String? = nil, hold: Hold? = nil, archive: (any ExchangeArchiving)? = nil,
             onConversationEnded: (@Sendable () -> Void)? = nil) throws {
            harness = try CoreHarness(research: NullCounter())
            claude = FakeClaudeBrain(reply: "Claude reply, sir.", sentences: ["Claude reply, sir."], hold: hold)
            fastPath = FakeFastPath(reply: fast)
            sink = EventSink(events)
            let router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: [:]), claude: claude,
                                     local: FakeLocalBrain(.reply("Local reply, sir.")),
                                     backend: EventBackend(EventLog()), research: NullCounter(), log: { _ in })
            coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: gate,
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { true },
                                          onConversationEnded: onConversationEnded,
                                          archive: archive ?? EventArchive(events))
        }

        func submit(_ text: String, _ channel: Channel = .voice) async -> TurnOutcome {
            await coordinator.submit(UserInput(text: text, channel: channel), sink: sink)
        }
    }

    @Test func aBrainReplyIsArchivedAfterItReachedTheSink() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        #expect(await rig.submit("  what's on today? \n") == .reply("Claude reply, sir."))
        #expect(rig.events.events == ["sink Claude reply, sir.",
                                      "archive voice what's on today? -> Claude reply, sir."])
    }

    @Test func theFastPathAndAConfirmationAreArchived() async throws {
        let rig = try Rig(fastPath: "Fast reply, sir.")
        defer { rig.harness.remove() }
        #expect(await rig.submit("volume up", .text) == .fastPath("Fast reply, sir."))
        await rig.gate.stash(desc: "That will delete notes.txt permanently", action: { "Deleted, sir." },
                             turn: TurnContext(channel: .voice))
        #expect(await rig.submit("yes") == .confirmation("Deleted, sir."))
        #expect(rig.events.events == ["sink Fast reply, sir.", "archive text volume up -> Fast reply, sir.",
                                      "sink Deleted, sir.", "archive voice yes -> Deleted, sir."])
    }

    /// The dismissal is archived after its reply and before the conversation-ended hook, so
    /// the compile that hook starts reads the whole conversation.
    @Test func aDismissalIsArchivedBeforeTheConversationEnds() async throws {
        let events = EventLog()
        let rig = try Rig(archive: EventArchive(events), onConversationEnded: { events.add("ended") })
        defer { rig.harness.remove() }
        let sink = EventSink(events)
        #expect(await rig.coordinator.submit(UserInput(text: "That's all, JARVIS.", channel: .text), sink: sink)
            == .dismissed(Dismissal.reply))
        #expect(events.events == ["sink Always a pleasure, sir.",
                                  "archive text That's all, JARVIS. -> Always a pleasure, sir.", "ended"])
    }

    @Test func refusedTurnsAreNotArchived() async throws {
        let hold = Hold()
        let rig = try Rig(hold: hold)
        defer { rig.harness.remove() }
        #expect(await rig.submit(" \n\t") == .empty)
        let first = Task { await rig.submit("first") }
        await hold.waitUntilEntered()
        #expect(await rig.submit("second", .text) == .busy)
        await hold.open()
        #expect(await first.value == .reply("Claude reply, sir."))
        #expect(rig.events.events == ["sink Claude reply, sir.", "archive voice first -> Claude reply, sir."])
    }

    // MARK: - MemoryArchiver over the real MemoryStore

    @Test func memoryArchiverWritesTheExchangeAndLogsCountsOnly() async throws {
        let logged = EventLog()
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let clock = ManualClock(CoreHarness.epoch)
        let memory = MemoryStore(store: harness.store, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        let rig = try Rig(archive: MemoryArchiver(memory: memory, log: { logged.add($0) }))
        defer { rig.harness.remove() }

        #expect(await rig.submit("my sister Amira lives in Leeds", .text) == .reply("Claude reply, sir."))
        let lines = try harness.sandbox.read("memory/archive.jsonl").split(separator: "\n").map(String.init)
        // UI1 part 5: each line ends with its turn's id, the same on both.
        let turn = try #require(ArchiveEntry(line: Data((lines.first ?? "").utf8))?.turn)
        #expect(UUID(uuidString: turn) != nil)
        #expect(lines == [
            #"{"timestamp": 1790582400.0, "date": "2026-09-28", "channel": "text", "role": "user", "text": "my sister Amira lives in Leeds", "turn": ""# + turn + #""}"#,
            // MEM1 part 3: the reply's line also names the brain that wrote it.
            #"{"timestamp": 1790582400.0, "date": "2026-09-28", "channel": "text", "role": "jarvis", "text": "Claude reply, sir.", "turn": ""# + turn + #"", "brain": "claude"}"#,
        ])
        #expect(logged.events == ["memory: archived 2 message(s)"])

        MemoryArchiver(memory: memory, log: { logged.add($0) }).record(user: "only me", reply: "", channel: .voice)
        #expect(memory.archive(after: 0).entries.map(\.text) == ["my sister Amira lives in Leeds",
                                                                 "Claude reply, sir.", "only me"])
        #expect(logged.events.last == "memory: archived 1 message(s)")
        #expect(!logged.events.joined().contains("Amira") && !logged.events.joined().contains("only me"))
    }

    @Test func aRefusedArchiveWriteIsLoggedAsACount() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        final class Lost: StateLease { var isHeld: Bool { false } }
        let store = try StateStore(root: sb.root.path(percentEncoded: false), lease: Lost())
        let logged = EventLog()
        MemoryArchiver(memory: MemoryStore(store: store), log: { logged.add($0) })
            .record(user: "secret plans", reply: "Noted, sir.", channel: .text)
        #expect(logged.events == ["memory: 2 of 2 message(s) not archived"])
        #expect(!FileManager.default.fileExists(atPath: sb.root.path(percentEncoded: false) + "memory"))
    }
}
