import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// T3.6's one live probe (plan M02-M04 §3.8, §5 A-11, §8 R-7). Skipped unless
/// JARVIS_LIVE_LOCAL=1. It runs one real LocalBrain turn, "what time is it", on
/// `SystemLanguageModel.default` with the real tool selection, and prints the numbers R-7
/// needs. Before M5 no tool has a body, so get_time answers with the gateway's text.
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
        let tools = LocalToolsetTests.catalogTools()
        let core = LocalToolset.core22.compactMap { name in tools.first { $0.name == name } }
        func counted(_ body: () async throws -> Int) async -> String {
            do { return String(try await body()) } catch { return "error: \(error)" }
        }
        let instructionTokens = await counted { try await counter.tokenCount(instructions: instructions) }
        let allTokens = await counted { try await counter.tokenCount(tools: tools) }
        let coreTokens = await counted { try await counter.tokenCount(tools: core) }
        print("PROBE tokens instructions \(instructionTokens), 46 tools \(allTokens), CORE-22 \(coreTokens)")
        print("PROBE estimate instructions \(LocalToolset.estimate(instructions: instructions)), "
              + "46 tools \(LocalToolset.estimate(tools: tools)), CORE-22 \(LocalToolset.estimate(tools: core))")

        // The one model call, through the real selection, session and stream.
        let logs = LogRecorder()
        let gatewayLogs = LogRecorder()
        let sink = RecordingSink()
        let turn = TurnContext(channel: .voice)
        let brain = LocalBrain(gateway: ToolGateway(confirmationGate: ConfirmationGate(), log: gatewayLogs.function),
                               log: logs.function)
        let clock = ContinuousClock()
        let start = clock.now
        let outcome = await brain.generate(system: instructions, user: "what time is it", channel: .voice,
                                           turn: turn, sink: sink)
        let elapsed = clock.now - start

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
