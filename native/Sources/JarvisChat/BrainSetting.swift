import Foundation
import JarvisBrain
import Observation

/// M9a part 7: the menus' "Brain" item, Claude or On-device, with a checkmark on the current
/// one. Kept in UserDefaults as SpeakRepliesToggle keeps `speakReplies`, and Claude until the
/// user picks otherwise. BrainRouter reads the stored choice as each turn begins, so a change
/// holds from the next message, with no restart, and a turn already running finishes on the
/// brain it began with. Only replies follow it: file reading, the memory writer and the persona
/// writer keep their own routes. `JARVIS_USE_CLAUDE=0` still forces the on-device model: the item
/// then shows On-device, disabled, and says why.
@MainActor
@Observable
public final class BrainSetting {
    /// The UserDefaults key.
    nonisolated public static let defaultsKey = "brain"
    nonisolated public static let menuTitle = "Brain"

    nonisolated public static func title(_ choice: BrainChoice) -> String {
        switch choice {
        case .claude: "Claude"
        case .onDevice: "On-device"
        }
    }

    /// The help text for the item.
    nonisolated public static let help = "Which brain writes his replies, from the next message: Claude, "
        + "or Apple's on-device model. Claude needs a network; offline he answers on-device, as before. "
        + "File reading, the memory writer and the persona writer keep their own routes."
    /// The help text while `JARVIS_USE_CLAUDE=0` holds.
    nonisolated public static let forcedHelp = "On-device: JARVIS_USE_CLAUDE=0 turns Claude off for this "
        + "launch. File reading, the memory writer and the persona writer keep their own routes."

    /// The user's choice, as stored.
    public var choice: BrainChoice {
        didSet { defaults.set(choice.rawValue, forKey: Self.defaultsKey) }
    }
    /// `JARVIS_USE_CLAUDE=0`: Claude is off for this launch, whatever the choice says.
    public let claudeOff: Bool
    /// What the item shows checked.
    public var shown: BrainChoice { claudeOff ? .onDevice : choice }
    public var help: String { claudeOff ? Self.forcedHelp : Self.help }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard, claudeEnabled: Bool) {
        self.defaults = defaults
        claudeOff = !claudeEnabled
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
