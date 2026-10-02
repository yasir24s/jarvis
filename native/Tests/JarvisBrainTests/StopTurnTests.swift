import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// A flag any task can set and read.
final class Flag: Sendable {
    private let state = Mutex(false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}

/// Returns once the calling task is cancelled (or after `limit`, so a test cannot hang).
func waitForCancellation(limit: Duration = .seconds(10)) async {
    let start = ContinuousClock.now
    while !Task.isCancelled && ContinuousClock.now - start < limit {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// A Claude stand-in for Stop: it streams `shown`, runs `before` (a tool call, say), notes that
/// it is inside, then waits to be cancelled. Cancelled, it runs `after` and returns what a
/// cancelled ClaudeDriver returns on the text channel: what it had shown, or nil for nothing.
actor StoppableClaude: ClaudeGenerating {
    private(set) var users: [String] = []
    private(set) var systems: [String] = []
    let shown: String
    let entered = Flag()
    private let before: @Sendable (TurnContext) async -> Void
    private let after: @Sendable (TurnContext) async -> Void
    private let finishes: [String]

    /// `finishes` are the replies of later calls, which return at once.
    init(shown: String, finishes: [String] = [],
         before: @escaping @Sendable (TurnContext) async -> Void = { _ in },
         after: @escaping @Sendable (TurnContext) async -> Void = { _ in }) {
        self.shown = shown
        self.finishes = finishes
        self.before = before
        self.after = after
    }

    func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
        users.append(user)
        systems.append(system)
        if users.count > 1 {
            let reply = finishes[min(users.count - 2, finishes.count - 1)]
            await sink.delta(reply)
            return reply
        }
        if !shown.isEmpty { await sink.delta(shown) }
        await before(turn)
        entered.set()
        await waitForCancellation()
        await after(turn)
        await sink.delta(" and more after the stop")
        await sink.sentence("A sentence after the stop.")
        return shown.isEmpty ? nil : shown
    }
}

/// An on-device stand-in that behaves as LocalBrain does when cancelled: what it streamed is
/// lost to it, and it sends its error line and fails.
actor StoppableLocal: LocalGenerating {
    let entered = Flag()
    private(set) var calls = 0
    let streamed: String

    init(streamed: String) {
        self.streamed = streamed
    }

    func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                  sink: any ReplySink) async -> LocalOutcome {
        calls += 1
        await sink.delta(streamed)
        entered.set()
        await waitForCancellation()
        await sink.sentence(LocalBrain.errorReply)
        return .failed(LocalBrain.errorReply)
    }
}

/// A sink that records everything it is sent.
final class SinkLog: ReplySink {
    private let state = Mutex<[String]>([])
    var events: [String] { state.withLock { $0 } }
    func sentence(_ text: String) async { state.withLock { $0.append("sentence \(text)") } }
    func delta(_ text: String) async { state.withLock { $0.append("delta \(text)") } }
    func retracted(messageID: String) async { state.withLock { $0.append("retracted \(messageID)") } }
}

/// A confirm-tier tool whose action sets a flag: if the flag is ever set, a gated tool ran.
struct GatedWrite: ToolImpl {
    static let name = "write_file"
    static let schema = ToolSchema(name: name)
    let ran: Flag

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let ran = self.ran
        return .needsConfirmation(desc: "write the file") {
            ran.set()
            return "written"
        }
    }
}

/// A plain tool that sets a flag when it runs.
struct FlagRead: ToolImpl {
    static let name = "read_file"
    static let schema = ToolSchema(name: name)
    let ran: Flag

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        ran.set()
        return .text("contents")
    }
}

