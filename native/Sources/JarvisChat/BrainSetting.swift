import Foundation
import JarvisBrain
import Observation

/// M9a part 7: the menus' "Brain" item, Claude or On-device, with a checkmark on the current
/// one. Kept in UserDefaults as SpeakRepliesToggle keeps `speakReplies`, and Claude until the
/// user picks otherwise. BrainRouter reads the stored choice as each turn begins, so a change
/// holds from the next message, with no restart, and a turn already running finishes on the
/// brain it began with. Only replies follow it: file reading, the memory writer and the persona
/// writer stay on Claude. `JARVIS_USE_CLAUDE=0` still forces the on-device model for a Claude
/// pick: Claude's entry is then disabled, a Claude pick shows On-device, and the help says why.
///
/// B2: ChatGPT, through Codex on the user's ChatGPT sign-in, is the third entry, and
/// `JARVIS_USE_CHATGPT=0` does the same for it. With both off the whole item is disabled on
/// On-device, as it was with Claude off before.
@MainActor
@Observable
public final class BrainSetting {
    /// The UserDefaults key.
    nonisolated public static let defaultsKey = "brain"
    nonisolated public static let menuTitle = "Brain"

    nonisolated public static func title(_ choice: BrainChoice) -> String {
        switch choice {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .onDevice: "On-device"
        }
    }

    /// Part 4: where the other Claude uses go, whichever brain answers.
    nonisolated public static let routes = "File reading, the memory writer and the persona writer stay on Claude "
        + "whichever brain answers, unless JARVIS_USE_CLAUDE=0 turns Claude off."
    /// The help text for the item.
    nonisolated public static let help = "Which brain writes his replies, from the next message: Claude, ChatGPT "
        + "(through Codex, on your ChatGPT sign-in) or Apple's on-device model. Claude and ChatGPT need a network; "
        + "offline he answers on-device, as before. " + routes
    /// The help text while `JARVIS_USE_CLAUDE=0` holds and ChatGPT is on.
    nonisolated public static let claudeOffHelp = "JARVIS_USE_CLAUDE=0 turns Claude off for this launch, for replies "
        + "and for file reading, the memory writer and the persona writer. ChatGPT and On-device can still be picked."
    /// The help text while `JARVIS_USE_CHATGPT=0` holds and Claude is on.
    nonisolated public static let chatgptOffHelp = "JARVIS_USE_CHATGPT=0 turns ChatGPT off for this launch. Claude "
        + "and On-device can still be picked. " + routes
    /// The help text while both are off.
    nonisolated public static let forcedHelp = "On-device: JARVIS_USE_CLAUDE=0 and JARVIS_USE_CHATGPT=0 turn Claude "
        + "and ChatGPT off for this launch, for replies and for file reading, the memory writer and the persona writer."

    /// The user's choice, as stored.
    public var choice: BrainChoice {
        didSet { defaults.set(choice.rawValue, forKey: Self.defaultsKey) }
    }
    /// `JARVIS_USE_CLAUDE=0`: Claude is off for this launch, whatever the choice says.
    public let claudeOff: Bool
    /// B2: `JARVIS_USE_CHATGPT=0`: ChatGPT is off for this launch, whatever the choice says.
    public let chatgptOff: Bool
    /// What the item shows checked: the choice, or On-device when the chosen brain is off.
    public var shown: BrainChoice { isOff(choice) ? .onDevice : choice }
    /// Both cloud brains are off, so the whole item is disabled.
    public var allOff: Bool { claudeOff && chatgptOff }
    public var help: String {
        switch (claudeOff, chatgptOff) {
        case (true, true): Self.forcedHelp
        case (true, false): Self.claudeOffHelp
        case (false, true): Self.chatgptOffHelp
        case (false, false): Self.help
        }
    }

    /// Whether `choice`'s brain is switched off for this launch (its entry is then disabled).
    public func isOff(_ choice: BrainChoice) -> Bool {
        switch choice {
        case .claude: claudeOff
        case .chatgpt: chatgptOff
        case .onDevice: false
        }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, claudeEnabled: Bool, chatgptEnabled: Bool = true) {
        self.defaults = defaults
        claudeOff = !claudeEnabled
        chatgptOff = !chatgptEnabled
        choice = Self.stored(in: defaults)
    }

    /// The choice stored in `defaults`: Claude when there is none, or it is not one of ours. Read
    /// on any thread (UserDefaults is), which is how BrainRouter asks each turn.
    nonisolated public static func stored(in defaults: UserDefaults) -> BrainChoice {
        defaults.string(forKey: defaultsKey).flatMap(BrainChoice.init(rawValue:)) ?? .claude
    }

    /// Reads the setting again, so a change made outside the menu shows there too.
    public func refresh() {
        let stored = Self.stored(in: defaults)
        if stored != choice { choice = stored }
    }
}
