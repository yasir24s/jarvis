import Foundation
import Observation
import Synchronization

/// P6 part 5 (DEV-P6-06, proposed): the user's consent to JARVIS learning about them from their
/// files (P3's background scanner), the "Learn About Me From My Files" item in the app menu and
/// the menu-bar menu. Memory is the user's own: a new install learns nothing from files until
/// they switch it on.
///
/// Kept as `fileLearningEnabled` in the app's defaults (`com.jarv1s.assistant`), so it survives
/// a relaunch. With no value yet, `resolve(filesIndexExists:)` decides once: an install whose
/// scanner has already run (memory/files-index.json exists) counts as having consented and is
/// set on, so its scan carries on; a new install is set off.
@MainActor
@Observable
public final class FileLearningConsent {
    /// The defaults domain, the app's own, as the voice settings use.
    public static let defaultsSuite = "com.jarv1s.assistant"
    public static let defaultsKey = "fileLearningEnabled"
    /// Set once JARVIS has offered, in the chat, to learn from the user's files.
    public static let offeredKey = "fileLearningOffered"
    /// The menu item's title.
    public static let menuTitle = "Learn About Me From My Files"

    /// The app's defaults: the suite, or the standard defaults (the same domain inside the app).
    public static var appDefaults: UserDefaults {
        UserDefaults(suiteName: defaultsSuite) ?? .standard
    }

    public var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.defaultsKey)
            shared.set(isOn)
        }
    }

    /// The same value for background work off the main actor (the scanner reads it).
    @ObservationIgnored public let shared: SharedFlag
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = FileLearningConsent.appDefaults) {
        self.defaults = defaults
        let on = defaults.bool(forKey: Self.defaultsKey)
        isOn = on
        shared = SharedFlag(on)
    }

    /// Whether the user (or `resolve`) has set a value yet.
    public var isDecided: Bool { defaults.object(forKey: Self.defaultsKey) != nil }

    /// Decides the value once, when none is set: on when the file index already exists, else off.
    public func resolve(filesIndexExists: Bool) {
        guard !isDecided else { return }
        isOn = filesIndexExists
    }

    /// Whether JARVIS should offer, in the chat, to learn from the user's files: on a first
    /// launch (no memory folder yet), when learning from files is off and he has not offered
    /// before. Marks the offer made when it is due, so it is made once.
    public func takeFirstRunOffer(memoryFolderExists: Bool) -> Bool {
        guard !memoryFolderExists, !isOn, !defaults.bool(forKey: Self.offeredKey) else { return false }
        defaults.set(true, forKey: Self.offeredKey)
        return true
    }

    /// The offer, in his voice, naming the menu item.
    public static let firstRunOffer = "Good day, sir. Should you care to let me, I can learn about you from your "
        + "documents, reading them quietly in the background and keeping what I learn on this Mac. The longer ones "
        + "go to Claude, with anything that looks secret taken out first. Choose \(menuTitle) in the JARVIS menu "
        + "or the menu-bar menu whenever you wish. Until then, I shan't read a thing."
}

/// A Bool any thread may read, set from the main actor.
public final class SharedFlag: Sendable {
    private let value: Mutex<Bool>

    public init(_ value: Bool) {
        self.value = Mutex(value)
    }

    public var isOn: Bool { value.withLock { $0 } }

    public func set(_ on: Bool) {
        value.withLock { $0 = on }
    }
}
