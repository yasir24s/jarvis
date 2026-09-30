import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import Synchronization

/// A coordinator stand-in: it records every input and runs a script that plays the brain's
/// side of the turn against the sink it was given. Like `TurnCoordinator`, it decides `.busy`
/// and `.empty` before it takes a turn, so `accepted` is called only for a turn that runs.
actor FakeCoordinator: TurnSubmitting {
    typealias Script = @Sendable (UserInput, any ReplySink) async -> TurnOutcome
    /// Asked before a turn is taken: `.busy` or `.empty` refuses it, nil runs it.
    typealias Refusal = @Sendable (UserInput) async -> TurnOutcome?

    private(set) var inputs: [UserInput] = []
    /// The context of each turn taken, in order.
    private(set) var turns: [TurnContext] = []
    private let refusal: Refusal
    private let script: Script

    init(refusing refusal: @escaping Refusal = { _ in nil }, _ script: @escaping Script) {
        self.refusal = refusal
        self.script = script
    }

    /// Answers every turn with `outcome` and sends nothing to the sink. `.busy` and `.empty`
    /// refuse the turn before it is taken.
    init(answering outcome: TurnOutcome) {
        let refused = Outcomes.isRefusal(outcome) ? outcome : nil
        self.init(refusing: { _ in refused }) { _, _ in outcome }
    }

    /// Hands out `outcomes` one per turn. A `.busy` or `.empty` one refuses its turn before it
    /// is taken.
    init(_ outcomes: Outcomes) {
        self.init(refusing: { _ in await outcomes.refusal() }) { _, _ in await outcomes.next() }
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        inputs.append(input)
        if let refused = await refusal(input) { return refused }
        let turn = TurnContext(channel: input.channel, startTainted: input.pasted)
        turns.append(turn)
        await accepted?(turn)
        let outcome = await script(input, sink)
        await turn.close()
        return outcome
    }
}

/// Outcomes handed out one per turn, in order.
actor Outcomes {
    private var queue: [TurnOutcome]

    init(_ outcomes: [TurnOutcome]) {
        queue = outcomes
    }

    static func isRefusal(_ outcome: TurnOutcome) -> Bool {
        outcome == .busy || outcome == .empty
    }

    func next() -> TurnOutcome {
        queue.removeFirst()
    }

    /// Takes the next outcome if it refuses the turn.
    func refusal() -> TurnOutcome? {
        guard let first = queue.first, Self.isRefusal(first) else { return nil }
        return queue.removeFirst()
    }
}

/// One value, set from any task.
actor Snapshot<Value: Sendable> {
    private(set) var value: Value?

    func set(_ newValue: Value) {
        value = newValue
    }
}

/// Holds a fake turn open so a test can look at the transcript mid-stream: the script parks,
/// the test waits until it has parked, looks, then opens the gate.
actor Gate {
    private var parked = false
    private var opened = false
    private var parkWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func park() async {
        parked = true
        for waiter in parkWaiters { waiter.resume() }
        parkWaiters = []
        guard !opened else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilParked() async {
        guard !parked else { return }
        await withCheckedContinuation { parkWaiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters = []
    }
}

/// A `TextConfirmAuthenticator` that never shows a system sheet. `available` is what
/// `canAuthenticate` says; `answer` is the owner check's result. It records each reason.
final class FakeTextAuthenticator: TextConfirmAuthenticator {
    let available: Bool
    let answer: Bool
    private let asked = Mutex<[String]>([])

    init(available: Bool = true, answer: Bool) {
        self.available = available
        self.answer = answer
    }

    var reasons: [String] { asked.withLock { $0 } }

    func canAuthenticate() -> Bool { available }

    func authenticate(reason: String) async -> Bool {
        asked.withLock { $0.append(reason) }
        return answer
    }
}

/// Research counters in memory.
final class ResearchRecorder: ResearchCounting {
    private let bumps = Mutex<[String: Int]>([:])

    var counts: [String: Int] { bumps.withLock { $0 } }

    func bump(_ key: String, by n: Int) {
        bumps.withLock { $0[key, default: 0] += n }
    }
}

/// Whether a confirmation's action ran.
actor ActionLog {
    private(set) var runs = 0

    func ran() {
        runs += 1
    }
}

/// A coordinator stand-in that does what `TurnCoordinator.submit` does with a pending
/// confirmation: it trims the input and offers it to the real gate through a text port with
/// `authenticator`. A handled input is sent to the sink as one sentence; anything else gets
/// `reply` from the brain.
func confirmingCoordinator(_ gate: ConfirmationGate, authenticator: any TextConfirmAuthenticator,
                           reply: String = "It is three o'clock, sir.") -> FakeCoordinator {
    FakeCoordinator { input, sink in
        let turn = TurnContext(channel: input.channel, startTainted: input.pasted)
        if case .handled(let result) = await gate.consume(Py.strip(input.text), via: .text(authenticator: authenticator),
                                                          runIn: turn) {
            if !result.isEmpty { await sink.sentence(result) }
            return .confirmation(result)
        }
        await sink.sentence(reply)
        return .reply(reply)
    }
}

/// Waits a millisecond at a time, 2000 times at most, until `condition` holds. The sleeps are
/// on the suspending clock, so a Mac asleep with its lid closed does not use the bound up.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1), clock: .suspending)
    }
    return condition()
}