func until(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2000 where !(await condition()) {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// UI1 part 4: Stop at the brain. A stopped turn ends where it is, never falls back to the
/// local model, keeps what was shown as the history's reply, runs no tool and no stashed
/// confirmation after the stop, and sends nothing more to the sink. A message added while he
/// replied reaches the brains labelled, with the stopped exchange in its history.
@Suite("UI1 stop at the brain", .serialized)
struct StopTurnTests {
    static let enabled = ClaudeConfig(environment: [:])
    static let disabled = ClaudeConfig(environment: ["JARVIS_USE_CLAUDE": "0"])

    static func router(_ harness: CoreHarness, claude: any ClaudeGenerating, local: any LocalGenerating,
                       config: ClaudeConfig = enabled) -> BrainRouter {
        BrainRouter(core: harness.core, config: config, claude: claude, local: local,
                    backend: EventBackend(EventLog()), research: NullCounter(), log: { _ in })
    }

    @Test func stoppedClaudeTurnKeepsWhatWasShownAndNeverFallsBack() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let claude = StoppableClaude(shown: "The first half of")
        let local = FakeLocalBrain(.reply("Local reply, sir."))
        let router = Self.router(harness, claude: claude, local: local)
        let sink = SinkLog()
        let task = Task {
            await router.process("explain the plan", online: true, channel: .text,
                                 turn: TurnContext(channel: .text), sink: sink)
        }
        await until { claude.entered.isSet }
        task.cancel()
        let reply = await task.value
        #expect(reply == "The first half of")
        #expect(await local.calls.isEmpty)
        #expect(sink.events == ["delta The first half of"])   // nothing after the stop
        let saved = try Self.saved(harness)
        #expect(saved.suffix(2) == [Self.turn("user", "explain the plan"), Self.turn("assistant", "The first half of")])
    }

    @Test func stoppedBeforeAnythingShowsKeepsAnEmptyReply() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let claude = StoppableClaude(shown: "")
        let local = FakeLocalBrain(.reply("Local reply, sir."))
        let router = Self.router(harness, claude: claude, local: local)
        let task = Task {
            await router.process("explain the plan", online: true, channel: .text,
                                 turn: TurnContext(channel: .text), sink: SinkLog())
        }
        await until { claude.entered.isSet }
        task.cancel()
        #expect(await task.value == "")
        #expect(await local.calls.isEmpty)
        let saved = try Self.saved(harness)
        #expect(saved.suffix(2) == [Self.turn("user", "explain the plan"), Self.turn("assistant", "")])
    }

    @Test func stoppedLocalTurnKeepsWhatItStreamedAndDropsItsErrorLine() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let local = StoppableLocal(streamed: "Half an answer")
        let router = Self.router(harness, claude: FakeClaudeBrain(reply: "unused"), local: local, config: Self.disabled)
        let sink = SinkLog()
        let task = Task {
            await router.process("explain the plan", online: true, channel: .text,
                                 turn: TurnContext(channel: .text), sink: sink)
        }
        await until { local.entered.isSet }
        task.cancel()
        #expect(await task.value == "Half an answer")
        #expect(sink.events == ["delta Half an answer"])   // the error line is neither shown nor spoken
        let saved = try Self.saved(harness)
        // Not popped, as a failed turn would be: the user's message and the partial reply stay.
        #expect(saved.suffix(2) == [Self.turn("user", "explain the plan"), Self.turn("assistant", "Half an answer")])
    }

    /// The message added while he replied: the brain gets it labelled, with the user's earlier
    /// message and the partial reply in the history before it; history keeps it as typed.
    @Test func addedContextReachesTheBrainLabelledAfterThePartialReply() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let claude = StoppableClaude(shown: "Flights to Rome start at", finishes: ["In euros, sir: from 89."])
        let router = Self.router(harness, claude: claude, local: FakeLocalBrain(.reply("unused")))
        let first = Task {
            await router.process("find flights to Rome", online: true, channel: .text,
                                 turn: TurnContext(channel: .text), sink: SinkLog())
        }
        await until { claude.entered.isSet }
        first.cancel()
        _ = await first.value
        let reply = await router.process("in euros please", online: true, channel: .text,
                                         turn: TurnContext(channel: .text), sink: SinkLog(), addsContext: true)
        #expect(reply == "In euros, sir: from 89.")
        let users = await claude.users
        #expect(users == ["find flights to Rome", BrainRouter.addedContext("in euros please")])
        #expect(BrainRouter.addedContext("in euros please").hasSuffix("\nin euros please"))
        let system = try #require(await claude.systems.last)
        #expect(system.contains("User: find flights to Rome\nYou: Flights to Rome start at"))
        let saved = try Self.saved(harness)
        #expect(saved.suffix(4) == [Self.turn("user", "find flights to Rome"),
                                    Self.turn("assistant", "Flights to Rome start at"),
                                    Self.turn("user", "in euros please"),
                                    Self.turn("assistant", "In euros, sir: from 89.")])
    }

    /// Through the coordinator: the confirmation the stopped turn stashed is dropped, so a
    /// "confirm" after the stop runs nothing; a tool the stopped turn calls after the stop is
    /// refused before it runs; the local model is never asked.
    @Test func aStoppedTurnRunsNoGatedToolAndNoToolAfterTheStop() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let gate = ConfirmationGate()
        let gateway = ToolGateway(confirmationGate: gate, log: { _ in })
        let wrote = Flag(), read = Flag()
        await gateway.register(GatedWrite(ran: wrote))
        await gateway.register(FlagRead(ran: read))
        let lateResult = Mutex<String?>(nil)
        let claude = StoppableClaude(shown: "I'll write that file", finishes: ["Confirm what, sir?"], before: { turn in
            _ = await gateway.call("write_file", JSONObject(), turn: turn, origin: .model(.claude))
        }, after: { turn in
            // A call that arrives once the stop has landed: the turn is closed.
            await until { await !turn.isOpen }
            let result = await gateway.call("read_file", JSONObject(), turn: turn, origin: .model(.claude))
            lateResult.withLock { $0 = result.text }
        })
        let local = FakeLocalBrain(.reply("Local reply, sir."))
        let coordinator = TurnCoordinator(brain: Self.router(harness, claude: claude, local: local), confirmations: gate,
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { true })
        let sink = SinkLog()
        let task = Task {
            await coordinator.submit(UserInput(text: "write the file", channel: .text), sink: sink)
        }
        await until { claude.entered.isSet }
        #expect(await gate.pending != nil)   // stashed while the turn ran
        task.cancel()
        #expect(await task.value == .reply("I'll write that file"))
        #expect(await gate.pending == nil)   // dropped with the stop
        #expect(lateResult.withLock { $0 } == "Turn closed.")
        #expect(!read.isSet)
        #expect(await local.calls.isEmpty)
        #expect(sink.events == ["delta I'll write that file"])

        // "confirm" now finds nothing to confirm: it goes to the brain, and the write never runs.
        let next = await coordinator.submit(UserInput(text: "confirm", channel: .text), sink: SinkLog())
        #expect(next == .reply("Confirm what, sir?"))
        #expect(!wrote.isSet)
    }

    /// history.json as saved, parsed.
    static func saved(_ harness: CoreHarness) throws -> [JSONValue] {
        let text = try #require(harness.historyFile())
        return try #require(PyJSON.loads(Data(text.utf8)).arrayValue)
    }

    static func turn(_ role: String, _ content: String) -> JSONValue {
        .object(JSONObject([.init(key: "role", value: .string(role)), .init(key: "content", value: .string(content))]))
    }
}
