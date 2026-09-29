import Foundation
import JarvisCore
import JarvisTools

/// jarvis.py `process_command` (plan: M02-M04 §3.9), in Python's order. `CoreState.beginTurn`
/// runs steps 1 to 9 (M1's `m1_prompt` golden suite proves that half against the real
/// function); this type adds the channel, then calls Claude or the on-device model.
///
/// Both brains send their own reply to the sink as it is produced (Python's streamed speech,
/// and its `say()` for the fixed replies), so the router only returns the text.
///
/// Where native differs from Python:
/// - A text turn also bumps `interactions_text` (M01b's key: a typed command reached the LLM
///   path; Python has no text channel). It comes after `beginTurn`, so after the counters
///   `track_feedback` bumps rather than next to `interactions`: only the first-bump key order
///   in usage.json can show it.
/// - The local model gets the same folded prompt as Claude (D-11), where Python hands Ollama
///   `sys_prompt` plus the 12 raw history turns.
public struct BrainRouter: Sendable {
    private let core: CoreState
    private let config: ClaudeConfig
    private let claude: any ClaudeGenerating
    private let local: any LocalGenerating
    private let backend: any BackendReporting
    private let research: any ResearchCounting
    private let log: @Sendable (String) -> Void

    /// - Parameter log: where the router's own line goes (a turn whose state files have the
    ///   wrong shape). Tests pass their own.
    public init(core: CoreState, config: ClaudeConfig, claude: any ClaudeGenerating,
                local: any LocalGenerating, backend: any BackendReporting, research: any ResearchCounting,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.core = core
        self.config = config
        self.claude = claude
        self.local = local
        self.backend = backend
        self.research = research
        self.log = log
    }

    /// The system prompt both brains get: `system + ChannelAddendum.text(channel) + preamble`
    /// (steps 10 and 11). `claudeSystem` is `system + preamble`, so for voice, whose addendum
    /// is empty, this is `claudeSystem` itself, byte for byte.
    public static func prompt(_ head: CoreState.TurnPrompt, channel: Channel) -> String {
        let addendum = ChannelAddendum.text(channel)
        guard !addendum.isEmpty else { return head.claudeSystem }
        let system = Array(head.system.utf8), full = Array(head.claudeSystem.utf8)
        guard full.starts(with: system) else {
            assertionFailure("claudeSystem does not start with system")
            return head.claudeSystem + addendum
        }
        return head.system + addendum + String(decoding: full[system.count...], as: UTF8.self)
    }

    /// One command, as `process_command(text, online)`. Returns the reply ("" when a state file
    /// has the wrong shape: Python's turn raises there, and its main loop only logs).
    public func process(_ text: String, online: Bool, channel: Channel, turn: TurnContext,
                        sink: any ReplySink) async -> String {
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
        let system = Self.prompt(head, channel: channel)                              // step 10

        if config.enabled && online {                                                  // step 11
            // Python's `if reply:`: nil and "" both fall through to the local model.
            if let reply = await claude.generate(system: system, user: text, turn: turn, sink: sink),
               !reply.isEmpty {
                await core.recordAssistant(reply)                                    // step 12
                return reply
            }
        }

        await backend.set(LocalBrain.backendName)                                     // step 13
        // History as Python's four local-loop endings leave it (jarvis.py 5086-5118).
        switch await local.generate(system: system, user: text, channel: channel, turn: turn, sink: sink) {
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
}
