import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// T3.6 (plan M02-M04 §3.8 "LocalToolset.select", D-7): the budget rule with injected token
/// counts and context sizes, and DynamicTool's one path to a tool body, the gateway. No model.
@Suite("M3 local model: tool budget and DynamicTool")
struct LocalToolsetTests {
    static func catalogTools(_ turn: TurnContext = TurnContext(channel: .voice),
                             gateway: ToolGateway = localTestGateway(),
                             budget: LocalCallBudget = LocalCallBudget()) -> [DynamicTool] {
        LocalToolset.dynamicTools(ToolCatalog.tools, gateway: gateway, turn: turn, budget: budget,
                                  log: { _ in })
    }

    static func select(_ counter: FakeCounter, logs: LogRecorder = LogRecorder()) async -> LocalToolSelection {
        await LocalToolset.select(from: catalogTools(), instructions: "unused by FakeCounter",
                                  counter: counter, log: logs.function)
    }

    @Test("CORE-22 is 22 distinct catalog tools")
    func core22() {
        #expect(LocalToolset.core22.count == 22)
        #expect(Set(LocalToolset.core22).count == 22)
        #expect(Set(LocalToolset.core22).isSubset(of: DataSourceMap.allTools))
        #expect(Self.catalogTools().count == 46)
    }

