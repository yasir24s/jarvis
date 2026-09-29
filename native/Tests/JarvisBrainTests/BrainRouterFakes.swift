import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization

// Fakes for BrainRouterTests and TurnCoordinatorTests: both brains, the fast path, the
// authenticator, and a Sandbox-backed CoreState. Nothing here starts a process.

/// One ordered list that several fakes write to, so a test can check the call order.
final class EventLog: Sendable {
    private let state = Mutex<[String]>([])

    func add(_ event: String) { state.withLock { $0.append(event) } }
    var events: [String] { state.withLock { $0 } }
}

/// `ResearchCounting` that writes "bump <key>+<n>" to an EventLog.
final class EventCounter: ResearchCounting, Sendable {
    let log: EventLog
    init(_ log: EventLog) { self.log = log }
    func bump(_ key: String, by n: Int) { log.add("bump \(key)+\(n)") }
    var bumps: [String] { log.events.filter { $0.hasPrefix("bump ") } }
}

/// `BackendReporting` that writes "backend <name>" to an EventLog.
final class EventBackend: BackendReporting, Sendable {
    let log: EventLog
    init(_ log: EventLog) { self.log = log }
    func set(_ name: String) async { log.add("backend \(name)") }
}

/// Keeps a fake brain inside `generate` until `open()`; `waitUntilEntered()` returns once a
/// call is inside.
actor Hold {
    private var isOpen = false
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered = true
        for w in enteredWaiters { w.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// What a fake brain saw on one call. `tainted` is read at the start of the call.
struct BrainCall: Sendable {
    let system: String
    let user: String
    let channel: Channel
    let turn: TurnContext
    let tainted: Bool
    let startedPasteTainted: Bool
}

/// A Claude brain that records each call, sends `sentences` to the sink and returns `reply`.
actor FakeClaudeBrain: ClaudeGenerating {
    private(set) var calls: [BrainCall] = []
    private let reply: String?
    private let sentences: [String]
    private let events: EventLog?
    private let hold: Hold?

    init(reply: String?, sentences: [String] = [], events: EventLog? = nil, hold: Hold? = nil) {
        self.reply = reply
        self.sentences = sentences
        self.events = events
        self.hold = hold
    }

    func generate(system: String, user: String, turn: TurnContext, sink: any ReplySink) async -> String? {
        let channel = await turn.channel, pasted = await turn.startedPasteTainted, tainted = await turn.tainted
        calls.append(BrainCall(system: system, user: user, channel: channel, turn: turn,
                               tainted: tainted, startedPasteTainted: pasted))
        events?.add("claude")
        for s in sentences { await sink.sentence(s) }
        if let hold { await hold.enter() }
        return reply
    }
}

/// An on-device brain that records each call and returns `outcome`.
actor FakeLocalBrain: LocalGenerating {
    private(set) var calls: [BrainCall] = []
    private let outcome: LocalOutcome
    private let events: EventLog?

    init(_ outcome: LocalOutcome, events: EventLog? = nil) {
        self.outcome = outcome
        self.events = events
    }

    func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                  sink: any ReplySink) async -> LocalOutcome {
        let pasted = await turn.startedPasteTainted, tainted = await turn.tainted
        calls.append(BrainCall(system: system, user: user, channel: channel, turn: turn,
                               tainted: tainted, startedPasteTainted: pasted))
        events?.add("local")
        return outcome
    }
}

actor FakeFastPath: FastPathRouting {
    private(set) var texts: [String] = []
    private let reply: String?

    init(reply: String?) { self.reply = reply }

    func route(_ text: String, turn: TurnContext) async -> String? {
        texts.append(text)
        return reply
    }
}

actor FakeAuthenticator: ConfirmAuthenticator {
    private(set) var reasons: [String] = []
    private let answer: Bool

    init(answer: Bool) { self.answer = answer }

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        return answer
    }
}

struct FixedFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "Finder" }
}

/// A CoreState on its own Sandbox, at the rules' fixed epoch. Two harnesses made with the same
/// seed give the same `beginTurn` result, so one can serve as the other's oracle.
struct CoreHarness {
    static let epoch: Double = 1_790_582_400
    /// Two earlier turns, so the history preamble is not empty.
    static let seedHistory = #"[{"role": "user", "content": "Robin asked about the weather"}, {"role": "assistant", "content": "It is sunny, sir."}]"#

    let sandbox: Sandbox
    let store: StateStore
    let core: CoreState

    init(research: any ResearchCounting, files: [String: String] = ["history.json": CoreHarness.seedHistory]) throws {
        sandbox = try Sandbox()
        for (name, text) in files { try sandbox.write(name, text) }
        let clock = ManualClock(Self.epoch)
        store = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: nil, clock: clock)
        core = CoreState(store: store, clock: clock, research: research, frontApp: FixedFrontApp())
    }

    /// history.json as the store wrote it, or nil if it is missing.
    func historyFile() -> String? {
        try? sandbox.read("history.json")
    }

    func remove() { sandbox.remove() }
}

/// A ResearchCounting that drops everything (for oracles whose bumps do not matter).
final class NullCounter: ResearchCounting, Sendable {
    func bump(_ key: String, by n: Int) {}
}
