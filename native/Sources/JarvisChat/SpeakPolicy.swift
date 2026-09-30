import JarvisTools

// USER DECISION POINT (plan: M02-M04 §3.12): whether JARVIS reads a typed reply aloud. The app
// asks `shouldSpeakReply` about every finished reply in the chat window (`SpeakReplies`).
// Drafted 2026-09-30 at the user's request, for Codex to polish.

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
/// - **Never speak** (the M4 stub). Quiet and private, but the text channel loses the voice.
/// - **Length cap.** Long markdown replies sound bad; strip markdown before TTS.
/// - **Privacy.** When `context.turn.dataSources` holds personal sources, ElevenLabs (cloud)
///   sends that text off-device. M8 can route it to Piper. The policy may also refuse to speak
///   at all.
/// - **Cost and latency.** Cloud TTS usage grows with every spoken reply.
///
/// The rule chosen: speak a typed reply whenever the "Speak replies" toggle is on, the user's
/// explicit consent, except when a voice conversation is already speaking its own replies, when
/// the reply is empty or longer than `SpeakRules.replyLimit`, or when a cloud voice would carry
/// personal content off the Mac. Window focus and idle time do not matter while the toggle is on.
///
/// When this returns true the app bumps `text_reply_spoken` and hands the text, with
/// `context.turn`, to M8's speaker. Until M8 there is no speaker, so nothing is spoken yet.
public func shouldSpeakReply(channel: Channel, text: String, context: SpeakContext) -> Bool {
    guard channel == .text, context.speakToggleOn else { return false }
    // The voice loop (M11, M12) speaks its own replies; reading a typed one would talk over it.
    guard !context.voiceConversationActive else { return false }
    guard context.replyCharCount > 0, context.replyCharCount <= SpeakRules.replyLimit else { return false }
    if SpeakRules.cloudVoices.contains(context.ttsBackend),
       !context.turn.dataSources.isDisjoint(with: SpeakRules.personalSources) {
        return false
    }
    return true
}

/// The limits `shouldSpeakReply` applies.
enum SpeakRules {
    /// Longer replies are not read aloud: past about 40 s of speech, reading the window is
    /// quicker than listening, and long text-chat answers are mostly Markdown.
    static let replyLimit = 600
    /// Voices whose synthesis happens off the Mac.
    static let cloudVoices: Set<String> = ["elevenlabs"]
    /// Turn data sources whose text is the user's own: never read out by a cloud voice.
    static let personalSources: Set<DataSource> = [.messages, .calendar, .reminders, .contacts, .email,
                                                   .notes, .files, .clipboard, .screen, .location]
}
