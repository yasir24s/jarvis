import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// T3.6 (plan M02-M04 §3.8 "LocalToolset.select", D-7): the budget rule with injected token
/// counts and context sizes, and DynamicTool's one path to a tool body, the gateway. No model.
/// With no ranker the rule offers CORE-21, D-7's fixed list as amended; the per-turn choice by
/// relevance has its own suite (`LocalToolRankerTests`).
@Suite("M3 local model: tool budget and DynamicTool")
struct LocalToolsetTests {
    /// D-7's list as T3.6 measured it, before web_search and search_memory replaced
    /// open_settings, list_shortcuts and get_wifi_status.
    static let measuredCore22 = [
        "get_time", "get_battery", "get_cpu_usage", "get_wifi_status", "set_volume",
        "set_brightness", "music_now_playing", "music_play", "music_control", "set_reminder",
        "set_alarm", "make_note", "get_calendar", "create_event", "find_apps", "open_settings",
        "system_control", "run_shortcut", "list_shortcuts", "notify", "find_files", "run_command",
    ]

    /// `schemas` as DynamicTools: by default what a local turn can be offered, 47 of them.
    static func catalogTools(_ turn: TurnContext = TurnContext(channel: .voice),
                             gateway: ToolGateway = localTestGateway(),
                             budget: LocalCallBudget = LocalCallBudget(),
                             schemas: [ToolSchema] = LocalToolset.catalog) -> [DynamicTool] {
        LocalToolset.dynamicTools(schemas, gateway: gateway, turn: turn, budget: budget, log: { _ in })
    }

    static func select(_ counter: FakeCounter, logs: LogRecorder = LogRecorder()) async -> LocalToolSelection {
        await LocalToolset.select(from: catalogTools(), instructions: "unused by FakeCounter",
                                  counter: counter, log: logs.function)
    }

