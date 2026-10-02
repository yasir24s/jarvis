import Foundation
import JarvisCore
import JarvisTools
import Synchronization

/// jarvis.py `process_command` (plan: M02-M04 §3.9), in Python's order. `CoreState.beginTurn`
/// runs steps 1 to 9 (M1's `m1_prompt` golden suite proves that half against the real
/// function); this type adds the channel, then calls Claude or the on-device model.
///
/// Both brains send their own reply to the sink as it is produced (Python's streamed speech,
/// and its `say()` for the fixed replies), so the router only returns the text.
///
/// Where native differs from Python:
/// - M9a part 7: the menus' Brain item can send replies to the on-device model while Claude is
///   on and online (`choice`). Only replies: file reading, the memory writer and the persona
///   writer keep their own routes.
/// - A text turn also bumps `interactions_text` (M01b's key: a typed command reached the LLM
///   path; Python has no text channel). It comes after `beginTurn`, so after the counters
///   `track_feedback` bumps rather than next to `interactions`: only the first-bump key order
///   in usage.json can show it.
/// - The local model gets the same folded prompt as Claude (D-11), where Python hands Ollama
///   `sys_prompt` plus the 12 raw history turns.
/// - With `recall`, the facts relevant to the message follow the channel addendum (D-51 P2),
///   within each brain's own budget. No relevant fact adds nothing.
/// M9a part 7: which brain writes the replies, from the menus' "Brain" item. Claude still needs
/// `JARVIS_USE_CLAUDE` and a network; otherwise the on-device model answers, as before.
public enum BrainChoice: String, Sendable, CaseIterable {
    case claude
    case onDevice
}

public struct BrainRouter: Sendable {
    private let core: CoreState
    private let config: ClaudeConfig
    private let claude: any ClaudeGenerating
    private let local: any LocalGenerating
    private let backend: any BackendReporting
    private let research: any ResearchCounting
    private let recall: MemoryRecall?
    private let log: @Sendable (String) -> Void
    private let choice: @Sendable () -> BrainChoice

    /// - Parameters:
    ///   - recall: the long-term memory's recall (D-51 P2); nil adds none.
    ///   - choice: M9a part 7, the menus' Brain item, read once as each turn begins.
    ///   - log: where the router's own line goes (a turn whose state files have the wrong
    ///     shape). Tests pass their own.
    public init(core: CoreState, config: ClaudeConfig, claude: any ClaudeGenerating,
                local: any LocalGenerating, backend: any BackendReporting, research: any ResearchCounting,
                recall: MemoryRecall? = nil, choice: @escaping @Sendable () -> BrainChoice = { .claude },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.choice = choice
        self.core = core
        self.config = config
        self.claude = claude
        self.local = local
        self.backend = backend
        self.research = research
        self.recall = recall
        self.log = log
    }

    /// The system prompt a brain gets: `system + SelfKnowledge.text(channel) +
    /// ChannelAddendum.text(channel) + memory + preamble` (steps 10 and 11, P4's self-knowledge
    /// and the D-51 memory block). `memoryTools` picks the self-knowledge that names
    /// search_memory. `claudeSystem` is `system + preamble`, so for voice, whose self-knowledge
    /// and addendum are empty, with no memory this is `claudeSystem` itself, byte for byte.
    public static func prompt(_ head: CoreState.TurnPrompt, channel: Channel, memory: String = "",
                              memoryTools: Bool = true) -> String {
        let addendum = SelfKnowledge.text(channel, memoryTools: memoryTools) + ChannelAddendum.text(channel) + memory
        guard !addendum.isEmpty else { return head.claudeSystem }
        let system = Array(head.system.utf8), full = Array(head.claudeSystem.utf8)
        guard full.starts(with: system) else {
            assertionFailure("claudeSystem does not start with system")
            return head.claudeSystem + addendum
        }
        return head.system + addendum + String(decoding: full[system.count...], as: UTF8.self)
    }

    /// UI1 part 4: what the brains are given for a message sent while the reply to the last one
    /// was still coming. The history before it holds that message and the reply as far as it got.
    public static func addedContext(_ text: String) -> String {
        "[Added context: I stopped your last reply, so it was cut short, to add this to the same request.]\n" + text
    }

