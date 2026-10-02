import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// MEM1 part 3: which brain said it. A brain's reply is archived with `"brain"` (claude,
/// chatgpt, on-device); the user's lines, replies no brain wrote, and every older or Python-era
/// line have none and still read.
@Suite("MEM1 part 3: the archive names the brain", .timeLimit(.minutes(1)))
struct ArchiveBrainTests {
    @Test func theLineCarriesTheBrainLastAndOldLinesStillRead() throws {
        let turn = "6F0C2E8A-1111-4222-8333-944455556666"
        let entry = ArchiveEntry(timestamp: 1_790_582_400, date: "2026-09-29", channel: "voice", role: .jarvis,
                                 text: "It's noon, sir.", turn: turn, brain: ArchiveBrain.chatgpt.rawValue)
        #expect(entry.line == #"{"timestamp": 1790582400.0, "date": "2026-09-29", "channel": "voice", "role": "jarvis", "text": "It's noon, sir.", "turn": "\#(turn)", "brain": "chatgpt"}"#)
        #expect(ArchiveEntry(line: Data(entry.line.utf8)) == entry)
        // Before MEM1, before UI1, and the Python era: no brain, read as before.
        let before = #"{"timestamp": 1790582400.0, "date": "2026-09-29", "channel": "text", "role": "jarvis", "text": "Hi.", "turn": "\#(turn)"}"#
        let older = #"{"timestamp": 1790582400.0, "date": "2026-09-29", "channel": "text", "role": "user", "text": "Hi."}"#
        let python = #"{"timestamp": 1700000000.0, "date": "2023-11-14", "channel": "voice (Python)", "role": "jarvis", "text": "Hello, sir."}"#
        for line in [before, older, python] {
            let read = try #require(ArchiveEntry(line: Data(line.utf8)), "\(line)")
            #expect(read.brain == nil)
            #expect(read.line == line)   // written back, byte for byte
        }
        #expect(ArchiveBrain.allCases.map(\.rawValue) == ["claude", "chatgpt", "on-device"])
    }

    @Test func theArchiverPutsTheBrainOnTheReplyOnly() throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch))
        let archiver = MemoryArchiver(memory: memory, log: { _ in })
        let turn = UUID()
        archiver.record(user: "What's the time?", reply: "Noon, sir.", channel: .voice, turn: turn, brain: .onDevice)
        let lines = memory.archivedMessages()
        #expect(lines.map(\.role) == [.user, .jarvis])
        #expect(lines.map(\.brain) == [nil, "on-device"])
        #expect(lines.allSatisfy { $0.turn == turn.uuidString })
    }

    /// Records each archived exchange with its brain.
    final class BrainArchive: ExchangeArchiving {
        let seen = Mutex<[String]>([])
        func record(user: String, reply: String, channel: Channel) {
            seen.withLock { $0.append("\(reply) <- none") }
        }

        func record(user: String, reply: String, channel: Channel, turn: UUID, brain: ArchiveBrain?) {
            seen.withLock { $0.append("\(reply) <- \(brain?.rawValue ?? "none")") }
        }
    }

    @Test func eachBrainsTurnIsArchivedWithItsName() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let choice = BrainChoiceTests.Choice(.claude)
        let claudeFails = Mutex(false)
        let claude = FakeClaudeBrain(reply: "Claude reply, sir.")
        let failing = FakeClaudeBrain(reply: nil)
        let router = BrainRouter(
            core: harness.core, config: ClaudeConfig(environment: [:]),
            claude: SwitchingBrain(when: { claudeFails.withLock { $0 } }, first: failing, otherwise: claude),
            chatgpt: FakeClaudeBrain(reply: "ChatGPT reply, sir."), local: FakeLocalBrain(.reply("Local reply, sir.")),
            backend: EventBackend(EventLog()), research: NullCounter(), choice: { choice.get }, log: { _ in })
        let archive = BrainArchive()
        let coordinator = TurnCoordinator(brain: router, confirmations: ConfirmationGate(),
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { true },
                                          archive: archive)
        func ask() async { _ = await coordinator.submit(UserInput(text: "hello", channel: .text), sink: RecordingSink()) }
        await ask()
        choice.set(.chatgpt)
        await ask()
        choice.set(.onDevice)
        await ask()
        choice.set(.claude)
        claudeFails.withLock { $0 = true }
        await ask()   // Claude gives nothing: the on-device model answers
        #expect(archive.seen.withLock { $0 } == ["Claude reply, sir. <- claude", "ChatGPT reply, sir. <- chatgpt",
                                                  "Local reply, sir. <- on-device", "Local reply, sir. <- on-device"])
    }

    /// `first` while `when` holds, else `otherwise`.
    struct SwitchingBrain: ClaudeGenerating {
        let when: @Sendable () -> Bool
        let first: FakeClaudeBrain
        let otherwise: FakeClaudeBrain
        func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
            await (when() ? first : otherwise).generate(system: system, user: user, turn: turn, sink: sink)
        }
    }
}
