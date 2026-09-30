import JarvisTools

// USER DECISION POINT (plan: M02-M04 §3.12): whether JARVIS reads a typed reply aloud. The app
// asks `shouldSpeakReply` about every finished reply in the chat window (`SpeakReplies`).

/// What the policy knows about one finished typed reply.
public struct SpeakContext: Sendable {
    let chatWindowIsKey: Bool; let speakToggleOn: Bool; let userIdleSeconds: Double
    let voiceConversationActive: Bool; let replyCharCount: Int
    let turn: TurnSummary            // dataSources/tainted — sensitive content awareness
    let ttsBackend: String           // "elevenlabs" | "piper" (M8)

    public init(chatWindowIsKey: Bool, speakToggleOn: Bool, userIdleSeconds: Double,
                voiceConversationActive: Bool, replyCharCount: Int, turn: TurnSummary, ttsBackend: String) {
        self.chatWindowIsKey = chatWindowIsKey
        self.speakToggleOn = speakToggleOn
        self.userIdleSeconds = userIdleSeconds
        self.voiceConversationActive = voiceConversationActive
        self.replyCharCount = replyCharCount
        self.turn = turn
        self.ttsBackend = ttsBackend
    }
}

/// USER DECISION: return true to have JARVIS read this typed-channel reply aloud.
///
/// The trade-offs:
/// - **Always speak.** Consistent persona, but noisy while you read, and it doubles the output.
/// - **Speak only when the window is not key, or you are idle.** Useful when you walk away,
///   but a surprise at other times.
/// - **Never speak** (this stub). Quiet and private, but the text channel loses the voice.
/// - **Length cap.** Long markdown replies sound bad; strip markdown before TTS.
/// - **Privacy.** When `context.turn.dataSources` holds personal sources, ElevenLabs (cloud)
///   sends that text off-device. M8 can route it to Piper. The policy may also refuse to speak
///   at all.
/// - **Cost and latency.** Cloud TTS usage grows with every spoken reply.
///
/// When this returns true the app bumps `text_reply_spoken` and hands the text, with
/// `context.turn`, to M8's speaker. Until M8 there is no speaker, so nothing is spoken yet.
public func shouldSpeakReply(channel: Channel, text: String, context: SpeakContext) -> Bool {
    // TODO(user): decide when a typed reply is read aloud. The trade-offs are listed above.
    false
}
