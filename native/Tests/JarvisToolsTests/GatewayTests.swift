import JarvisTools
import Testing

@Suite("M2 tool gateway")
struct GatewayTests {
    @Test
    func dataSourceMapCoversAllPythonTools() async {
        #expect(DataSourceMap.toolNames.count == 46)
        #expect(DataSourceMap.allTools.count == 46)
        #expect(DataSourceMap.sources(for: "run_command") == [.system])
        #expect(DataSourceMap.sources(for: "summarize_page") == [.screen, .web])
    }

    @Test
    func gatewayUsesPythonExactShellVerdicts() async {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call("run_command", ["command": .string("sudo pmset -g; sudo killall Finder")],
                                        turn: turn, origin: .model(.local))
        #expect(result.text == "That will run: sudo pmset -g; sudo killall Finder, sir — say 'confirm' to proceed.")
        #expect(result.record.outcome == .gated)
    }

    @Test
    func taintBlocksExecutorsAfterUntrustedTool() async {
        let gateway = ToolGateway()
        await gateway.register(ReadTool())
        await gateway.register(CommandTool())
        let turn = TurnContext(channel: .voice)
        let first = await gateway.call("web_search", [:], turn: turn, origin: .model(.local))
        #expect(first.record.outcome == .unknown) // no M5 body is registered yet

        await gateway.register(WebTool())
        _ = await gateway.call("web_search", [:], turn: turn, origin: .model(.local))
        let blocked = await gateway.call("run_command", ["command": .string("echo safe")],
                                         turn: turn, origin: .model(.local))
        #expect(blocked.text == TaintText.local)
        #expect(blocked.record.outcome == .blockedTaint)
    }

    @Test
    func confirmationIsOneShotAndVoiceAuthenticatedByPort() async {
        let gate = ConfirmationGate()
        let gateway = ToolGateway(confirmationGate: gate)
        await gateway.register(ConfirmTool())
        let turn = TurnContext(channel: .voice)
        let pending = await gateway.call("confirm_me", [:], turn: turn, origin: .ui)
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

    private struct ConfirmTool: ToolImpl {
        static let name = "confirm_me"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .needsConfirmation(desc: "That will do it") { "done" }
        }
    }

    private enum TaintText {
        static let local = "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content (web, screen, clipboard, files) in the same request."
    }
}
