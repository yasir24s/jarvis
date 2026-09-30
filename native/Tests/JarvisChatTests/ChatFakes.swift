import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import Synchronization

/// A coordinator stand-in: it records every input and runs a script that plays the brain's
/// side of the turn against the sink it was given.
actor FakeCoordinator: TurnSubmitting {
    typealias Script = @Sendable (UserInput, any ReplySink) async -> TurnOutcome

    private(set) var inputs: [UserInput] = []
    private let script: Script

    init(_ script: @escaping Script) {
        self.script = script
    }

    /// Answers every turn with `outcome` and sends nothing to the sink.
    init(answering outcome: TurnOutcome) {
        self.init { _, _ in outcome }
    }

    func submit(_ input: UserInput, sink: any ReplySink) async -> TurnOutcome {
        inputs.append(input)
        return await script(input, sink)
    }
}

/// Outcomes handed out one per turn, in order.
actor Outcomes {
    private var queue: [TurnOutcome]

    init(_ outcomes: [TurnOutcome]) {
        queue = outcomes
    }

    func next() -> TurnOutcome {
        queue.removeFirst()
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

/// Waits a millisecond at a time, for 2 s at most, until `condition` holds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}
