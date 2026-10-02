import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// UI1 part 5: an edit supersedes the turns it replaced. Archive lines carry their turn's id (a
/// new last field; lines without it read as before), one appended line names the superseded
/// turns (an older reader skips it), and the compile and search_memory, through the index or a
/// scan of the files, skip those turns' messages. History is rewound to before the first
/// replaced turn, in history.json's own format.
@Suite("UI1 superseded turns", .serialized, .timeLimit(.minutes(2)))
struct SupersedeTests {
    static let utc = TimeZone(identifier: "UTC")!
    static let epoch: Double = 1_790_582_400

    struct Rig {
        let sandbox: Sandbox
        let clock = ManualClock(SupersedeTests.epoch)
        let store: StateStore
        let memory: MemoryStore
        let index: MemoryIndex

        init() throws {
            sandbox = try Sandbox()
            store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock, timeZone: SupersedeTests.utc)
            let clock = clock
            index = MemoryIndex(database: MemoryDatabase(memory: memory, now: { clock.now() }, log: { _ in }),
                                memory: memory)
        }

        var scan: MemoryRecall { MemoryRecall(memory: memory, vectors: FactVectors(embedding: nil)) }
        var indexed: MemoryRecall { MemoryRecall(memory: memory, vectors: FactVectors(embedding: nil), index: index) }

        func archiveLines() throws -> [String] {
            let data = try Data(contentsOf: URL(fileURLWithPath: memory.path(.archive)))
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }

        func exchange(_ user: String, _ reply: String, turn: UUID) {
            clock.advance(1)
            MemoryArchiver(memory: memory, log: { _ in }).record(user: user, reply: reply, channel: .text, turn: turn)
        }
    }

    @Test func linesCarryTheTurnLastAndOldLinesStillRead() throws {
        let entry = ArchiveEntry(timestamp: Self.epoch, timeZone: Self.utc, channel: "text", role: .user,
                                 text: "I live in Leeds", turn: "T-1")
        #expect(entry.line == #"{"timestamp": 1790582400.0, "date": "2026-09-28", "channel": "text", "role": "user", "text": "I live in Leeds", "turn": "T-1"}"#)
        #expect(ArchiveEntry(line: Data(entry.line.utf8)) == entry)
        let old = #"{"timestamp": 1790582400.0, "date": "2026-09-28", "channel": "text", "role": "user", "text": "I live in Leeds"}"#
        let parsed = try #require(ArchiveEntry(line: Data(old.utf8)))
        #expect(parsed.turn == nil && parsed.text == "I live in Leeds")
        #expect(ArchiveEntry(timestamp: Self.epoch, date: "2026-09-28", channel: "text", role: .user,
                             text: "I live in Leeds").line == old)
    }

    @Test func aSupersedeLineIsSkippedByAnOlderReader() throws {
        let line = ArchiveSupersede.line(turns: ["T-1", "T-2"], timestamp: Self.epoch, timeZone: Self.utc)
        #expect(line == #"{"timestamp": 1790582400.0, "date": "2026-09-28", "superseded": ["T-1", "T-2"]}"#)
        #expect(ArchiveEntry(line: Data(line.utf8)) == nil)          // what every reader before UI1 does
        #expect(ArchiveSupersede.turns(line: Data(line.utf8)) == ["T-1", "T-2"])
        let entry = ArchiveEntry(timestamp: Self.epoch, timeZone: Self.utc, channel: "text", role: .user,
                                 text: "text with \"turn\": \"T-9\" typed in it", turn: "T-1")
        let needle = ArchiveSupersede.needle(turn: "T-1")
        #expect(String(decoding: needle, as: UTF8.self) == #""turn": "T-1""#)
        #expect(Data(entry.line.utf8).range(of: needle) != nil)
        #expect(Data(entry.line.utf8).range(of: ArchiveSupersede.needle(turn: "T-9")) == nil)   // escaped in text
    }

    @Test func compileAndSearchSkipSupersededTurns() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let first = UUID(), edited = UUID(), kept = UUID()
        rig.exchange("My sister lives in Leeds", "Noted, sir.", turn: first)
        rig.exchange("My sister lives in York", "Noted, sir: York.", turn: edited)
        #expect(rig.memory.supersede(turns: [first.uuidString]))
        rig.exchange("She plays the piano", "Lovely, sir.", turn: kept)

        // The archive kept every line, and gained one.
        let lines = try rig.archiveLines()
        #expect(lines.count == 7)
        #expect(lines[4].contains(#""superseded": [""# + first.uuidString + "\"]"))

        // The compile's read, and the files' scan, skip the superseded turn.
        let read = rig.memory.archiveLines(after: 0)
        #expect(read.entries.map(\.text) == ["My sister lives in York", "Noted, sir: York.",
                                             "She plays the piano", "Lovely, sir."])
        #expect(read.ends.count == read.entries.count)
        #expect(read.end == (try Data(contentsOf: URL(fileURLWithPath: rig.memory.path(.archive)))).count)
        #expect(!rig.memory.archivedMessages().contains { $0.text.contains("Leeds") })

        // search_memory, by a scan and through the index, finds York and never Leeds.
        #expect(rig.scan.searchConversations("Leeds").isEmpty)
        #expect(rig.indexed.searchConversations("Leeds").isEmpty)
        #expect(rig.indexed.searchConversations("sister").map(\.text) == ["My sister lives in York"])
        #expect(rig.indexed.searchConversations("sister") == rig.scan.searchConversations("sister"))
    }

    @Test func theIndexForgetsATurnSupersededAfterItWasIndexed() throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let first = UUID()
        rig.exchange("The meeting is in Leeds", "Noted, sir.", turn: first)
        #expect(rig.indexed.searchConversations("Leeds").count == 1)   // indexed now
        #expect(rig.memory.supersede(turns: [first.uuidString]))
        #expect(rig.indexed.searchConversations("Leeds").isEmpty)
        #expect(rig.indexed.searchConversations("noted").isEmpty)
    }

    @Test func theCompileNeverSeesASupersededTurn() async throws {
        let rig = try Rig()
        defer { rig.sandbox.remove() }
        let first = UUID(), edited = UUID()
        rig.exchange("My sister lives in Leeds", "Noted, sir.", turn: first)
        rig.memory.supersede(turns: [first.uuidString])
        rig.exchange("My sister lives in York", "Noted, sir.", turn: edited)
        let local = ScriptedWriter(.reply("The user's sister lives in York.")), claude = ScriptedWriter(.fail(.offline))
        let writer = CollaborativePersonaLLM(local: local, claude: claude, validator: FactExtraction.passesCheck,
                                             name: "Memory writer", log: { _ in })
        let ids = FactCompilerTests.IDs()
        let compiler = FactCompiler(memory: rig.memory, writer: writer, vectors: FactVectors(embedding: nil),
                                    clock: rig.clock, makeID: { ids.next() }, log: { _ in })
        _ = await compiler.compile()
        let transcript = try #require(local.calls.first?.user)
        #expect(transcript.contains("York"))
        #expect(!transcript.contains("Leeds"))
    }

    /// History: an edit's turn rewinds to before the first replaced turn, so history.json holds
    /// the conversation up to the edited message, then the edit and its reply, in its own format.
    @Test func anEditRewindsHistoryToBeforeTheReplacedTurns() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let gate = ConfirmationGate()
        let archive = Recorded()
        let router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: [:]),
                                 claude: EchoClaude(), local: FakeLocalBrain(.reply("unused")),
                                 backend: EventBackend(EventLog()), research: NullCounter(), log: { _ in })
        let coordinator = TurnCoordinator(brain: router, confirmations: gate,
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { true },
                                          archive: archive)
        _ = await coordinator.submit(UserInput(text: "one", channel: .text), sink: SinkLog())
        _ = await coordinator.submit(UserInput(text: "two", channel: .text), sink: SinkLog())
        _ = await coordinator.submit(UserInput(text: "three", channel: .text), sink: SinkLog())
        let turns = archive.turnIDs
        #expect(turns.count == 3)

        // Edit "two": it and "three" are replaced.
        let edited = await coordinator.submit(UserInput(text: "two, edited", channel: .text,
                                                        replacing: Array(turns[1...])), sink: SinkLog())
        #expect(edited == .reply("You said: two, edited"))
        let saved = try SupersedeTests.historyTail(harness, 4)
        #expect(saved == [StopTurnTests.turn("user", "one"), StopTurnTests.turn("assistant", "You said: one"),
                          StopTurnTests.turn("user", "two, edited"),
                          StopTurnTests.turn("assistant", "You said: two, edited")])
        #expect(archive.superseded == [Array(turns[1...])])
        // history.json stays a JSON list of {"role", "content"} objects, as Python writes it.
        let text = try #require(harness.historyFile())
        #expect(text.hasPrefix(#"[{"role": "#))
    }

    /// The mark counts what this process added, less a popped user turn (the local brain's
    /// failure), so a rewind after one drops exactly the turns after the mark.
    @Test func aRewindAfterAPoppedTurnDropsOnlyWhatFollowedTheMark() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let core = harness.core
        _ = try await core.beginTurn("failed one", online: true)
        await core.popTrailingUserTurn()
        let mark = await core.historyMark()
        #expect(mark == 0)
        _ = try await core.beginTurn("kept out", online: true)
        await core.recordAssistant("a reply")
        await core.rewindHistory(to: mark)
        let turns = await core.history.turns.map { JSONValue.object($0) }
        #expect(turns == (try PyJSON.loads(Data(CoreHarness.seedHistory.utf8)).arrayValue ?? []))
        #expect(try Self.historyTail(harness, 2) == turns)
    }

    static func historyTail(_ harness: CoreHarness, _ n: Int) throws -> [JSONValue] {
        let text = try #require(harness.historyFile())
        return Array(try #require(PyJSON.loads(Data(text.utf8)).arrayValue).suffix(n))
    }
}

/// A Claude stand-in that answers "You said: <message>".
struct EchoClaude: ClaudeGenerating {
    func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
        let reply = "You said: " + user
        await sink.delta(reply)
        return reply
    }
}

/// An archive that keeps the turn ids it is given, and what was superseded.
final class Recorded: ExchangeArchiving {
    private let state = Mutex<(ids: [UUID], superseded: [[UUID]])>(([], []))

    var turnIDs: [UUID] { state.withLock { $0.ids } }
    var superseded: [[UUID]] { state.withLock { $0.superseded } }

    func record(user: String, reply: String, channel: Channel) {}

    func record(user: String, reply: String, channel: Channel, turn: UUID) {
        state.withLock { $0.ids.append(turn) }
    }

    func supersede(turns: [UUID]) {
        state.withLock { $0.superseded.append(turns) }
    }
}