    /// One command, as `process_command(text, online)`. Returns the reply ("" when a state file
    /// has the wrong shape: Python's turn raises there, and its main loop only logs).
    ///
    /// UI1 part 4: a stopped turn (its task cancelled) ends where it is, and never falls back to
    /// the local model. History keeps what was shown of the reply as the assistant turn ("" if
    /// nothing was), and that is what is returned. With `addsContext`, the brains get the text
    /// labelled by `addedContext`; history and the rest of the turn see it as typed.
    public func process(_ text: String, online: Bool, channel: Channel, turn: TurnContext,
                        sink: any ReplySink, addsContext: Bool = false) async -> String {
        // M9a part 7: read before anything waits, so a turn finishes on the brain it began with.
        let chosen = choice()
        let head: CoreState.TurnPrompt
        do {
            head = try await core.beginTurn(text, online: online)                    // steps 1-9
        } catch {
            // Python raises before its `finally`, so nothing is saved either.
            log("Loop error: \(error)")
            return ""
        }
        defer { await core.saveHistory() }                                            // step 14
        if channel == .text {
            research.bump(ResearchKey.interactionsText, by: 1)                       // step 5
        }
        let memory = recall?.appendix(for: text) ?? .none                              // D-51 P2
        let system = Self.prompt(head, channel: channel, memory: memory.claude,      // step 10
                                 memoryTools: recall != nil)
        let localSystem = Self.prompt(head, channel: channel, memory: memory.local, memoryTools: false)
        let user = addsContext ? Self.addedContext(text) : text
        let shown = ShownReply(sink)

        if config.enabled && online && chosen == .claude {                             // step 11
            // Python's `if reply:`: nil and "" both fall through to the local model.
            let reply = await claude.generate(system: system, user: user, turn: turn, sink: shown)
            if Task.isCancelled { return await stopped(shown) }
            if let reply, !reply.isEmpty {
                await core.recordAssistant(reply)                                    // step 12
                return reply
            }
        }
        if Task.isCancelled { return await stopped(shown) }

        await backend.set(LocalBrain.backendName)                                     // step 13
        // History as Python's four local-loop endings leave it (jarvis.py 5086-5118).
        let outcome = await local.generate(system: localSystem, user: user, channel: channel, turn: turn, sink: shown)
        if Task.isCancelled { return await stopped(shown) }
        switch outcome {
        case .reply(let reply):
            await core.recordAssistant(reply)
            return reply
        case .emptyReply(let spoken):
            await core.recordAssistant("")
            return spoken
        case .stuck(let spoken):
            return spoken
        case .failed(let reply):
            await core.popTrailingUserTurn()
            return reply
        }
    }

    /// UI1 part 5: where history stands, before a turn, and the rewind an edit makes to it.
    public func historyMark() async -> Int {
        await core.historyMark()
    }

    public func rewindHistory(to mark: Int) async {
        await core.rewindHistory(to: mark)
    }

    /// The stopped turn's history: the reply as far as it was shown.
    private func stopped(_ shown: ShownReply) async -> String {
        let partial = shown.text
        await core.recordAssistant(partial)
        return partial
    }
}

/// UI1 part 4: hands a reply on to `sink` and keeps what was shown of it, the deltas or, on a
/// path with none, the sentences, since the last retraction (as the chat's live row does).
/// Once the turn is stopped nothing more is passed on or kept: the local model's error line for
/// a cancelled generation is neither shown, spoken nor taken as the reply.
final class ShownReply: ReplySink {
    private struct Shown {
        var deltas = ""
        var sentences: [String] = []
    }

    private let sink: any ReplySink
    private let shown = Mutex(Shown())

    init(_ sink: any ReplySink) {
        self.sink = sink
    }

    var text: String {
        shown.withLock { Py.strip($0.deltas.isEmpty ? $0.sentences.joined(separator: " ") : $0.deltas) }
    }

    func sentence(_ text: String) async {
        guard !Task.isCancelled else { return }
        shown.withLock { $0.sentences.append(text) }
        await sink.sentence(text)
    }

    func delta(_ text: String) async {
        guard !Task.isCancelled else { return }
        shown.withLock { $0.deltas += text }
        await sink.delta(text)
    }

    func retracted(messageID: String) async {
        guard !Task.isCancelled else { return }
        shown.withLock { $0 = Shown() }
        await sink.retracted(messageID: messageID)
    }
}
