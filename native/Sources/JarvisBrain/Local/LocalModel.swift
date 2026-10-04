import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// The seam between LocalBrain and FoundationModels (plan M02-M04 §3.8). Production uses
// `SystemLocalModel`; the offline tests put a fake behind the same two protocols, so the
// retry, tool-limit and error paths run without a model.

/// The model LocalBrain drives: whether it can run, which tools a turn gets, and a new
/// session per turn.
public protocol LocalLanguageModel: Sendable {
    /// nil when the model can run, otherwise the reason it cannot (LocalBrain logs it).
    func unavailableReason() async -> String?
    /// The turn's tools (LocalToolset's budget rule for the real model), chosen for `request`.
    func tools(for request: LocalToolRequest, instructions: String, gateway: ToolGateway, turn: TurnContext,
               budget: LocalCallBudget) async -> [DynamicTool]
    /// A new session holding `instructions` and `tools`, for one turn only.
    func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession
    /// A new tools-less session for the guided tool choice, one turn only; nil when this model
    /// has none (the turn then calls tools free-form).
    func guidedSession(instructions: String) async -> (any LocalGuidedSession)?
    /// MEM1 part 1: the tokens the model's context holds.
    var contextSize: Int { get async }
}

public extension LocalLanguageModel {
    /// A fake that does not say has the context the budgets were first sized for.
    var contextSize: Int { get async { MemoryRecall.referenceContextSize } }

    /// A fake without guided generation calls tools free-form.
    func guidedSession(instructions: String) async -> (any LocalGuidedSession)? { nil }
}

/// One turn's conversation. Each element of the stream is the whole reply so far
/// (FoundationModels snapshots are cumulative); LocalBrain diffs them into deltas.
public protocol LocalModelSession: Sendable {
    func streamResponse(to prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, any Error>
}

/// `SystemLanguageModel.default` (or another system model) behind `LocalLanguageModel`.
public struct SystemLocalModel: LocalLanguageModel {
    public let model: SystemLanguageModel
    private let ranker: LocalToolRanker?
    private let log: @Sendable (String) -> Void

    /// - Parameter embedding: the sentence vectors that choose each turn's tools by relevance;
    ///   nil offers CORE-21 instead.
    public init(model: SystemLanguageModel = .default, embedding: (any SentenceEmbedding)? = nil,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.model = model
        ranker = embedding.map { LocalToolRanker(embedding: $0) }
        self.log = log
    }

    public func unavailableReason() async -> String? {
        switch model.availability {
        case .available: return nil
        case .unavailable(let reason): return String(describing: reason)
        }
    }

    public func tools(for request: LocalToolRequest, instructions: String, gateway: ToolGateway, turn: TurnContext,
                      budget: LocalCallBudget) async -> [DynamicTool] {
        await LocalToolset.select(model: model, instructions: instructions, request: request, ranker: ranker,
                                  gateway: gateway, turn: turn, budget: budget, log: log).tools
    }

    public func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession {
        FoundationSession(session: LanguageModelSession(model: model, tools: tools, instructions: instructions))
    }

    public func guidedSession(instructions: String) async -> (any LocalGuidedSession)? {
        FoundationGuidedSession(session: LanguageModelSession(model: model, instructions: instructions))
    }

    /// `SystemLanguageModel.contextSize` (back-deployed: 4,096 before macOS 27).
    public var contextSize: Int { get async { model.contextSize } }
}

/// A `LanguageModelSession` behind `LocalModelSession`. Stopping the stream early (the
/// consumer is cancelled or drops it) cancels the generation.
struct FoundationSession: LocalModelSession {
    let session: LanguageModelSession

    func streamResponse(to prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, any Error> {
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await snapshot in session.streamResponse(to: prompt, options: options) {
                        continuation.yield(snapshot.content)
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

/// Cumulative snapshots to deltas. A snapshot that extends the last one yields the new tail.
/// One that does not (the model started a new message, say after a tool call) yields
/// whatever follows the part it shares with the last snapshot, since text already fed cannot
/// be taken back. Compared by Unicode scalar, so a combining mark that arrives after its
/// base letter is a delta of its own and not a change to the letter.
public struct SnapshotDiff: Sendable {
    private var last: [Unicode.Scalar] = []

    public init() {}

    public mutating func delta(to snapshot: String) -> String {
        let scalars = Array(snapshot.unicodeScalars)
        var shared = 0
        while shared < last.count, shared < scalars.count, last[shared] == scalars[shared] {
            shared += 1
        }
        last = scalars
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[shared...])
        return String(out)
    }
}
