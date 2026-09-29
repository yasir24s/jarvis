import Foundation
import FoundationModels
import JarvisCore
import JarvisTools

// jarvis.py `generate`'s local loop (5076-5120), on Apple's on-device model instead of
// Ollama (plan M02-M04 §3.8, "Semantics"). BrainRouter (T3.5) sets the backend name, folds
// the history into `system` (D-11) and does the history bookkeeping for each outcome.

/// One on-device turn per `generate` call: check the model is available, pick the turn's
/// tools, open one `LanguageModelSession`, stream the reply into `SentenceSplitter`, and let
/// the session go when the turn ends.
///
/// Every reply it returns also goes to `sink`: streamed text sentence by sentence as it
/// pops, and the fixed replies as one sentence each, as Python's `say()` speaks them.
///
/// Where native differs from Python:
/// - An empty reply is retried in the same session, which already holds any tool results,
///   so a retry never runs a tool again. The user text is sent again as the prompt, where
///   Ollama was sent the same messages again.
/// - The runaway limit is more than 10 tool calls, not 5 rounds (FoundationModels exposes no
///   round count). The eleventh call does not run.
/// - The model being unavailable is a failure, with its reason logged. Ollama had no
///   equivalent; its errors were exceptions.
public actor LocalBrain: LocalGenerating {
    /// `_set_backend` name for this brain. Its counter is `backend_local_apple_foundation_model_`:
    /// Python's `\W+` replaces the closing parenthesis too (golden m3_backend_key).
    public static let backendName = "local (apple-foundation-model)"
    public static let temperature = 0.6
    /// Python's `num_predict` for voice (D-12).
    public static let voiceResponseTokens = 200
    /// The text channel's longer cap (D-12).
    public static let textResponseTokens = 600
    /// Python's `empty_retries < 2`.
    public static let emptyRetries = 2
    public static let emptyReply = "Sorry, sir — could you say that again?"
    public static let stuckReply = "I got stuck working through that, sir."
    public static let errorReply = "My local reasoning core had an error, sir."

    private let gateway: ToolGateway
    private let model: any LocalLanguageModel
    private let log: @Sendable (String) -> Void

    /// - Parameters:
    ///   - gateway: every tool call the model makes goes through it, as `.model(.local)`.
    ///   - model: `SystemLocalModel()` in production; tests pass a fake.
    ///   - log: where log lines go. Tests pass their own.
    public init(gateway: ToolGateway, model: (any LocalLanguageModel)? = nil,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.gateway = gateway
        self.model = model ?? SystemLocalModel(log: log)
        self.log = log
    }

    /// `temperature 0.6`; 200 response tokens for voice, 600 for text.
    public static func options(for channel: Channel) -> GenerationOptions {
        GenerationOptions(temperature: temperature,
                          maximumResponseTokens: channel == .voice ? voiceResponseTokens : textResponseTokens)
    }

    /// Never throws. `.failed` means BrainRouter pops the user entry (Python's except branch).
    public func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                         sink: any ReplySink) async -> LocalOutcome {
        if let reason = await model.unavailableReason() {
            log("Brain error: the on-device model is unavailable (\(reason))")
            await sink.sentence(Self.errorReply)
            return .failed(Self.errorReply)
        }
        let budget = LocalCallBudget()
        let tools = await model.tools(instructions: system, gateway: gateway, turn: turn, budget: budget)
        // The turn's one session. It is a local, so it is released when the turn returns.
        let session = await model.session(instructions: system, tools: tools)
        let options = Self.options(for: channel)
        var retries = 0
        do {
            while true {
                let content = try await reply(from: session, to: user, options: options, sink: sink)
                if !Py.strip(content).isEmpty { return .reply(content) }
                guard retries < Self.emptyRetries else { break }
                retries += 1
                log("Empty model response — retry \(retries).")
            }
            await sink.sentence(Self.emptyReply)
            return .reply(Self.emptyReply)
        } catch {
            if budget.exceeded {
                log("Local model: stopped after \(LocalCallBudget.limit) tool calls this turn")
                await sink.sentence(Self.stuckReply)
                return .reply(Self.stuckReply)
            }
            log("Brain error: \(Self.describe(error))")
            await sink.sentence(Self.errorReply)
            return .failed(Self.errorReply)
        }
    }

    /// One streamed response: snapshots diffed into deltas, each delta to `sink.delta` and
    /// `SentenceSplitter`, each popped sentence to `sink.sentence`, the rest force-popped at
    /// the end. Returns Python's `" ".join(full).strip()`.
    private func reply(from session: any LocalModelSession, to prompt: String, options: GenerationOptions,
                       sink: any ReplySink) async throws -> String {
        var diff = SnapshotDiff()
        var buf = ""
        var full: [String] = []
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let delta = diff.delta(to: snapshot)
            guard !delta.isEmpty else { continue }
            await sink.delta(delta)
            buf += delta
            let (sentences, rest) = SentenceSplitter.pop(buf)
            buf = rest
            for sentence in sentences {
                full.append(sentence)
                await sink.sentence(sentence)
            }
        }
        for sentence in SentenceSplitter.pop(buf, force: true).sentences {
            full.append(sentence)
            await sink.sentence(sentence)
        }
        return Py.strip(full.joined(separator: " "))
    }

    /// The error for the log. Context overflow is named, whichever SDK spelling it arrives in.
    static func describe(_ error: any Error) -> String {
        if #available(macOS 27, *), let error = error as? LanguageModelError,
           case .contextSizeExceeded = error {
            return "context size exceeded: \(error)"
        }
        if let error = error as? LanguageModelSession.GenerationError,
           case .exceededContextWindowSize = error {
            return "context size exceeded: \(error)"
        }
        return String(describing: error)
    }
}
