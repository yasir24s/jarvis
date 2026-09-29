import JarvisCore
import JarvisTools
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

    @Test
    func gatewayUsesPythonExactShellVerdicts() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", Self.args(("command", .string("sudo pmset -g; sudo killall Finder"))),
                                        turn: turn, origin: .model(.local))
        #expect(result.text == "That will run: sudo pmset -g; sudo killall Finder, sir — say 'confirm' to proceed.")
        #expect(result.record.outcome == ToolRunRecord.Outcome.gated)
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
        let pending = await gateway.call("confirm_me", JSONObject(), turn: turn, origin: .ui)
        #expect(pending.text == "That will do it, sir — say 'confirm' to proceed.")
        let consumed = await gate.consume("confirm", via: .voice, runIn: turn)
        #expect(consumed == .handled("done"))
        let second = await gate.consume("confirm", via: .voice, runIn: turn)
        #expect(second == .notHandled)
    }

    private struct CommandTool: ToolImpl {
        static let name = "run_command"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("ran") }
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
        static let name = "confirm_me"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .needsConfirmation(desc: "That will do it") { "done" }
        }
    }

    private static func args(_ pairs: (String, JSONValue)...) -> JSONObject {
        JSONObject(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
    }
}
