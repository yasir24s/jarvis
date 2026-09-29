import Foundation
import FoundationModels
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Synchronization

// Fakes for the T3.6 tests. Nothing here loads a model: FakeLocalModel stands in for
// FoundationModels behind LocalBrain's two protocols, and FakeCounter stands in for the
// tokenizer. The fake session calls the real DynamicTools, so a scripted tool call goes
// through the real ToolGateway like the model's would.

/// A gateway of its own for each test, with its own confirmation gate.
func localTestGateway(log: @escaping @Sendable (String) -> Void = { _ in }) -> ToolGateway {
    ToolGateway(confirmationGate: ConfirmationGate(), log: log)
}

/// Injected token counts: each tool costs `perTool[name]` (default `toolCost`), the
/// instructions cost `instructions`. `failing` makes both counts throw.
struct FakeCounter: LocalTokenCounting {
    struct CountFailed: Error {}

    let contextSize: Int
    var toolCost = 100
    var perTool: [String: Int] = [:]
    var instructions = 0
    var failing = false
    var estimates: Bool { false }

    func tokenCount(tools: [DynamicTool]) async throws -> Int {
        if failing { throw CountFailed() }
        return tools.reduce(0) { $0 + (perTool[$1.name] ?? toolCost) }
    }

    func tokenCount(instructions: String) async throws -> Int {
        if failing { throw CountFailed() }
        return self.instructions
    }
}

/// One step of a scripted response.
enum FakeStep: Sendable {
    /// Yield this cumulative snapshot.
    case snapshot(String)
    /// Call the offered tool with this name and JSON arguments, as FoundationModels would:
    /// a tool that throws ends the response with `ToolCallError`.
    case call(String, String)
    /// End the response with this error.
    case fail(any Error)
    /// Wait until the stream is cancelled.
    case hang
}

/// A test error with a fixed description.
struct FakeModelError: Error, CustomStringConvertible {
    let description: String
}

/// What the fake saw, readable from the test.
final class FakeModelLog: Sendable {
    struct State {
        var sessions = 0
        var instructions: [String] = []
        var offered: [[String]] = []
        var prompts: [String] = []
        var options: [GenerationOptions] = []
        var toolOutputs: [String] = []
        weak var lastSession: FakeSession?
    }

    let state = Mutex(State())

    var sessions: Int { state.withLock { $0.sessions } }
    var instructions: [String] { state.withLock { $0.instructions } }
    var prompts: [String] { state.withLock { $0.prompts } }
    var options: [GenerationOptions] { state.withLock { $0.options } }
    var toolOutputs: [String] { state.withLock { $0.toolOutputs } }
    var lastSessionAlive: Bool { state.withLock { $0.lastSession != nil } }
    var offeredTools: [[String]] { state.withLock { $0.offered } }
}

/// FoundationModels' stand-in. `attempts[i]` scripts the i-th `streamResponse` of a session.
/// `offer` limits the tools to these names (default: the whole catalog, in order).
final class FakeLocalModel: LocalLanguageModel {
    let reason: String?
    let attempts: [[FakeStep]]
    let offer: [String]?
    let seen = FakeModelLog()

    init(reason: String? = nil, attempts: [[FakeStep]], offer: [String]? = nil) {
        self.reason = reason
        self.attempts = attempts
        self.offer = offer
    }

    func unavailableReason() async -> String? { reason }

    func tools(instructions: String, gateway: ToolGateway, turn: TurnContext,
               budget: LocalCallBudget) async -> [DynamicTool] {
        let schemas = offer.map { names in ToolCatalog.tools.filter { names.contains($0.name) } }
            ?? ToolCatalog.tools
        let tools = LocalToolset.dynamicTools(schemas, gateway: gateway, turn: turn, budget: budget,
                                              log: { _ in })
        seen.state.withLock { $0.offered.append(tools.map(\.name)) }
        return tools
    }

    func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession {
        let session = FakeSession(attempts: attempts, tools: tools, seen: seen)
        seen.state.withLock {
            $0.sessions += 1
            $0.instructions.append(instructions)
            $0.lastSession = session
        }
        return session
    }
}

/// One fake session: each `streamResponse` plays the next scripted attempt; past the end
/// of the script it answers with an empty reply.
final class FakeSession: LocalModelSession {
    let attempts: [[FakeStep]]
    let tools: [DynamicTool]
    let seen: FakeModelLog
    private let next = Mutex(0)

    init(attempts: [[FakeStep]], tools: [DynamicTool], seen: FakeModelLog) {
        self.attempts = attempts
        self.tools = tools
        self.seen = seen
    }

    func streamResponse(to prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        let index = next.withLock { value -> Int in
            defer { value += 1 }
            return value
        }
        seen.state.withLock {
            $0.prompts.append(prompt)
            $0.options.append(options)
        }
        let steps = index < attempts.count ? attempts[index] : []
        let tools = self.tools
        let seen = self.seen
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        switch step {
                        case .snapshot(let text):
                            continuation.yield(text)
                        case let .call(name, json):
                            guard let tool = tools.first(where: { $0.name == name }) else {
                                throw FakeModelError(description: "tool \(name) not offered")
                            }
                            do {
                                let output = try await tool.call(arguments: GeneratedContent(json: json))
                                seen.state.withLock { $0.toolOutputs.append(output) }
                            } catch {
                                throw LanguageModelSession.ToolCallError(tool: tool, underlyingError: error)
                            }
                        case .fail(let error):
                            throw error
                        case .hang:
                            try await Task.sleep(for: .seconds(3600))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A tool body that records what reached it.
struct RecordingBody: JarvisTool {
    static let name = "set_volume"

    final class Calls: Sendable {
        let state = Mutex<[(JSONObject, ToolOrigin)]>([])
        var args: [JSONObject] { state.withLock { $0.map(\.0) } }
        var origins: [ToolOrigin] { state.withLock { $0.map(\.1) } }
    }

    let calls: Calls

    func run(_ args: ToolArgs, _ ctx: ToolContext) async throws -> String {
        calls.state.withLock { $0.append((args, ctx.origin)) }
        return "Volume set, sir."
    }
}