    @Test("all 46 when tools plus instructions fit in 0.6 × contextSize")
    func allFit() async {
        let logs = LogRecorder()
        // 46 × 50 + 1000 = 3300 ≤ 0.6 × 6000 = 3600
        let s = await Self.select(FakeCounter(contextSize: 6000, toolCost: 50, instructions: 1000), logs: logs)
        #expect(s.tier == .all)
        #expect(s.names == DataSourceMap.toolNames)
        #expect(s.allToolTokens == 2300)
        #expect(s.selectedToolTokens == 2300)
        #expect(s.instructionTokens == 1000)
        #expect(s.limit == 3600)
        #expect(s.dropped.isEmpty)
        #expect(logs.lines == ["Local model: contextSize 6000, limit 3600.0; instructions 1000 tokens; "
                               + "46 tools 2300 tokens; offering all: 46 tools, 2300 tokens"])
    }

    @Test("exactly at the limit still fits")
    func boundary() async {
        // 46 × 10 + 140 = 600 = 0.6 × 1000
        let fits = await Self.select(FakeCounter(contextSize: 1000, toolCost: 10, instructions: 140))
        #expect(fits.tier == .all)
        let over = await Self.select(FakeCounter(contextSize: 1000, toolCost: 10, instructions: 141))
        #expect(over.tier == .core22)
    }

    @Test("CORE-22, in D-7 order, when all 46 do not fit")
    func core22Fits() async {
        let logs = LogRecorder()
        // 46 × 50 + 1000 = 3300 > 2457.6; 22 × 50 + 1000 = 2100 ≤ 2457.6
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 1000), logs: logs)
        #expect(s.tier == .core22)
        #expect(s.names == LocalToolset.core22)
        #expect(s.allToolTokens == 2300)
        #expect(s.selectedToolTokens == 1100)
        #expect(s.dropped.isEmpty)
        #expect(logs.lines.count == 1)
        #expect(logs.lines.first?.hasSuffix("offering CORE-22: 22 tools, 1100 tokens") == true)
    }

    @Test("CORE-22 tools dropped from the tail until it fits, and the drop is logged")
    func tailDrop() async {
        let logs = LogRecorder()
        // 22 × 50 + 1500 = 2600 > 2457.6; three drops give 19 × 50 + 1500 = 2450
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 1500), logs: logs)
        #expect(s.tier == .core22Trimmed)
        #expect(s.dropped == ["run_command", "find_files", "notify"])
        #expect(s.names == Array(LocalToolset.core22.prefix(19)))
        #expect(s.selectedToolTokens == 950)
        #expect(logs.lines == ["Local model: contextSize 4096, limit 2457.6; instructions 1500 tokens; "
                               + "46 tools 2300 tokens; offering CORE-22 trimmed: 19 tools, 950 tokens; "
                               + "dropped run_command, find_files, notify"])
    }

    @Test("per-tool counts decide the drop, not the tool count")
    func unevenCosts() async {
        // run_command alone is too big; dropping it is enough.
        let counter = FakeCounter(contextSize: 4096, toolCost: 20, perTool: ["run_command": 900],
                                  instructions: 1200)
        let s = await Self.select(counter)
        #expect(s.tier == .core22Trimmed)
        #expect(s.dropped == ["run_command"])
        #expect(s.tools.count == 21)
    }

    @Test("instructions alone over the limit leave no tools")
    func nothingFits() async {
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 3000))
        #expect(s.tools.isEmpty)
        #expect(s.dropped == LocalToolset.core22.reversed())
    }

    @Test("a tokenizer failure falls back to chars ÷ 3.5, and says so")
    func countFailure() async {
        let logs = LogRecorder()
        let tools = Self.catalogTools()
        let instructions = String(repeating: "a", count: 700)
        let s = await LocalToolset.select(from: tools, instructions: instructions,
                                          counter: FakeCounter(contextSize: 100_000, failing: true),
                                          log: logs.function)
        #expect(s.instructionTokens == 200)
        #expect(s.allToolTokens == LocalToolset.estimate(tools: tools))
        #expect(s.tier == .all)
        #expect(logs.lines.filter { $0.hasPrefix("Local model: token count failed") }.count == 2)
    }

    @Test("the estimate is Python len() ÷ 3.5, rounded up")
    func estimate() throws {
        #expect(LocalToolset.estimate(instructions: "") == 0)
        #expect(LocalToolset.estimate(instructions: "abcdefg") == 2)
        #expect(LocalToolset.estimate(instructions: "abcdefgh") == 3)
        #expect(LocalToolset.estimate(instructions: "—é") == 1)   // two code points
        let schema = try #require(ToolCatalog.tools.first { $0.name == "get_time" })
        let tool = try DynamicTool(schema: schema, gateway: localTestGateway(), turn: TurnContext(channel: .voice),
                                   budget: LocalCallBudget())
        let chars = schema.name.unicodeScalars.count + schema.description.unicodeScalars.count
            + schema.parametersJSON.unicodeScalars.count
        #expect(LocalToolset.estimate(tools: [tool]) == Int((Double(chars) / 3.5).rounded(.up)))
    }

    // MARK: - DynamicTool

    @Test("a call reaches the body through the gateway, as .model(.local)")
    func callGoesThroughGateway() async throws {
        let gateway = localTestGateway()
        let calls = RecordingBody.Calls()
        let schema = try #require(ToolCatalog.tools.first { $0.name == "set_volume" })
        await gateway.register(RecordingBody(calls: calls), schema: schema)
        let turn = TurnContext(channel: .voice)
        let tool = try DynamicTool(schema: schema, gateway: gateway, turn: turn, budget: LocalCallBudget())

        let out = try await tool.call(arguments: GeneratedContent(json: #"{"level": 30}"#))
        #expect(out == "Volume set, sir.")
        #expect(calls.args == [JSONObject([.init(key: "level", value: .int(30))])])
        #expect(calls.origins == [.model(.local)])
        let runs = await turn.summary().toolRuns
        #expect(runs == [ToolRunRecord(name: "set_volume", origin: .model(.local), outcome: .ran)])
    }

    @Test("a tool with no body yet answers with the gateway's text")
    func noBody() async throws {
        let turn = TurnContext(channel: .voice)
        let tool = try #require(Self.catalogTools(turn).first { $0.name == "get_time" })
        let out = try await tool.call(arguments: GeneratedContent(json: "{}"))
        #expect(out == GuardStrings.unknownTool("get_time"))
        #expect(await turn.summary().toolRuns.map(\.origin) == [.model(.local)])
    }

    @Test("the gateway's taint guard applies, with the local model's wording")
    func taint() async throws {
        let turn = TurnContext(channel: .voice, startTainted: true)
        let tool = try #require(Self.catalogTools(turn).first { $0.name == "run_command" })
        let out = try await tool.call(arguments: GeneratedContent(json: #"{"command": "echo hi"}"#))
        #expect(out == TaintPolicy.blockedTextLocal)
        #expect(await turn.summary().toolRuns.map(\.outcome) == [.blockedTaint])
    }

    @Test("arguments that are not a JSON object reach the body as {}")
    func nonObjectArguments() async throws {
        let gateway = localTestGateway()
        let calls = RecordingBody.Calls()
        let schema = try #require(ToolCatalog.tools.first { $0.name == "set_volume" })
        await gateway.register(RecordingBody(calls: calls), schema: schema)
        let tool = try DynamicTool(schema: schema, gateway: gateway, turn: TurnContext(channel: .voice),
                                   budget: LocalCallBudget())
        _ = try await tool.call(arguments: GeneratedContent(json: "[1, 2]"))
        #expect(calls.args == [JSONObject()])
    }

    @Test("the eleventh call in a turn is refused before the gateway")
    func callLimit() async throws {
        let gateway = localTestGateway()
        let calls = RecordingBody.Calls()
        let schema = try #require(ToolCatalog.tools.first { $0.name == "set_volume" })
        await gateway.register(RecordingBody(calls: calls), schema: schema)
        let budget = LocalCallBudget()
        let tool = try DynamicTool(schema: schema, gateway: gateway, turn: TurnContext(channel: .voice),
                                   budget: budget)
        for _ in 0..<10 {
            _ = try await tool.call(arguments: GeneratedContent(json: #"{"level": 5}"#))
        }
        #expect(!budget.exceeded)
        await #expect(throws: LocalCallBudget.LimitExceeded()) {
            try await tool.call(arguments: GeneratedContent(json: #"{"level": 5}"#))
        }
        #expect(budget.exceeded)
        #expect(budget.calls == 11)
        #expect(calls.args.count == 10)
    }
}
