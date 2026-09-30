import JarvisCore
import JarvisTools
import Synchronization
import Testing

@Suite("ToolGatewayTests")
struct ToolGatewayTests {
    @Test
    func dataSourceMapCoversAllPythonTools() async {
        #expect(DataSourceMap.toolNames.count == 46)
        #expect(DataSourceMap.allTools.count == 46)
        #expect(DataSourceMap.allTools == Set(DataSourceMap.toolNames))
        #expect(DataSourceMap.sources(for: "run_command") == [.system])
        #expect(DataSourceMap.sources(for: "summarize_page") == [.screen, .web])

        let turn = TurnContext(channel: .voice)
        for name in DataSourceMap.toolNames {
            await turn.recordSources(for: name)
        }
        let summary = await turn.summary()
        #expect(summary.dataSources == Set(DataSource.allCases))
    }

    // X-1: the run_command pre-guard uses ShellPolicy.strictVerdict, so a chain whose second
    // sudo is not allowlisted is blocked even though Python (and the M2 default) only confirm it.
    @Test
    func gatewayBlocksChainedDisallowedSudo() async {
        let logs = RecordingLog()
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: logs.sink)
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let cmd = "sudo pmset -g; sudo killall Finder"
        let result = await gateway.call("run_command", Self.args(("command", .string(cmd))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == GuardStrings.sudoNotAllowed)
        #expect(result.record.outcome == ToolRunRecord.Outcome.blockedGuard)
        #expect(logs.all == ["BLOCKED command: \(cmd)"])
    }

    // X-1: a dangerous command hidden in a substitution inside double quotes is blocked; the
    // M2/Python whole-line classifier only confirms it (\brm\b). Native segments the $().
    @Test
    func gatewayBlocksDangerousSubstitution() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string(#"foo "$(rm -rf /)""#))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == GuardStrings.systemDamaging)
        #expect(result.record.outcome == ToolRunRecord.Outcome.blockedGuard)
    }

