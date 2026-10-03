import Foundation
import Observation

/// Batch C parts 2 and 5b: the two media switches, both off until the user turns them on.
/// "Learn From My Music" lets JARVIS read the Music library and keep a few facts about the user's
/// taste in memory; "Media Library" keeps the music, TV and folder catalogue for the media tools.
/// Both are personal sources: the catalogue stays on this Mac and a brain is given titles only.
@MainActor
@Observable
public final class MediaConsent {
    public static let musicKey = "learnFromMusic"
    public static let libraryKey = "mediaLibrary"
    public static let musicTitle = "Learn From My Music"
    public static let forgetMusicTitle = "Forget My Music…"
    public static let libraryTitle = "Media Library"

    public var music: Bool {
        didSet {
            defaults.set(music, forKey: Self.musicKey)
            sharedMusic.set(music)
        }
    }

    public var library: Bool {
        didSet {
            defaults.set(library, forKey: Self.libraryKey)
            sharedLibrary.set(library)
        }
    }

    @ObservationIgnored public let sharedMusic: SharedFlag
    @ObservationIgnored public let sharedLibrary: SharedFlag
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = FileLearningConsent.appDefaults) {
        self.defaults = defaults
        let m = defaults.bool(forKey: Self.musicKey), l = defaults.bool(forKey: Self.libraryKey)
        music = m
        library = l
        sharedMusic = SharedFlag(m)
        sharedLibrary = SharedFlag(l)
    }
}
