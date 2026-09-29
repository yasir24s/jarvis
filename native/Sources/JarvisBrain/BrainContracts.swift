import JarvisTools

// The two brains as BrainRouter (T3.5) calls them, plan §3.6, §3.8 and §3.9. Written by the
// orchestrator so T3.5 and T3.6 can be built in parallel: executors implement or call these
// protocols, never edit them.

/// The Claude CLI driver (T3.4). `nil` means "fall back to the local model".
public protocol ClaudeGenerating: Sendable {
    func generate(system: String, user: String, turn: TurnContext, sink: ReplySink) async -> String?
}

/// What the on-device model produced for one turn.
public enum LocalOutcome: Sendable, Equatable {
    /// A reply to speak or show, including Python's fixed replies for an empty answer
    /// ("Sorry, sir — could you say that again?") and a runaway tool loop.
    case reply(String)
    /// The model failed or is unavailable. BrainRouter drops the trailing user turn from
    /// history, as Python's error branch does, and replies with this text.
    case failed(String)
}

/// The on-device model (FoundationModels, T3.6). `system` already holds the prompt, the
/// channel addendum and the folded history (D-11). It never throws.
public protocol LocalGenerating: Sendable {
    func generate(system: String, user: String, channel: Channel, turn: TurnContext,
                  sink: ReplySink) async -> LocalOutcome
}

/// T3.4 is the Claude brain BrainRouter calls.
extension ClaudeDriver: ClaudeGenerating {}
