import Foundation
import FoundationModels
import JarvisBrain
import JarvisCore
import JarvisTools
import Synchronization

/// The real on-device path for one request, with every tool a recording fake:
/// `BrainRouter.answer(online: false)` builds the prompt as the app does (CoreState's turn
/// prompt, the channel's self-knowledge and addendum), then `LocalBrain` picks the turn's tools
/// with `LocalToolset.select` and L2's `LocalToolRanker` over the production sentence embedding,
/// and streams the model's reply. Each request gets a fresh state root in a temp directory (no
/// history, no memory block, no personality notes), a fresh gateway and a fresh brain, so cases
/// never see one another.
///
/// What it adds to the production path is only observation: `SelectionRecordingModel` keeps
/// the `LocalToolSelection` the turn was given, and the fakes keep each call's arguments.
public struct OnDeviceBrain: EvalBrain {
    public let timeout: Duration
    private let embedding: any SentenceEmbedding
    private let log: @Sendable (String) -> Void

    /// - Parameter log: where the brain's own log lines go. The replay passes one that drops
    ///   them, since some quote the request.
    public init(timeout: Duration = .seconds(90), embedding: any SentenceEmbedding = SystemSentenceEmbedding(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.timeout = timeout
        self.embedding = embedding
        self.log = log
    }

    /// Nil when the on-device model can answer; otherwise why not.
    public static func unavailableReason() -> String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(let reason): return String(describing: reason)
        }
    }

    public func observe(_ evalCase: EvalCase) async -> EvalObservation {
        let channel: Channel = evalCase.channel == "voice" ? .voice : .text
        let started = ContinuousClock.now
        func elapsed() -> Double {
            let d = ContinuousClock.now - started
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        let root = FileManager.default.temporaryDirectory
            .appending(path: "od-eval-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let core: CoreState
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try StateStore(root: root.path(percentEncoded: false), lease: nil)
            core = CoreState(store: store, clock: SystemClock(), research: NoResearch(), frontApp: NoFrontApp())
        } catch {
            return EvalObservation(calls: [], reply: "harness: \(error)", ending: .failed, latencyMs: 0, offer: nil)
        }

        let recorder = ToolRecorder()
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: log)
        await RecordingTool.registerAll(LocalToolset.catalog, on: gateway, recorder: recorder)
        let model = SelectionRecordingModel(embedding: embedding, log: log)
        let brain = LocalBrain(gateway: gateway, model: model, log: log)
        let router = BrainRouter(core: core, config: ClaudeConfig(environment: [:]), claude: NoCloud(),
                                 chatgptEnabled: false, local: brain, backend: NoBackend(), research: NoResearch(),
                                 log: log)
        let turn = TurnContext(channel: channel, startTainted: evalCase.tainted ?? false)
        let text = evalCase.request
        let limit = timeout

        let answer: BrainRouter.Answer? = await withTaskGroup(of: BrainRouter.Answer?.self) { group in
            group.addTask {
                await router.answer(text, online: false, channel: channel, turn: turn, sink: NoSink())
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let latency = elapsed()
        await turn.close()
        let calls = recorder.merge(await turn.summary().toolRuns)
        let offer = model.selection.map {
            EvalOffer(tools: $0.names, tier: $0.tier.rawValue, instructionTokens: $0.instructionTokens,
                      toolTokens: $0.selectedToolTokens, limit: $0.limit, contextSize: $0.contextSize,
                      estimated: $0.estimated)
        }
        guard let answer else {
            return EvalObservation(calls: calls, reply: "", ending: .timeout, latencyMs: latency, offer: offer)
        }
        let ending: EvalEnding = switch answer.text {
        case LocalBrain.emptyReply: .empty
        case LocalBrain.stuckReply: .stuck
        case LocalBrain.errorReply: .failed
        default: .reply
        }
        return EvalObservation(calls: calls, reply: answer.text, ending: ending, latencyMs: latency, offer: offer)
    }
}

/// `SystemLocalModel` with the turn's `LocalToolSelection` kept. `tools(for:)` makes the same
/// call `SystemLocalModel.tools(for:)` makes (the default model, L2's ranker over `embedding`)
/// but keeps the whole selection, not only its tools; the session is `SystemLocalModel`'s own.
final class SelectionRecordingModel: LocalLanguageModel {
    private let inner: SystemLocalModel
    private let ranker: LocalToolRanker
    private let log: @Sendable (String) -> Void
    private let kept = Mutex<LocalToolSelection?>(nil)

    init(embedding: any SentenceEmbedding, log: @escaping @Sendable (String) -> Void) {
        inner = SystemLocalModel(embedding: embedding, log: log)
        ranker = LocalToolRanker(embedding: embedding)
        self.log = log
    }

    var selection: LocalToolSelection? { kept.withLock { $0 } }

    func unavailableReason() async -> String? { await inner.unavailableReason() }

    func tools(for request: LocalToolRequest, instructions: String, gateway: ToolGateway, turn: TurnContext,
               budget: LocalCallBudget) async -> [DynamicTool] {
        let selection = await LocalToolset.select(model: inner.model, instructions: instructions, request: request,
                                                  ranker: ranker, gateway: gateway, turn: turn, budget: budget,
                                                  log: log)
        kept.withLock { $0 = selection }
        return selection.tools
    }

    func session(instructions: String, tools: [DynamicTool]) async -> any LocalModelSession {
        await inner.session(instructions: instructions, tools: tools)
    }

    var contextSize: Int { get async { await inner.contextSize } }
}

struct NoCloud: ClaudeGenerating {
    func generate(system: String, user: String, turn: TurnContext, sink: ReplySink) async -> String? { nil }
}

struct NoBackend: BackendReporting {
    func set(_ name: String) async {}
}

struct NoResearch: ResearchCounting {
    func bump(_ key: String, by n: Int) {}
}

struct NoFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}

struct NoSink: ReplySink {
    func sentence(_ text: String) async {}
}
