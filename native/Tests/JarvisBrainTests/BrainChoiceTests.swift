import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// M9a part 7: BrainRouter follows the menus' Brain item turn by turn. Claude needs
/// `config.enabled && online && choice == .claude`; anything else is the on-device path, which
/// sets the backend (the "Backend: <name>" line and its existing counter) as before.
@Suite("M9 brain choice")
struct BrainChoiceTests {
    static let claudeReply = "It is nine o'clock, sir."
    static let localReply = "Local reply, sir."
    static let localBackend = "backend \(LocalBrain.backendName)"

    /// The menu's choice, changed by the test between turns.
    final class Choice: Sendable {
        private let value: Mutex<BrainChoice>
        init(_ c: BrainChoice) { value = Mutex(c) }
        func set(_ c: BrainChoice) { value.withLock { $0 = c } }
        var get: BrainChoice { value.withLock { $0 } }
    }

    struct Rig {
        let harness: CoreHarness
        let events: EventLog
        let claude: FakeClaudeBrain
        let local: FakeLocalBrain
        let router: BrainRouter
        let choice: Choice

        init(config: ClaudeConfig = ClaudeConfig(environment: [:]), choice c: BrainChoice = .claude,
             hold: Hold? = nil) throws {
            events = EventLog()
            let research = EventCounter(events)
            harness = try CoreHarness(research: research)
            claude = FakeClaudeBrain(reply: BrainChoiceTests.claudeReply, events: events, hold: hold)
            local = FakeLocalBrain(.reply(BrainChoiceTests.localReply), events: events)
            let choice = Choice(c)
            self.choice = choice
            router = BrainRouter(core: harness.core, config: config, claude: claude, local: local,
                                 backend: EventBackend(events), research: research, choice: { choice.get },
                                 log: { _ in })
        }

        func run(online: Bool = true) async -> String {
            await router.process("what time is it", online: online, channel: .text,
                                 turn: TurnContext(channel: .text), sink: RecordingSink())
        }
    }

    @Test func theRouterFollowsTheChoiceEachTurn() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.claudeReply)
        rig.choice.set(.onDevice)
        #expect(await rig.run() == Self.localReply)
        rig.choice.set(.claude)
        #expect(await rig.run() == Self.claudeReply)
        #expect(await rig.claude.calls.count == 2)
        #expect(await rig.local.calls.count == 1)
        #expect(rig.events.events.filter { $0 == Self.localBackend }.count == 1)
    }

    @Test func useClaudeZeroForcesOnDeviceWhateverTheChoice() async throws {
        let rig = try Rig(config: ClaudeConfig(environment: ["JARVIS_USE_CLAUDE": "0"]), choice: .claude)
        defer { rig.harness.remove() }
        #expect(await rig.run() == Self.localReply)
        #expect(await rig.claude.calls.isEmpty)
    }

    @Test func claudeChosenButOfflineFallsBackAsBefore() async throws {
        let rig = try Rig(choice: .claude)
        defer { rig.harness.remove() }
        #expect(await rig.run(online: false) == Self.localReply)
        #expect(await rig.claude.calls.isEmpty)
        #expect(rig.events.events.contains(Self.localBackend))
    }

    @Test(.timeLimit(.minutes(1)))
    func aTurnAlreadyRunningFinishesOnTheBrainItBeganWith() async throws {
        let hold = Hold()
        let rig = try Rig(choice: .claude, hold: hold)
        defer { rig.harness.remove() }
        let first = Task { await rig.run() }
        await hold.waitUntilEntered()
        rig.choice.set(.onDevice)
        await hold.open()
        #expect(await first.value == Self.claudeReply)
        #expect(await rig.run() == Self.localReply)
        #expect(await rig.local.calls.count == 1)
    }
}