    // X-4: a Keychain secret read is blocked; Python classifies it ok.
    @Test
    func gatewayBlocksKeychainSecretRead() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string("security find-generic-password -s jarvis"))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == GuardStrings.systemDamaging)
        #expect(result.record.outcome == ToolRunRecord.Outcome.blockedGuard)
    }

    // An allowlisted single sudo still only confirms (the strict policy does not over-block it).
    @Test
    func gatewayStillConfirmsAllowlistedSudo() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string("sudo pmset -g"))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == "That will run: sudo pmset -g, sir — say 'confirm' to proceed.")
        #expect(result.record.outcome == ToolRunRecord.Outcome.gated)
    }

    // A benign chain stays ok and reaches the (test) body.
    @Test
    func gatewayRunsBenignChain() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string("echo hi && ls -la"))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == "ran")
        #expect(result.record.outcome == ToolRunRecord.Outcome.ran)
    }

    @Test
    func taintBlocksExecutorsAfterUntrustedTool() async {
        let gateway = ToolGateway()
        await gateway.register(ReadTool())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let first = await gateway.call("web_search", JSONObject(), turn: turn, origin: .model(.local))
        #expect(first.record.outcome == .unknown) // no M5 body is registered yet

        await gateway.register(WebTool())
        _ = await gateway.call("web_search", JSONObject(), turn: turn, origin: .model(.local))
        let blocked = await gateway.call("run_command", Self.args(("command", .string("echo safe"))),
                                         turn: turn, origin: .model(.local))
        #expect(blocked.text == TaintPolicy.blockedTextLocal)
        #expect(blocked.record.outcome == ToolRunRecord.Outcome.blockedTaint)
    }

    @Test
    func taintUsesExactClaudeBlockedText() async {
        let gateway = ToolGateway()
        await gateway.register(WebTool())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)

        _ = await gateway.call("web_search", JSONObject(), turn: turn, origin: .model(.claude))
        let blocked = await gateway.call("run_command", Self.args(("command", .string("echo safe"))),
                                         turn: turn, origin: .model(.claude))

        #expect(blocked.text == TaintPolicy.blockedTextClaude)
        #expect(blocked.isError)
        #expect(blocked.record.outcome == ToolRunRecord.Outcome.blockedTaint)
    }

    @Test(arguments: [BackendKind.local, BackendKind.claude])
    func taintBlocksCatalogToolBeforeMissingBodyAndRecordsResearch(_ backend: BackendKind) async {
        let logs = RecordingLog()
        let counter = RecordingCounter()
        let gateway = ToolGateway(log: logs.sink, research: counter)
        let turn = TurnContext(channel: .voice, startTainted: true)

        let blocked = await gateway.call("run_command", Self.args(("command", .string("echo hi"))),
                                         turn: turn, origin: .model(backend))

        #expect(blocked.text == (backend == .claude ? TaintPolicy.blockedTextClaude : TaintPolicy.blockedTextLocal))
        #expect(blocked.record.outcome == ToolRunRecord.Outcome.blockedTaint)
        #expect(logs.all == ["BLOCKED run_command after untrusted-content ingestion (injection guard)"])
        #expect(counter.bumps == ["taint_block+1"])
    }

    @Test
    func staticGuardsRunBeforeMissingBodyAndUseExactBlockLogs() async {
        let logs = RecordingLog()
        let gateway = ToolGateway(log: logs.sink)
        let turn = TurnContext(channel: .voice)
        let command = String(repeating: "x", count: 140)

        let commandResult = await gateway.call(
            "run_command", Self.args(("command", .string("rm -rf / " + command))),
            turn: turn, origin: .model(.local))
        let scriptResult = await gateway.call(
            "run_applescript", Self.args(("script", .string("tell application \"System Events\" to keystroke \"x\""))),
            turn: turn, origin: .model(.local))

        #expect(commandResult.record.outcome == .blockedGuard)
        #expect(scriptResult.record.outcome == .blockedGuard)
        #expect(logs.all == [
            "BLOCKED command: \(String(("rm -rf / " + command).prefix(120)))",
            "BLOCKED dangerous AppleScript from LLM"
        ])
    }

    @Test
    func genuinelyUnknownToolStillReturnsUnknownBeforeGuards() async {
        let logs = RecordingLog()
        let counter = RecordingCounter()
        let gateway = ToolGateway(log: logs.sink, research: counter)
        let turn = TurnContext(channel: .voice, startTainted: true)

        let result = await gateway.call("not_a_jarvis_tool", JSONObject(), turn: turn,
                                        origin: .model(.local))

        #expect(result.text == "Unknown tool not_a_jarvis_tool")
        #expect(result.record.outcome == .unknown)
        #expect(logs.all.isEmpty)
        #expect(counter.bumps.isEmpty)
    }

    @Test
    func taintIsSetOnlyAfterUntrustedToolReturns() async {
        let gateway = ToolGateway()
        await gateway.register(SlowWebTool())
        let turn = TurnContext(channel: .voice)

        let task = Task {
            await gateway.call("web_search", JSONObject(), turn: turn, origin: .model(.local))
        }
        await Task.yield()
        #expect(await turn.tainted == false)
        _ = await task.value
        #expect(await turn.tainted)
    }

    @Test
    func concurrentCallsOnOneTurnAreFifoAndTaintBeforeExecutorCheck() async {
        let gateway = ToolGateway()
        await gateway.register(SlowWebTool())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)

        let web = Task {
            await gateway.call("web_search", JSONObject(), turn: turn, origin: .model(.local))
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
        let command = Task {
            await gateway.call("run_command", Self.args(("command", .string("echo safe"))),
                               turn: turn, origin: .model(.local))
        }

        _ = await web.value
        let commandResult = await command.value
        #expect(commandResult.text == TaintPolicy.blockedTextLocal)
        #expect(commandResult.record.outcome == ToolRunRecord.Outcome.blockedTaint)
    }

    @Test
    func closedTurnReturnsClosedText() async {
        let gateway = ToolGateway()
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        await turn.close()

        let result = await gateway.call("run_command", Self.args(("command", .string("echo safe"))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == "Turn closed.")
        #expect(result.isError)
        #expect(result.record.outcome == ToolRunRecord.Outcome.failed)
    }

    @Test
    func confirmationIsOneShotAndVoiceAuthenticatedByPort() async {
        let gate = ConfirmationGate()
        let gateway = ToolGateway(confirmationGate: gate)
        await gateway.register(ConfirmTool())
        let turn = TurnContext(channel: .voice)
        let pending = await gateway.call("write_file", JSONObject(), turn: turn, origin: .ui)
        #expect(pending.text == "That will do it, sir — say 'confirm' to proceed.")
        let consumed = await gate.consume("confirm", via: .voice, runIn: turn)
        #expect(consumed == .handled("done"))
        let second = await gate.consume("confirm", via: .voice, runIn: turn)
        #expect(second == .notHandled)
    }

    // Revocation check: a call whose turn is revoked while it waits behind another call in the
    // FIFO is blocked before its body runs. The barrier holds call A in flight (so A owns the
    // FIFO tail); B is enqueued only once A has entered, so B is provably queued behind A; the
    // live flag is flipped to false before B runs; releasing A lets B dequeue and refuse. No
    // wall-clock waits: ordering is a continuation handshake, not a sleep.
    @Test
    func revokedCallDoesNotRunBodyEvenWhenQueued() async {
        let barrier = Barrier()
        let ran = Flag()
        let live = LiveFlag(initial: true)
        let gateway = ToolGateway()
        await gateway.register(BarrierTool(barrier: barrier))
        await gateway.register(FlagCommandTool(ran: ran))
        let turn = TurnContext(channel: .voice)

        let a = Task { await gateway.call("get_time", JSONObject(), turn: turn, origin: .model(.local)) }
        await barrier.waitEntered()                     // A now holds the FIFO tail
        live.set(false)                                 // revoke before B is even queued
        let b = Task {
            await gateway.call("run_command", Self.args(("command", .string("echo hi"))),
                               turn: turn, origin: .model(.local), live: { live.get() })
        }
        await barrier.release()                         // release A; B dequeues next

        _ = await a.value
        let result = await b.value
        #expect(result.text == "Turn closed.")
        #expect(result.isError)
        #expect(result.record.outcome == ToolRunRecord.Outcome.failed)
        #expect(ran.value == false)                     // the body never ran
    }

    // A live check that stays true does not change behaviour: the body runs.
    @Test
    func liveCheckTrueRunsBodyNormally() async {
        let ran = Flag()
        let gateway = ToolGateway()
        await gateway.register(FlagCommandTool(ran: ran))
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string("echo hi"))),
                                        turn: turn, origin: .model(.local), live: { true })
        #expect(result.text == "ran")
        #expect(result.record.outcome == ToolRunRecord.Outcome.ran)
        #expect(ran.value)
    }

    private struct CommandTool: ToolImpl {
        static let name = "run_command"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("ran") }
    }

    private struct BarrierTool: ToolImpl {
        static let name = "get_time"
        static let schema = ToolSchema(name: name)
        let barrier: Barrier
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            await barrier.enter()
            return .text("time")
        }
    }

    private struct FlagCommandTool: ToolImpl {
        static let name = "run_command"
        static let schema = ToolSchema(name: name)
        let ran: Flag
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            ran.trip()
            return .text("ran")
        }
    }

    private struct ReadTool: ToolImpl {
        static let name = "read_file"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("read") }
    }

    private struct WebTool: ToolImpl {
        static let name = "web_search"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("web") }
    }

    private struct SlowWebTool: ToolImpl {
        static let name = "web_search"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            try? await Task.sleep(nanoseconds: 20_000_000)
            return .text("web")
        }
    }

    private struct ConfirmTool: ToolImpl {
        static let name = "write_file"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .needsConfirmation(desc: "That will do it") { "done" }
        }
    }

    private static func args(_ pairs: (String, JSONValue)...) -> JSONObject {
        JSONObject(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }
}

