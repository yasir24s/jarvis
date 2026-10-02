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

    /// Reads the setting again (U1 part 5), so a change made outside the menu (`defaults
    /// write`) holds from the next reply; the menu shows it too.
    public func refresh() {
        let stored = defaults.bool(forKey: Self.defaultsKey)
        if stored != isOn { isOn = stored }
    }
}

/// What happens to each finished reply (plan §3.12). A typed one: the user's policy is asked. On a
/// yes, `text_reply_spoken` is bumped and the text goes, with the turn's summary, to M8's
/// speaker. Until M8 there is no speaker: a yes is logged, and nothing is spoken or counted,
/// since the counter counts replies that were spoken.
public enum SpeakReplies {
    /// Bumped once per typed reply handed to the speaker (plan §3.12; additive, native only).
    public static let spokenCounter = "text_reply_spoken"
    /// `SpeakContext.ttsBackend` when no speaker is given.
    public static let noTTSBackend = "none"

    public typealias Policy = @MainActor (Channel, String, SpeakContext) -> Bool
    public typealias Speaker = @MainActor (String, TurnSummary) -> Void

    /// The policy's input for one finished row: the toggle's state, the row's length (Python
    /// `len()`, in scalars), its turn and the voice that would speak it (M8: "f5", or "say" while
    /// F5 is unavailable). No voice conversation runs before M11.
    /// - speakAnyway: M11's Mic Only Mode, which speaks every reply whatever the toggle says.
    @MainActor
    public static func context(for message: ChatMessage, turn: TurnSummary, toggle: SpeakRepliesToggle,
                               chatWindowIsKey: Bool, userIdleSeconds: Double,
                               ttsBackend: String = noTTSBackend, speakAnyway: Bool = false) -> SpeakContext {
        toggle.refresh()   // U1 part 5: the setting as it is now, not as it was at launch
        return SpeakContext(chatWindowIsKey: chatWindowIsKey, speakToggleOn: speakAnyway || toggle.isOn,
                            userIdleSeconds: userIdleSeconds, voiceConversationActive: false,
                            replyCharCount: message.text.unicodeScalars.count, turn: turn, ttsBackend: ttsBackend)
    }

    /// Asks `policy` (the user's `shouldSpeakReply`) about `message`, and returns its answer.
    @MainActor
    @discardableResult
    public static func replyFinished(_ message: ChatMessage, context: SpeakContext, research: any ResearchCounting,
                                     speaker: Speaker?, log: (String) -> Void,
                                     policy: Policy = shouldSpeakReply) -> Bool {
        // M9a: a reply to something said aloud is always spoken, whatever its length, as Python
        // spoke its voice replies. The toggle and the typed-reply policy are for typed turns, and
        // `text_reply_spoken` counts only those.
        if context.turn.channel == .voice {
            guard let speaker, !message.text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else {
                return false
            }
            speaker(message.text, context.turn)
            return true
        }
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
