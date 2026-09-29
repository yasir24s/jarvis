import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// TurnCoordinator.submit (plan §3.5, jarvis.py `handle_one`) over a real BrainRouter with fake
/// brains and fast path, a fresh ConfirmationGate and a Sandbox-backed CoreState.
@Suite("M3 turn coordinator (plan 3.5)")
struct TurnCoordinatorTests {
    static let claudeReply = "Claude reply, sir."
    static let desc = "That will delete robin-notes.txt permanently"

    struct Rig {
        let harness: CoreHarness
        let events: EventLog
        let claude: FakeClaudeBrain
        let local: FakeLocalBrain
        let fastPath: FakeFastPath
        let gate: ConfirmationGate
        let auth: FakeAuthenticator
        let turns = TurnRecorder()
        let online: OnlineProbe
        let sink = RecordingSink()
        let coordinator: TurnCoordinator

        init(claude reply: String? = TurnCoordinatorTests.claudeReply, hold: Hold? = nil,
             local outcome: LocalOutcome = .reply("Local reply, sir."), fastPath fast: String? = nil,
             authenticates: Bool = true, online isOnline: Bool = true,
             config: ClaudeConfig = ClaudeConfig(environment: [:])) throws {
            events = EventLog()
            let research = EventCounter(events)
            harness = try CoreHarness(research: research)
            claude = FakeClaudeBrain(reply: reply, events: events, hold: hold)
            local = FakeLocalBrain(outcome, events: events)
            fastPath = FakeFastPath(reply: fast)
            gate = ConfirmationGate()
            auth = FakeAuthenticator(answer: authenticates)
            online = OnlineProbe(isOnline)
            let router = BrainRouter(core: harness.core, config: config, claude: claude, local: local,
                                     backend: EventBackend(events), research: research, log: { _ in })
            let turns = turns, online = online
            coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: gate,
                                          textAuthenticator: auth, online: { online.ask() },
                                          onTurnStart: { turns.add($0) })
        }

        func submit(_ text: String, _ channel: Channel = .voice, pasted: Bool = false) async -> TurnOutcome {
            await coordinator.submit(UserInput(text: text, channel: channel, pasted: pasted), sink: sink)
        }

