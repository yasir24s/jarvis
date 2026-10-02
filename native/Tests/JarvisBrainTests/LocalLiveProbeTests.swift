import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// T3.6's one live probe (plan M02-M04 §3.8, §5 A-11, §8 R-7). Skipped unless
/// JARVIS_LIVE_LOCAL=1. It prints the tokenizer's count for each list of tools and what a count
/// costs, runs the per-turn choice of tools on the real tokenizer and NLEmbedding for five
/// messages, then runs three real LocalBrain turns on `SystemLanguageModel.default` ("what time
/// is it", a question about a phrase, a question about what the user said before) and prints
/// the numbers R-7 needs. No tool body is registered on its gateway, so a call is answered with
/// "Unknown tool"; what the probe shows is which tools the model reaches for.
@Suite("M3 local model: live probe (JARVIS_LIVE_LOCAL=1)")
struct LocalLiveProbeTests {
    static let enabled = ProcessInfo.processInfo.environment["JARVIS_LIVE_LOCAL"] == "1"

    @Test("one real on-device turn: availability, contextSize, token counts, reply",
          .enabled(if: LocalLiveProbeTests.enabled), .timeLimit(.minutes(5)))
    func probe() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let model = SystemLanguageModel.default
        let instructions = SystemPrompt.base(
            changelogPath: sandbox.root.appending(path: "CHANGELOG.md").path(percentEncoded: false))
        print("PROBE os \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("PROBE availability \(model.availability)")
        print("PROBE contextSize \(model.contextSize)")
        print("PROBE instructions \(instructions.unicodeScalars.count) chars (SYSTEM_PROMPT only)")

        // The tokenizer's counts for each candidate set, beside the brain's own selection.
        let counter = SystemTokenCounter(model: model)
        print("PROBE tokenizer \(counter.estimates ? LocalToolset.estimateNote : "tokenCount(for:)")")
        let catalog = LocalToolsetTests.catalogTools()
        let python = LocalToolsetTests.catalogTools(schemas: ToolCatalog.tools)
        let old = LocalToolsetTests.measuredCore22.compactMap { name in python.first { $0.name == name } }
        let core = LocalToolset.core21.compactMap { name in catalog.first { $0.name == name } }
        let pinned = LocalToolset.pinned.compactMap { name in catalog.first { $0.name == name } }
        func counted(_ body: () async throws -> Int) async -> String {
            do { return String(try await body()) } catch { return "error: \(error)" }
        }
        let hinted = instructions + LocalBrain.toolHint
        let instructionTokens = await counted { try await counter.tokenCount(instructions: instructions) }
        let hintedTokens = await counted { try await counter.tokenCount(instructions: hinted) }
        let pythonTokens = await counted { try await counter.tokenCount(tools: python) }
        let allTokens = await counted { try await counter.tokenCount(tools: catalog) }
        let oldTokens = await counted { try await counter.tokenCount(tools: old) }
        let coreTokens = await counted { try await counter.tokenCount(tools: core) }
        let pinnedTokens = await counted { try await counter.tokenCount(tools: pinned) }
        print("PROBE tokens instructions \(instructionTokens), with the hint \(hintedTokens), "
              + "46 tools \(pythonTokens), 47 tools \(allTokens), old CORE-22 \(oldTokens), "
              + "CORE-21 \(coreTokens), pinned 3 \(pinnedTokens)")
        print("PROBE estimate instructions \(LocalToolset.estimate(instructions: instructions)), "
              + "with the hint \(LocalToolset.estimate(instructions: hinted)), "
              + "46 tools \(LocalToolset.estimate(tools: python)), 47 tools \(LocalToolset.estimate(tools: catalog)), "
              + "old CORE-22 \(LocalToolset.estimate(tools: old)), CORE-21 \(LocalToolset.estimate(tools: core)), "
              + "pinned 3 \(LocalToolset.estimate(tools: pinned))")

        // The per-turn choice end to end: this tokenizer, NLEmbedding, and what each costs.
        // The probe prints the tool names; the app's log line never does.
        let clock = ContinuousClock()
        let embedding = SystemSentenceEmbedding()
        let ranker = LocalToolRanker(embedding: embedding)
        // What one count costs. The per-turn choice makes about eight: the instructions, every
        // tool, then a bisection for the longest list that fits.
        func cost(_ label: String, _ body: () async throws -> Int) async {
            var spent: [String] = []
            for _ in 0..<2 {
                let began = clock.now
                _ = try? await body()
                spent.append("\(clock.now - began)")
            }
            print("PROBE count cost \(label): \(spent.joined(separator: ", "))")
        }
        await cost("instructions") { try await counter.tokenCount(instructions: hinted) }
        await cost("1 tool") { try await counter.tokenCount(tools: Array(catalog.prefix(1))) }
        await cost("pinned 3") { try await counter.tokenCount(tools: pinned) }
        await cost("CORE-21") { try await counter.tokenCount(tools: core) }
        await cost("47 tools") { try await counter.tokenCount(tools: catalog) }
        let turns: [(String, String?)] = [("what's the weather like in London", nil), ("play some jazz", nil),
                     ("what did I tell you about my sister's birthday", nil),
                     ("turn it up more", "play some jazz"), ("remind me to call mom at five", nil)]
        for (text, previous) in turns {
            let request = LocalToolRequest(text: text, previousText: previous,
                                           previousTools: previous == nil ? [] : ["music_play"])
            let began = clock.now
            let chosen = await LocalToolset.select(from: catalog, instructions: hinted, counter: counter,
                                                   request: request, ranker: ranker, log: { _ in })
            print("PROBE select \(clock.now - began): \(chosen.tier.rawValue), \(chosen.tools.count) tools, "
                  + "\(chosen.selectedToolTokens) tokens + \(chosen.instructionTokens) of \(chosen.limit): "
                  + chosen.names.joined(separator: " "))
        }

        // The one model call, through the real selection, session and stream.
        let logs = LogRecorder()
        let gatewayLogs = LogRecorder()
        let sink = RecordingSink()
        let turn = TurnContext(channel: .voice)
        let brain = LocalBrain(gateway: ToolGateway(confirmationGate: ConfirmationGate(), log: gatewayLogs.function),
                               embedding: embedding, log: logs.function)
        let start = clock.now
        let outcome = await brain.generate(system: instructions, user: "what time is it", channel: .voice,
                                           turn: turn, sink: sink)
        let elapsed = clock.now - start

        // Two more turns on the same brain, which now has a previous message and its tools: does
        // the model reach for web_search and search_memory? Their bodies are not registered on
        // this gateway, so the answer to a call is its "Unknown tool" text; the call is the point.
        for text in ["where does the phrase 'old sport' come from?", "what did I tell you about my sister's birthday?"] {
            let sink = RecordingSink()
            let turn = TurnContext(channel: .voice)
            let began = clock.now
            let outcome = await brain.generate(system: instructions, user: text, channel: .voice,
                                               turn: turn, sink: sink)
            let runs = await turn.summary().toolRuns
            print("PROBE turn [\(text)]: tools \(runs.map { "\($0.name) \($0.outcome)" }), "
                  + "\(clock.now - began), \(outcome)")
        }

        for line in logs.lines { print("PROBE log \(line)") }
        for line in gatewayLogs.lines { print("PROBE gateway log \(line)") }
        let runs = await turn.summary().toolRuns
        print("PROBE tool runs \(runs.map { "\($0.name) \($0.outcome)" })")
        print("PROBE deltas \(await sink.deltas.count), sentences \(await sink.sentences)")
        print("PROBE outcome \(outcome)")
        print("PROBE elapsed \(elapsed)")

        // An unavailable model is a result too: the brain fails before it selects tools.
        if model.availability == .available {
            let selection = try #require(logs.lines.first { $0.hasPrefix("Local model: contextSize") })
            #expect(selection.contains("contextSize \(model.contextSize)"))
        } else {
            #expect(outcome == .failed(LocalBrain.errorReply))
        }
    }
}
