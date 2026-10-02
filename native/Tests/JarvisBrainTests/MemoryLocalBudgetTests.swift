import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// MEM1 part 1: the on-device memory block is sized for the model's real context (200 tokens at
/// 4,096, 400 at 8,192), and L2's budget still fits the tools around it.
@Suite("MEM1 part 1: the on-device memory block scales with the context")
struct MemoryLocalBudgetTests {
    @Test func theBudgetScalesWithTheContext() {
        #expect(MemoryRecall.localBudget(contextSize: 4096) == 200)
        #expect(MemoryRecall.localBudget(contextSize: 8192) == 400)
        #expect(MemoryRecall.localBudget(contextSize: 2048) == 100)
        #expect(MemoryRecall.localBudget(contextSize: 1_000_000) == MemoryRecall.claudeBudget)
        #expect(MemoryRecall.localBudget(contextSize: 0) == MemoryRecall.localBudget)
        #expect(MemoryRecall.localBudget == 200 && MemoryRecall.referenceContextSize == 4096)
    }

    /// An on-device brain that reports its context size.
    struct SizedLocal: LocalGenerating {
        let inner: FakeLocalBrain
        let size: Int
        func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                      sink: any ReplySink) async -> LocalOutcome {
            await inner.generate(system: system, user: user, channel: channel, turn: turn, sink: sink)
        }

        var contextSize: Int { get async { size } }
    }

    /// The local system prompt for "zebra?" with 40 facts of 100 bytes that all match it, from a
    /// local brain whose context holds `size` tokens.
    static func localPrompt(contextSize size: Int) async throws -> String {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let memory = MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch), timeZone: MemoryRecallTests.utc)
        var table: [String: [Double]] = ["zebra?": [1, 0]]
        let facts = (0..<40).map { i -> MemoryFact in
            let text = "The user fact " + String(format: "%02d", i) + " " + String(repeating: "y", count: 83)
            table[text] = [1, 0]
            return MemoryRecallTests.fact(i, text)
        }
        MemoryRecallTests.store(facts, in: memory)
        let local = FakeLocalBrain(.reply("Local reply, sir."))
        let router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: ["JARVIS_USE_CLAUDE": "0"]),
                                 claude: FakeClaudeBrain(reply: nil), local: SizedLocal(inner: local, size: size),
                                 backend: EventBackend(EventLog()), research: NullCounter(),
                                 recall: MemoryRecall(memory: memory,
                                                      vectors: FactVectors(embedding: MemoryRecallTests.TableEmbedding(table))),
                                 log: { _ in })
        _ = await router.process("zebra?", online: true, channel: .voice, turn: TurnContext(channel: .voice),
                                 sink: RecordingSink())
        return try #require(await local.calls.first).system
    }

    static func memoryBlock(in prompt: String) -> String {
        guard let start = prompt.range(of: MemoryRecall.localHeader) else { return "" }
        let block = prompt[start.lowerBound...]
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        // The header's two leading newlines, the header line, then the "- " fact lines.
        var kept = ["", "", String(lines[2])]
        for line in lines.dropFirst(3) {
            guard line.hasPrefix("- ") else { break }
            kept.append(String(line))
        }
        return kept.joined(separator: "\n")
    }

    @Test func theRouterSizesTheLocalBlockForTheModelsContext() async throws {
        let small = Self.memoryBlock(in: try await Self.localPrompt(contextSize: 4096))
        let large = Self.memoryBlock(in: try await Self.localPrompt(contextSize: 8192))
        #expect(MemoryRecall.estimatedTokens(small) <= 200 && MemoryRecall.estimatedTokens(small) > 150)
        #expect(MemoryRecall.estimatedTokens(large) <= 400 && MemoryRecall.estimatedTokens(large) > 350)
        let smallFacts = small.components(separatedBy: "\n- ").count - 1
        let largeFacts = large.components(separatedBy: "\n- ").count - 1
        #expect(largeFacts >= 2 * smallFacts - 1, "\(smallFacts) facts at 4,096, \(largeFacts) at 8,192")
    }

    /// L2's rule counts the memory block with the instructions, so a larger block can only
    /// leave fewer tools, never overrun the limit. With T3.6's measured sizes (SYSTEM_PROMPT 963
    /// tokens, about 104 a tool): at 4,096 CORE-21 must be trimmed even with the 200-token block,
    /// at 8,192 all 21 fit with the 400-token block, with the pinned tools always in.
    @Test func lTwosBudgetStillFitsTheToolsAroundTheBlock() async throws {
        let tools = LocalToolsetTests.catalogTools()
        for (size, memory) in [(4096, 213), (8192, 425)] {
            let counter = FakeCounter(contextSize: size, toolCost: 104, instructions: 963 + memory)
            let selection = await LocalToolset.select(from: tools, instructions: "x", counter: counter, log: { _ in })
            #expect(Double(selection.instructionTokens + selection.selectedToolTokens) <= selection.limit)
            #expect(LocalToolset.pinned.allSatisfy { name in selection.names.contains(name) }, "\(size)")
            if size == 8192 {
                #expect(selection.tier == .core21 && selection.tools.count == LocalToolset.core21.count)
            } else {
                #expect(selection.tier == .core21Trimmed)
            }
        }
    }

    /// The real numbers, gated (JARVIS_LIVE_LOCAL=1): the model's context, the budgets, and the
    /// block's and the tools' token counts with the OS tokenizer.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JARVIS_LIVE_LOCAL"] == "1"))
    func realNumbers() async throws {
        let model = SystemLanguageModel.default
        let size = model.contextSize
        let budget = MemoryRecall.localBudget(contextSize: size)
        let facts = (0..<40).map { MemoryRecallTests.fact($0, "The user's sister Ana lives in Lisbon and teaches piano " + String($0) + ".") }
        let block = MemoryRecall.block(facts, budget: budget, header: MemoryRecall.localHeader)
        print("MEM1 contextSize \(size); local budget \(budget) estimated tokens (\(MemoryRecall.localBudget) at 4096)")
        print("MEM1 L2 limit \(LocalToolset.budgetFraction * Double(size)) tokens for tools plus instructions")
        let counter = SystemTokenCounter(model: model)
        let blockTokens = try await counter.tokenCount(instructions: block)
        print("MEM1 block: \(block.utf8.count) bytes, \(MemoryRecall.estimatedTokens(block)) estimated, \(blockTokens) counted")
        let system = SystemPrompt.base(changelogPath: "/private/var/empty/CHANGELOG.md")
        let systemTokens = try await counter.tokenCount(instructions: system)
        let withBlock = try await counter.tokenCount(instructions: system + block)
        print("MEM1 SYSTEM_PROMPT \(systemTokens) tokens; with the block \(withBlock)")
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        let all = LocalToolset.dynamicTools(LocalToolset.catalog, gateway: gateway, turn: TurnContext(channel: .voice),
                                            budget: LocalCallBudget(), log: { _ in })
        let allTokens = try await counter.tokenCount(tools: all)
        print("MEM1 all \(all.count) tools \(allTokens) tokens")
        for (label, instructions) in [("without the block", system), ("with the block", system + block)] {
            let s = await LocalToolset.select(from: all, instructions: instructions, counter: counter, log: { _ in })
            print("MEM1 \(label): \(s.tier.rawValue), \(s.tools.count) tools, \(s.selectedToolTokens) tool tokens, "
                  + "\(s.instructionTokens) instruction tokens, dropped \(s.dropped)")
            #expect(LocalToolset.pinned.allSatisfy { name in s.names.contains(name) })
        }
    }
}