    @Test("CORE-21 is D-7's list, with web_search and search_memory after get_time and three tools out")
    func core21() {
        let removed: Set = ["open_settings", "list_shortcuts", "get_wifi_status"]
        #expect(LocalToolset.core21.count == 21)
        #expect(Set(LocalToolset.core21).count == 21)
        #expect(Set(LocalToolset.core21).isSubset(of: Set(LocalToolset.catalog.map(\.name))))
        #expect(LocalToolset.core21.prefix(3) == ["get_time", "web_search", "search_memory"])
        #expect(Set(LocalToolset.core21).isDisjoint(with: removed))
        // Every other tool keeps D-7's order.
        #expect(Array(LocalToolset.core21.dropFirst(3))
                == Self.measuredCore22.filter { $0 != "get_time" && !removed.contains($0) })
        #expect(Self.measuredCore22.count == 22)
        #expect(Self.catalogTools().count == 47)
    }

    @Test("the catalog a local turn can be offered is Python's 46 and search_memory, which only P4 serves")
    func catalog() {
        let names = LocalToolset.catalog.map(\.name)
        #expect(names == ToolCatalog.tools.map(\.name) + ["search_memory"])
        #expect(Set(names).count == 47)
        // Without it a name in `pinned` or `core21` would be left out without a word.
        #expect(!DataSourceMap.allTools.contains("search_memory"))
        #expect(Set(LocalToolset.pinned).isSubset(of: Set(names)))
        #expect(LocalToolset.pinned == ["get_time", "web_search", "search_memory"])
    }

    @Test("all 47 when tools plus instructions fit in 0.6 × contextSize")
    func allFit() async {
        let logs = LogRecorder()
        // 47 × 50 + 1000 = 3350 ≤ 0.6 × 6000 = 3600
        let s = await Self.select(FakeCounter(contextSize: 6000, toolCost: 50, instructions: 1000), logs: logs)
        #expect(s.tier == .all)
        #expect(s.names == LocalToolset.catalog.map(\.name))
        #expect(s.allToolTokens == 2350)
        #expect(s.selectedToolTokens == 2350)
        #expect(s.instructionTokens == 1000)
        #expect(s.limit == 3600)
        #expect(s.dropped.isEmpty)
        #expect(logs.lines == ["Local model: contextSize 6000, limit 3600.0; instructions 1000 tokens; "
                               + "47 tools 2350 tokens; offering all: 47 tools, 2350 tokens"])
    }

    @Test("exactly at the limit still fits")
    func boundary() async {
        // 47 × 10 + 130 = 600 = 0.6 × 1000
        let fits = await Self.select(FakeCounter(contextSize: 1000, toolCost: 10, instructions: 130))
        #expect(fits.tier == .all)
        let over = await Self.select(FakeCounter(contextSize: 1000, toolCost: 10, instructions: 131))
        #expect(over.tier == .core21)
    }

    @Test("CORE-21, in D-7 order, when all 47 do not fit and there are no sentence vectors")
    func core21Fits() async {
        let logs = LogRecorder()
        // 47 × 50 + 1000 = 3350 > 2457.6; 21 × 50 + 1000 = 2050 ≤ 2457.6
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 1000), logs: logs)
        #expect(s.tier == .core21)
        #expect(s.names == LocalToolset.core21)
        #expect(s.allToolTokens == 2350)
        #expect(s.selectedToolTokens == 1050)
        #expect(s.dropped.isEmpty)
        #expect(logs.lines.count == 1)
        #expect(logs.lines.first?.hasSuffix("offering CORE-21: 21 tools, 1050 tokens") == true)
    }

    @Test("CORE-21 tools dropped from the tail until it fits, and the drop is logged")
    func tailDrop() async {
        let logs = LogRecorder()
        // 21 × 50 + 1500 = 2550 > 2457.6; two drops give 19 × 50 + 1500 = 2450
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 1500), logs: logs)
        #expect(s.tier == .core21Trimmed)
        #expect(s.dropped == ["run_command", "find_files"])
        #expect(s.names == Array(LocalToolset.core21.prefix(19)))
        #expect(s.selectedToolTokens == 950)
        #expect(logs.lines == ["Local model: contextSize 4096, limit 2457.6; instructions 1500 tokens; "
                               + "47 tools 2350 tokens; offering CORE-21 trimmed: 19 tools, 950 tokens; "
                               + "dropped run_command, find_files"])
    }

    @Test("per-tool counts decide the drop, not the tool count")
    func unevenCosts() async {
        // run_command alone is too big; dropping it is enough.
        let counter = FakeCounter(contextSize: 4096, toolCost: 20, perTool: ["run_command": 900],
                                  instructions: 1200)
        let s = await Self.select(counter)
        #expect(s.tier == .core21Trimmed)
        #expect(s.dropped == ["run_command"])
        #expect(s.tools.count == 20)
    }

    @Test("instructions alone over the limit leave no tools")
    func nothingFits() async {
        let s = await Self.select(FakeCounter(contextSize: 4096, toolCost: 50, instructions: 3000))
        #expect(s.tools.isEmpty)
        #expect(s.dropped == LocalToolset.core21.reversed())
    }

    @Test("a tokenizer failure falls back to the chars-per-token estimate, and says so")
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

    @Test("the estimate is Python len() ÷ chars per token, rounded up: 2.07 for tools, 3.5 for instructions")
    func estimate() throws {
        #expect(LocalToolset.toolCharsPerToken == 2.07)
        #expect(LocalToolset.instructionCharsPerToken == 3.5)
        #expect(LocalToolset.estimate(instructions: "") == 0)
        #expect(LocalToolset.estimate(instructions: "abcdefg") == 2)
        #expect(LocalToolset.estimate(instructions: "abcdefgh") == 3)
        #expect(LocalToolset.estimate(instructions: "—é") == 1)   // two code points
        let schema = try #require(ToolCatalog.tools.first { $0.name == "get_time" })
        let tool = try DynamicTool(schema: schema, gateway: localTestGateway(), turn: TurnContext(channel: .voice),
                                   budget: LocalCallBudget())
        let chars = schema.name.unicodeScalars.count + schema.description.unicodeScalars.count
            + schema.parametersJSON.unicodeScalars.count
        #expect(LocalToolset.estimate(tools: [tool]) == Int((Double(chars) / 2.07).rounded(.up)))
    }

    /// The live probe's tokenizer counts (macOS 27.2, T3.6): all 46 tools 4,790 tokens, the old
    /// CORE-22 2,430, and SYSTEM_PROMPT at 3,633 chars 963. The estimate is not below any of
    /// them. They are measurements of those 46 tools and of D-7's list before it was amended.
    @Test("the estimate does not undercount what the tokenizer measured")
    func estimateCoversMeasurement() {
        let tools = Self.catalogTools(schemas: ToolCatalog.tools)
        let core = Self.measuredCore22.compactMap { name in tools.first { $0.name == name } }
        #expect(tools.count == 46)
        #expect(core.count == 22)
        #expect(LocalToolset.estimate(tools: tools) >= 4790)
        #expect(LocalToolset.estimate(tools: core) >= 2430)
        #expect(LocalToolset.estimate(instructions: String(repeating: "a", count: 3633)) >= 963)
    }

    /// Below macOS 26.4 the context is 4096 and the counts are estimates. At 3.5 chars per
    /// token for tools, the old CORE-22 (1,440) plus SYSTEM_PROMPT (1,017) came to 2,457 and was
    /// judged to fit 0.6 × 4096 = 2,457.6, though the tokenizer counts 2,430 for CORE-22 alone.
    @Test("below macOS 26.4, CORE-21 plus SYSTEM_PROMPT is not judged to fit 4096")
    func estimatedCore21DoesNotFit4096() async {
        let logs = LogRecorder()
        // A 35-character changelog path, as long as the production one.
        let prompt = SystemPrompt.base(changelogPath: "/private/tmp/jarvis-xy/CHANGELOG.md")
        let s = await LocalToolset.select(from: Self.catalogTools(), instructions: prompt,
                                          counter: EstimatingCounter(), log: logs.function)
        #expect(s.estimated)
        #expect(s.tier == .core21Trimmed)
        #expect(!s.dropped.isEmpty)
        #expect(Double(s.selectedToolTokens + s.instructionTokens) <= s.limit)
        #expect(logs.lines.last?.hasSuffix("(estimated: tools chars/2.07, instructions chars/3.5)") == true)
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
