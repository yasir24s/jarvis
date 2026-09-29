// Where a brain sends its reply while it is being generated (plan §3.6, §3.13).
// The contract between ClaudeDriver (T3.4), LocalBrain (T3.6), TurnCoordinator (T3.5) and the
// chat window (M4). Written by the orchestrator: executors call or implement it, never edit it.

/// `sentence` gets each complete sentence as `SentenceSplitter` pops it; that is what
/// "emitted" means for salvage. `delta` gets raw text as it streams, for live rendering.
/// `retracted` names a message the model retracted after a refusal (R6), so the text channel
/// can strike through the rows that message fed.
public protocol ReplySink: Sendable {
    func sentence(_ text: String) async
    func delta(_ text: String) async
    func retracted(messageID: String) async
}

public extension ReplySink {
    func delta(_ text: String) async {}
    func retracted(messageID: String) async {}
}
