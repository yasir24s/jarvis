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

/// What `SystemTokenCounter` does below macOS 26.4: the chars-per-token estimate, with the
/// back-deployed `contextSize` of 4096.
struct EstimatingCounter: LocalTokenCounting {
    var contextSize = 4096
    var estimates: Bool { true }

    func tokenCount(tools: [DynamicTool]) async throws -> Int {
        LocalToolset.estimate(tools: tools)
    }

    func tokenCount(instructions: String) async throws -> Int {
        LocalToolset.estimate(instructions: instructions)
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
        var requests: [LocalToolRequest] = []
        var prompts: [String] = []
        var options: [GenerationOptions] = []
        var toolOutputs: [String] = []
        /// The tools each reply session was given.
        var sessionTools: [[String]] = []
        weak var lastSession: FakeSession?
    }

    let state = Mutex(State())

    var sessions: Int { state.withLock { $0.sessions } }
    var instructions: [String] { state.withLock { $0.instructions } }
    var requests: [LocalToolRequest] { state.withLock { $0.requests } }
    var prompts: [String] { state.withLock { $0.prompts } }
    var options: [GenerationOptions] { state.withLock { $0.options } }
    var toolOutputs: [String] { state.withLock { $0.toolOutputs } }
    var lastSessionAlive: Bool { state.withLock { $0.lastSession != nil } }
    var offeredTools: [[String]] { state.withLock { $0.offered } }
    var sessionTools: [[String]] { state.withLock { $0.sessionTools } }
}

/// FoundationModels' stand-in. `attempts[i]` scripts the i-th `streamResponse` of a session.
/// `offer` limits the tools to these names (default: the whole catalog, in order).
final class FakeLocalModel: LocalLanguageModel {
    let reason: String?
    let attempts: [[FakeStep]]
    let offer: [String]?
    /// The guided session; nil means this model has none, as before od/guided-generation.
    let guided: FakeGuidedSession?
    let seen = FakeModelLog()

    init(reason: String? = nil, attempts: [[FakeStep]], offer: [String]? = nil,
         guided: FakeGuidedSession? = nil) {
        self.reason = reason
        self.attempts = attempts
        self.offer = offer
        self.guided = guided
    }

    func guidedSession(instructions: String) async -> (any LocalGuidedSession)? { guided }

    func unavailableReason() async -> String? { reason }

    func tools(for request: LocalToolRequest, instructions: String, gateway: ToolGateway, turn: TurnContext,
               budget: LocalCallBudget) async -> [DynamicTool] {
        let schemas = offer.map { names in ToolCatalog.tools.filter { names.contains($0.name) } }
            ?? ToolCatalog.tools
        let tools = LocalToolset.dynamicTools(schemas, gateway: gateway, turn: turn, budget: budget,
                                              log: { _ in })
        seen.state.withLock {
            $0.offered.append(tools.map(\.name))
            $0.requests.append(request)
        }
        return tools
    }

    func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession {
        let session = FakeSession(attempts: attempts, tools: tools, seen: seen)
        seen.state.withLock {
            $0.sessions += 1
            $0.instructions.append(instructions)
            $0.sessionTools.append(tools.map(\.name))
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

/// A deterministic stand-in for NLEmbedding: each word of four letters or more adds one to the
/// slot its FNV-1a hash picks, so two sentences are close when they share words, on every Mac.
/// `calls` counts the sentences asked for. `available: false` answers nil, as a Mac without the
/// language asset does, and so does a sentence with no such word.
final class WordBagEmbedding: SentenceEmbedding {
    static let dimension = 512

    private let available: Bool
    private let asked = Mutex(0)

    init(available: Bool = true) {
        self.available = available
    }

    var calls: Int { asked.withLock { $0 } }

    func vector(for sentence: String) -> [Double]? {
        asked.withLock { $0 += 1 }
        guard available else { return nil }
        var vector = [Double](repeating: 0, count: Self.dimension)
        var any = false
        let words = sentence.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        for word in words where word.count >= 4 {
            vector[Self.slot(word)] += 1
            any = true
        }
        return any ? vector : nil
    }

    private static func slot(_ word: Substring) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in word.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return Int(hash % UInt64(dimension))
    }
}

/// The guided session's stand-in. Each `respond` returns the next scripted reply in order
/// (choice, arguments, choice, …) as JSON, or throws; past the end of the script it throws.
final class FakeGuidedSession: LocalGuidedSession {
    enum Reply: Sendable {
        case json(String)
        case fail(any Error)
        /// Cancel the calling task, then return this JSON (a Stop while generating).
        case jsonThenCancel(String)
    }

    let replies: [Reply]
    private let state = Mutex<[String]>([])

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    /// Shorthand: a choice of `name`.
    static func choose(_ name: String) -> Reply { .json(#"{"tool": "\#(name)"}"#) }

    /// The prompts it was asked, in order.
    var prompts: [String] { state.withLock { $0 } }

    func respond(to prompt: String, schema: GenerationSchema, options: GenerationOptions) async throws
        -> GeneratedContent {
        let index = state.withLock { prompts -> Int in
            prompts.append(prompt)
            return prompts.count - 1
        }
        guard index < replies.count else { throw FakeModelError(description: "guided script ended") }
        switch replies[index] {
        case .json(let json): return try GeneratedContent(json: json)
        case .fail(let error): throw error
        case .jsonThenCancel(let json):
            withUnsafeCurrentTask { $0?.cancel() }
            return try GeneratedContent(json: json)
        }
    }
}

/// find_contact with a fixed answer, recording what reached it.
struct FindContactBody: JarvisTool {
    static let name = "find_contact"
    static let reply = "Priya Shah: +44 7700 900123"
    let calls: RecordingBody.Calls

    func run(_ args: ToolArgs, _ ctx: ToolContext) async throws -> String {
        calls.state.withLock { $0.append((args, ctx.origin)) }
        return Self.reply
    }
}

/// send_message as the real one behaves: it asks for confirmation, and `calls` records only a
/// confirmed send. A body reached before confirmation is recorded in `reached`.
struct SendMessageBody: ToolImpl {
    static let name = "send_message"
    static var schema: ToolSchema { ToolCatalog.tools.first { $0.name == name }! }
    let reached: RecordingBody.Calls
    let sent: RecordingBody.Calls

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        reached.state.withLock { $0.append((args, ctx.origin)) }
        let sent = self.sent
        let origin = ctx.origin
        return .needsConfirmation(desc: "Send Priya a message") {
            sent.state.withLock { $0.append((args, origin)) }
            return "Sent, sir."
        }
    }
}