        /// Every turn made so far is closed.
        func allTurnsClosed() async -> Bool {
            for turn in turns.all where await turn.isOpen { return false }
            return true
        }
    }

    /// A pending action that records whether it ran.
    final class Action: Sendable {
        private let ran = Mutex(false)
        let result: String
        init(_ result: String) { self.result = result }
        var body: @Sendable () async throws -> String { { [self] in ran.withLock { $0 = true }; return result } }
        var didRun: Bool { ran.withLock { $0 } }
    }

    // MARK: - One turn at a time (D-10)

    @Test(.timeLimit(.minutes(1)))
    func secondSubmitIsBusyAndNotQueued() async throws {
        let hold = Hold()
        let rig = try Rig(hold: hold)
        defer { rig.harness.remove() }
        let first = Task { await rig.submit("first command") }
        await hold.waitUntilEntered()
        #expect(await rig.submit("second command", .text) == .busy)
        await hold.open()
        #expect(await first.value == .reply(Self.claudeReply))
        #expect(await rig.submit("third command") == .reply(Self.claudeReply))
        // The busy input never reached the brain, and no turn was made for it.
        #expect(await rig.claude.calls.map(\.user) == ["first command", "third command"])
        #expect(rig.turns.all.count == 2)
        #expect(await rig.allTurnsClosed())
    }

    // MARK: - Trim

    @Test func emptyInputDoesNothing() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        #expect(await rig.submit(" \n\t\u{85}\u{3000}") == .empty)
        #expect(rig.turns.all.isEmpty)
        #expect(rig.events.events.isEmpty)
        #expect(rig.online.count == 0)
    }

    @Test func inputIsTrimmedWithPythonWhitespace() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        _ = await rig.submit("\u{85} what time is it\u{3000}\n")
        #expect(await rig.claude.calls.map(\.user) == ["what time is it"])
    }

    // MARK: - Confirmation first

    @Test func confirmationIsConsumedBeforeTheRouter() async throws {
        let rig = try Rig(fastPath: "Fast reply, sir.")
        defer { rig.harness.remove() }
        let action = Action("Deleted, sir.")
        await rig.gate.stash(desc: Self.desc, action: action.body, turn: TurnContext(channel: .voice))
        #expect(await rig.submit("yes") == .confirmation("Deleted, sir."))
        #expect(action.didRun)
        #expect(await rig.sink.sentences == ["Deleted, sir."])
        // Neither the fast path nor the brain ran: no interactions bump, no brain call.
        #expect(await rig.fastPath.texts.isEmpty)
        #expect(rig.events.events.isEmpty)
        #expect(rig.online.count == 0)
        #expect(await rig.gate.pending == nil)
        #expect(await rig.allTurnsClosed())
    }

    @Test(arguments: [true, false])
    func textConfirmationAsksTheAuthenticator(_ approve: Bool) async throws {
        let rig = try Rig(authenticates: approve)
        defer { rig.harness.remove() }
        let action = Action("Deleted, sir.")
        await rig.gate.stash(desc: Self.desc, action: action.body, turn: TurnContext(channel: .text))
        let outcome = await rig.submit("confirm", .text)
        guard case .confirmation(let text) = outcome else {
            Issue.record("expected a confirmation outcome, got \(outcome)")
            return
        }
        #expect(await rig.auth.reasons == [Self.desc])
        #expect(action.didRun == approve)
        #expect((text == "Deleted, sir.") == approve)
        #expect(await rig.claude.calls.isEmpty)
    }

    @Test func voiceConfirmationNeverAsksTheAuthenticator() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        let action = Action("Deleted, sir.")
        await rig.gate.stash(desc: Self.desc, action: action.body, turn: TurnContext(channel: .voice))
        #expect(await rig.submit("do it") == .confirmation("Deleted, sir."))
        #expect(await rig.auth.reasons.isEmpty)
    }

    @Test func nonAffirmativeInputCancelsAndGoesOn() async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        let action = Action("Deleted, sir.")
        await rig.gate.stash(desc: Self.desc, action: action.body, turn: TurnContext(channel: .voice))
        #expect(await rig.submit("what time is it") == .reply(Self.claudeReply))
        #expect(!action.didRun)
        #expect(await rig.gate.pending == nil)
        #expect(await rig.claude.calls.count == 1)
    }

    // MARK: - Fast path, then the brain

    @Test func fastPathAnswersBeforeTheBrain() async throws {
        let rig = try Rig(fastPath: "Fast reply, sir.")
        defer { rig.harness.remove() }
        #expect(await rig.submit("what time is it") == .fastPath("Fast reply, sir."))
        #expect(await rig.fastPath.texts == ["what time is it"])
        #expect(await rig.sink.sentences == ["Fast reply, sir."])
        #expect(rig.events.events.isEmpty)
        #expect(rig.online.count == 0)
        #expect(await rig.allTurnsClosed())
    }

    @Test func noFastPathAnswerGoesToTheBrainWithTheChannel() async throws {
        let rig = try Rig(online: false)
        defer { rig.harness.remove() }
        #expect(await rig.submit("what time is it", .text) == .reply("Local reply, sir."))
        #expect(await rig.fastPath.texts == ["what time is it"])
        #expect(rig.online.count == 1)
        let call = try #require(await rig.local.calls.first)
        #expect(call.channel == .text)
        #expect(await rig.claude.calls.isEmpty)   // offline
    }

    // MARK: - The turn context

    @Test(arguments: [true, false])
    func pastedInputStartsATaintedTurn(_ pasted: Bool) async throws {
        let rig = try Rig()
        defer { rig.harness.remove() }
        _ = await rig.submit("what time is it", .text, pasted: pasted)
        let call = try #require(await rig.claude.calls.first)
        #expect(call.tainted == pasted)
        #expect(call.startedPasteTainted == pasted)
        #expect(call.turnWasOpen)
    }

    enum Path: String, CaseIterable, Sendable {
        case confirmation, fastPath, claude, local, failed
    }

    @Test(arguments: Path.allCases)
    func everyPathClosesItsTurn(_ path: Path) async throws {
        let disabled = ClaudeConfig(environment: ["JARVIS_USE_CLAUDE": "0"])
        let rig: Rig = switch path {
        case .confirmation, .claude: try Rig()
        case .fastPath: try Rig(fastPath: "Fast reply, sir.")
        case .local: try Rig(config: disabled)
        case .failed: try Rig(local: .failed("My local reasoning core had an error, sir."), config: disabled)
        }
        defer { rig.harness.remove() }
        if path == .confirmation {
            await rig.gate.stash(desc: Self.desc, action: Action("Deleted, sir.").body, turn: TurnContext(channel: .voice))
        }
        _ = await rig.submit(path == .confirmation ? "yes" : "what time is it")
        #expect(rig.turns.all.count == 1)
        #expect(await rig.allTurnsClosed())
    }
}
