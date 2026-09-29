import JarvisBrain
import JarvisChat

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
