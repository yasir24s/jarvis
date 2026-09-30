import Foundation
import JarvisCore
import JarvisTools
import Observation

/// The menu's "Speak replies" toggle (plan: M02-M04 §3.12), the user's input to
/// `shouldSpeakReply`. It is kept in UserDefaults, so it survives a relaunch, and is off until
/// switched on.
@MainActor
@Observable
public final class SpeakRepliesToggle {
    /// The UserDefaults key.
    public static let defaultsKey = "speakReplies"

    public var isOn: Bool {
        didSet { defaults.set(isOn, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isOn = defaults.bool(forKey: Self.defaultsKey)
    }
}

/// What happens to each finished typed reply (plan §3.12): the user's policy is asked. On a
/// yes, `text_reply_spoken` is bumped and the text goes, with the turn's summary, to M8's
/// speaker. Until M8 there is no speaker: a yes is logged, and nothing is spoken or counted,
/// since the counter counts replies that were spoken.
public enum SpeakReplies {
    /// Bumped once per typed reply handed to the speaker (plan §3.12; additive, native only).
    public static let spokenCounter = "text_reply_spoken"
    /// `SpeakContext.ttsBackend` until M8 brings a speaker.
    public static let noTTSBackend = "none"

    public typealias Policy = @MainActor (Channel, String, SpeakContext) -> Bool
    public typealias Speaker = @MainActor (String, TurnSummary) -> Void

    /// The policy's input for one finished row: the toggle's state, the row's length (Python
    /// `len()`, in scalars) and its turn. No voice conversation runs before M8.
    @MainActor
    public static func context(for message: ChatMessage, turn: TurnSummary, toggle: SpeakRepliesToggle,
                               chatWindowIsKey: Bool, userIdleSeconds: Double) -> SpeakContext {
        SpeakContext(chatWindowIsKey: chatWindowIsKey, speakToggleOn: toggle.isOn, userIdleSeconds: userIdleSeconds,
                     voiceConversationActive: false, replyCharCount: message.text.unicodeScalars.count,
                     turn: turn, ttsBackend: noTTSBackend)
    }

    /// Asks `policy` (the user's `shouldSpeakReply`) about `message`, and returns its answer.
    @MainActor
    @discardableResult
    public static func replyFinished(_ message: ChatMessage, context: SpeakContext, research: any ResearchCounting,
                                     speaker: Speaker?, log: (String) -> Void,
                                     policy: Policy = shouldSpeakReply) -> Bool {
        guard policy(.text, message.text, context) else { return false }
        guard let speaker else {
            log("speak policy: yes, but typed replies are not spoken until M8")
            return true
        }
        research.bump(spokenCounter, by: 1)
        speaker(message.text, context.turn)
        return true
    }
}
