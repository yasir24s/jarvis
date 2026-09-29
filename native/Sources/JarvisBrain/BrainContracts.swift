import JarvisTools

// The two brains as BrainRouter (T3.5) calls them, plan §3.6, §3.8 and §3.9. Written by the
// orchestrator so T3.5 and T3.6 can be built in parallel: executors implement or call these
// protocols, never edit them.

/// The Claude CLI driver (T3.4). `nil` means "fall back to the local model".
public protocol ClaudeGenerating: Sendable {
    func generate(system: String, user: String, turn: TurnContext, sink: ReplySink) async -> String?
}

/// What the on-device model produced for one turn. Each case is one of the four endings of
/// Python's local loop (jarvis.py `process_command`), and names what BrainRouter does to
/// history, which is a compatibility surface Python must still read (D-41).
public enum LocalOutcome: Sendable, Equatable {
    /// A normal reply: appended to history as the assistant turn.
    case reply(String)
    /// No content after the empty-reply retries: the text ("Sorry, sir — could you say that
    /// again?") is spoken or shown, and "" is appended as the assistant turn.
    case emptyReply(spoken: String)
    /// A runaway tool loop: the text ("I got stuck working through that, sir.") is spoken or
    /// shown, and nothing is appended to history.
    case stuck(spoken: String)
    /// The model failed or is unavailable: the trailing user turn is dropped from history,
    /// and the text ("My local reasoning core had an error, sir.") is spoken or shown.
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
