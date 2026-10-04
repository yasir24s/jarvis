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
/// BrainRouter does not speak them again. Each of Python's four endings has its own
/// `LocalOutcome` case, so BrainRouter can do Python's history bookkeeping for it.
///
/// Where native differs from Python:
/// - An empty reply is retried in the same session, which already holds any tool results,
///   so a retry never runs a tool again. The user text is sent again as the prompt, where
///   Ollama was sent the same messages again.
/// - The runaway limit is more than 10 tool calls, not 5 rounds (FoundationModels exposes no
///   round count). The eleventh call does not run.
/// - The model being unavailable is a failure, with its reason logged. Ollama had no
///   equivalent; its errors were exceptions.
/// - Cancelling the calling task stops the generation. A cancelled turn with no reply yet is
///   an error (no retry); one with text already streamed returns that text.
/// - The instructions end with `toolHint`, one line the on-device model gets and Claude does
///   not, since only this model works with a short list of tools.
/// - The turn's tools are chosen by relevance to what was said (`LocalToolset`), so the brain
///   keeps the message and the tools of its previous turn for the next one's choice. A turn
///   Claude answered is not seen here.
/// - A tool call the model writes into its reply as text (`run_command: ...`, a JSON object)
///   is taken out of what is shown, spoken and kept (`ToolCallTextFilter`), and logged as
///   counts. Nothing runs it: there is no text tool protocol.
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
    /// The last line of the instructions. web_search and search_memory are pinned, so they are
    /// offered on every turn and this can say so. Live fix 6: the on-device model took
    /// SYSTEM_PROMPT's example "Done, sir." as an opener ("Done, sir. Your query is vague…") and
    /// invented offers ("Shall I also alert the fire brigade?"). The last two sentences are for
    /// it alone, so Claude's prompt stays Python's; the line stays within D-7's 30 tokens.
    public static let toolHint = "\n\nUse web_search for current facts, search_memory for past chats. Say done only if a tool ran. No offers."

    private let gateway: ToolGateway
    private let model: any LocalLanguageModel
    private let log: @Sendable (String) -> Void
    /// The previous turn's message and the tools it ran (each once, in order), for the next
    /// turn's choice of tools.
    private var previous: (text: String, tools: [String])?

    /// - Parameters:
    ///   - gateway: every tool call the model makes goes through it, as `.model(.local)`.
    ///   - model: `SystemLocalModel()` in production; tests pass a fake.
    ///   - embedding: the sentence vectors the default model chooses a turn's tools with (the
    ///     instance recall uses); nil means it offers the fixed list.
    ///   - log: where log lines go. Tests pass their own.
    public init(gateway: ToolGateway, model: (any LocalLanguageModel)? = nil,
                embedding: (any SentenceEmbedding)? = nil,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.gateway = gateway
        self.model = model ?? SystemLocalModel(embedding: embedding, log: log)
        self.log = log
    }

    /// MEM1 part 1: the model's context size, for the memory block's budget.
    public var contextSize: Int { get async { await model.contextSize } }

    /// `temperature 0.6`; 200 response tokens for voice, 600 for text.
    public static func options(for channel: Channel) -> GenerationOptions {
        GenerationOptions(temperature: temperature,
                          maximumResponseTokens: channel == .voice ? voiceResponseTokens : textResponseTokens)
    }

    /// Never throws. `.failed` means BrainRouter pops the user entry (Python's except branch).
    public func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                         sink: any ReplySink) async -> LocalOutcome {
        let request = LocalToolRequest(text: user, previousText: previous?.text,
                                       previousTools: previous?.tools ?? [])
        let outcome = await run(instructions: system + Self.toolHint, request: request, channel: channel,
                                turn: turn, sink: sink)
        // Whatever the ending, the next turn's choice of tools has this message and these tools.
        var seen = Set<String>()
        let tools = await turn.summary().toolRuns.map(\.name).filter { seen.insert($0).inserted }
        previous = (user, tools)
        return outcome
    }

    /// One turn, from the availability check to the outcome.
    private func run(instructions: String, request: LocalToolRequest, channel: Channel, turn: TurnContext,
                     sink: any ReplySink) async -> LocalOutcome {
        if let reason = await model.unavailableReason() {
            log("Brain error: the on-device model is unavailable (\(reason))")
            await sink.sentence(Self.errorReply)
            return .failed(Self.errorReply)
        }
        let budget = LocalCallBudget()
        let tools = await model.tools(for: request, instructions: instructions, gateway: gateway, turn: turn,
                                      budget: budget)
        // The turn's one session. It is a local, so it is released when the turn returns.
        let session = await model.session(instructions: instructions, tools: tools)
        let options = Self.options(for: channel)
        var retries = 0
        do {
            while true {
                let content = try await reply(from: session, to: request.text, options: options, budget: budget,
                                              sink: sink)
                if !Py.strip(content).isEmpty { return .reply(content) }
                // A cancelled turn ends its stream early. That is an error, not an empty reply.
                try Task.checkCancellation()
                guard retries < Self.emptyRetries else { break }
                retries += 1
                log("Empty model response — retry \(retries).")
            }
            await sink.sentence(Self.emptyReply)
            return .emptyReply(spoken: Self.emptyReply)
        } catch {
            if budget.exceeded {
                log("Local model: stopped after \(LocalCallBudget.limit) tool calls this turn")
                await sink.sentence(Self.stuckReply)
                return .stuck(spoken: Self.stuckReply)
            }
            log("Brain error: \(Self.describe(error))")
            await sink.sentence(Self.errorReply)
            return .failed(Self.errorReply)
        }
    }

    /// One streamed response: snapshots diffed into deltas, a tool call written as text taken
    /// out of them (`ToolCallTextFilter`), the deltas into `SentenceSplitter`, the rest
    /// force-popped at the end. Each popped sentence goes through `ReplyCheck` against the
    /// turn's gateway results before it reaches `sink` (as a sentence, and as the delta that
    /// shows it), so a claim that nothing backs is never spoken or shown. A gated or blocked
    /// call replaces the model's text with Swift's reply. Returns Python's
    /// `" ".join(full).strip()` of what was kept.
    private func reply(from session: any LocalModelSession, to prompt: String, options: GenerationOptions,
                       budget: LocalCallBudget, sink: any ReplySink) async throws -> String {
        var diff = SnapshotDiff()
        var filter = ToolCallTextFilter()
        var buf = ""
        var full: [String] = []
        var check = ReplyCheck.Stream()
        for try await snapshot in session.streamResponse(to: prompt, options: options) {
            let delta = filter.push(diff.delta(to: snapshot))
            guard !delta.isEmpty else { continue }
            buf += delta
            let (sentences, rest) = SentenceSplitter.pop(buf)
            let shown = check.pass(raw: Self.consumed(buf, leaving: rest), sentences: sentences,
                                   calls: budget.results)
            buf = rest
            if !shown.delta.isEmpty { await sink.delta(shown.delta) }
            for kept in shown.sentences {
                full.append(kept)
                await sink.sentence(kept)
            }
        }
        // What the filter still held at the end: a line start that never became a tool name, or
        // a JSON object that never closed and names no tool.
        buf += filter.finish()
        if filter.removed {
            log("Local model: tool-call text removed from the reply (lines \(filter.lines), "
                + "JSON objects \(filter.objects), characters \(filter.characters))")
        }
        let last = check.pass(raw: buf, sentences: SentenceSplitter.pop(buf, force: true).sentences,
                              calls: budget.results)
        if !last.delta.isEmpty { await sink.delta(last.delta) }
        for kept in last.sentences {
            full.append(kept)
            await sink.sentence(kept)
        }
        let swift = ReplyCheck.overrideReply(budget.results)
        let closing = swift ?? (full.isEmpty && check.changed > 0 ? ReplyCheck.notDone : nil)
        if check.changed > 0 || swift != nil {
            log("Local model: reply check changed \(check.changed) sentence(s)"
                + (swift != nil ? ", reply written from the gateway outcome" : ""))
        }
        if let closing {
            await sink.delta(check.shown(closing))
            full.append(closing)
            await sink.sentence(closing)
        }
        return Py.strip(full.joined(separator: " "))
    }

    /// The front of `buf` that SentenceSplitter consumed, given the `rest` it left.
    static func consumed(_ buf: String, leaving rest: String) -> String {
        String(String.UnicodeScalarView(buf.unicodeScalars.dropLast(rest.unicodeScalars.count)))
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