private final class RecordingLog: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }
}

private final class RecordingCounter: ResearchCounting {
    private let bumpsStorage = Mutex<[String]>([])

    var bumps: [String] { bumpsStorage.withLock { $0 } }

    func bump(_ key: String, by n: Int) {
        bumpsStorage.withLock { $0.append("\(key)+\(n)") }
    }
}

/// A two-way barrier with no wall-clock waits. The tool body calls `enter()`, which signals the
/// test (unblocking `waitEntered()`) and then blocks until the test calls `release()`. This lets
/// the test prove call A is in flight — and so owns the FIFO tail — before it enqueues call B.
private actor Barrier {
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var entered = false
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    /// Called by the tool body: announce entry, then wait to be released.
    func enter() async {
        entered = true
        if let w = enteredWaiter { enteredWaiter = nil; w.resume() }
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    /// Called by the test: return once the body has entered.
    func waitEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    /// Called by the test: let the body return.
    func release() {
        released = true
        if let w = releaseWaiter { releaseWaiter = nil; w.resume() }
    }
}

/// A write-once flag a tool body trips when it runs.
private final class Flag: Sendable {
    private let flag = Mutex(false)
    var value: Bool { flag.withLock { $0 } }
    func trip() { flag.withLock { $0 = true } }
}

/// The liveness the revocation check reads; the test flips it to false mid-flight.
private final class LiveFlag: Sendable {
    private let flag: Mutex<Bool>
    init(initial: Bool) { flag = Mutex(initial) }
    func get() -> Bool { flag.withLock { $0 } }
    func set(_ value: Bool) { flag.withLock { $0 = value } }
}
