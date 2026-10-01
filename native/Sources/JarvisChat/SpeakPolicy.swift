import JarvisTools

// Typed-reply speech policy (plan: M02-M04 §3.12). SpeakReplies asks about each finished reply.

/// What the policy knows about one finished typed reply.
public struct SpeakContext: Sendable {
    let chatWindowIsKey: Bool; let speakToggleOn: Bool; let userIdleSeconds: Double
    let voiceConversationActive: Bool; let replyCharCount: Int
    let turn: TurnSummary            // dataSources/tainted — sensitive content awareness
    let ttsBackend: String           // "f5" | "say" (M8, D-54); "elevenlabs" is a cloud voice

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

/// Allows a short typed reply when the user has enabled "Speak replies". Focus and idle time
/// do not override that consent. An active voice conversation takes priority; personal data
/// must not go to a cloud voice. The 600-scalar limit keeps longer answers in the chat window.
///
/// This is permission to speak, not a claim that speech occurred. SpeakReplies counts a reply
/// only when it hands the text to a speaker; until M8 there is no speaker.
public func shouldSpeakReply(channel: Channel, text: String, context: SpeakContext) -> Bool {
    guard channel == .text, context.speakToggleOn else { return false }
    // The voice loop (M11, M12) speaks its own replies; reading a typed one would talk over it.
    guard !context.voiceConversationActive else { return false }
    guard context.replyCharCount > 0, context.replyCharCount <= SpeakRules.replyLimit else { return false }
    // Check the actual text too: a stale context must not admit a blank or oversized reply.
    guard !text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }),
          text.unicodeScalars.count <= SpeakRules.replyLimit else { return false }
    if SpeakRules.cloudVoices.contains(context.ttsBackend),
       !context.turn.dataSources.isDisjoint(with: SpeakRules.personalSources) {
        return false
    }
    return true
}

/// The limits `shouldSpeakReply` applies.
enum SpeakRules {
    /// Unicode scalars, matching SpeakReplies.context and Python len(). Keep typed speech
    /// brief (D-49); this is a product limit, not a duration estimate or a TTS engine limit.
    static let replyLimit = 600
    /// Voices whose synthesis happens off the Mac.
    static let cloudVoices: Set<String> = ["elevenlabs"]
    /// Turn data sources whose text is the user's own: never read out by a cloud voice.
    static let personalSources: Set<DataSource> = [.messages, .calendar, .reminders, .contacts, .email,
                                                   .notes, .files, .clipboard, .screen, .location]
}
