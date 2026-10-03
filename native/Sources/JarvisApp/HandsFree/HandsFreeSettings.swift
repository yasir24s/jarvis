import Foundation
import SwiftUI

/// What Mic Only Mode puts back when it is turned off: the chat window, Show HUD and the
/// listening choice as they were.
struct MicOnlyRestore: Codable, Equatable {
    var chatWindowOpen: Bool
    var showHUD: Bool
    /// The listening choice before (nil: none made, listening followed the voiceprint).
    var listenChoice: Bool?
}

/// M11 part 5: the menus' "Listen for “Hey Jarvis”" and "Mic Only Mode", kept in the app's
/// defaults (`com.jarv1s.assistant`).
///
/// - Listening is on once a voice is enrolled and off otherwise, until the user chooses; the
///   choice then stands.
/// - Mic Only Mode is the Python build's way of using him: the chat window hidden, the HUD shown,
///   hands-free listening on and every reply spoken. Turning it off puts the window, the HUD and
///   the listening choice back as they were. It lasts across launches.
/// - The app does the window and the HUD (`onMicOnly`) and starts or stops listening (`onChange`).
@MainActor
@Observable
final class HandsFreeSettings {
    static let shared = HandsFreeSettings()

    nonisolated static let listenKey = "listenForHeyJarvis"
    nonisolated static let micOnlyKey = "micOnlyMode"
    nonisolated static let restoreKey = "micOnlyRestore"
    static let listenTitle = "Listen for “Hey Jarvis”"
    static let micOnlyTitle = "Mic Only Mode"
    static let talkTitle = "Push to Talk (⌃⌥J)"

    /// The user's own choice; nil while there is none.
    private(set) var listenChoice: Bool?
    private(set) var micOnly: Bool
    /// A voice is enrolled (VoiceprintStatus).
    var enrolled = false {
        didSet { if enrolled != oldValue { onChange?() } }
    }

    /// Hands-free listening should run.
    var listening: Bool { micOnly || (listenChoice ?? enrolled) }

    /// Listening may have changed: the app starts or stops it.
    @ObservationIgnored var onChange: (() -> Void)?
    /// The menu asked for Mic Only Mode on or off: the app hides or restores the window and the
    /// HUD, and calls `enterMicOnly` or `leaveMicOnly`.
    @ObservationIgnored var onMicOnly: ((Bool) -> Void)?
    /// The menu's Push to Talk.
    @ObservationIgnored var onTalk: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        listenChoice = defaults.object(forKey: Self.listenKey) as? Bool
        micOnly = defaults.bool(forKey: Self.micOnlyKey)
    }

    /// Whether the last launch left Mic Only Mode on (the chat window then stays closed at launch).
    nonisolated static func micOnlyAtLaunch(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: micOnlyKey)
    }

    /// The menu's "Listen for “Hey Jarvis”".
    func setListening(_ on: Bool) {
        guard !micOnly else { return }
        listenChoice = on
        defaults.set(on, forKey: Self.listenKey)
        onChange?()
    }

    /// Mic Only Mode on, keeping what to put back.
    func enterMicOnly(_ restore: MicOnlyRestore) {
        guard !micOnly else { return }
        if let data = try? JSONEncoder().encode(restore) { defaults.set(data, forKey: Self.restoreKey) }
        micOnly = true
        defaults.set(true, forKey: Self.micOnlyKey)
        onChange?()
    }

    /// Mic Only Mode off: the listening choice as it was, and what else to put back.
    @discardableResult
    func leaveMicOnly() -> MicOnlyRestore? {
        guard micOnly else { return nil }
        let restore = (defaults.data(forKey: Self.restoreKey)).flatMap { try? JSONDecoder().decode(MicOnlyRestore.self, from: $0) }
        micOnly = false
        defaults.set(false, forKey: Self.micOnlyKey)
        defaults.removeObject(forKey: Self.restoreKey)
        listenChoice = restore?.listenChoice
        if let choice = restore?.listenChoice {
            defaults.set(choice, forKey: Self.listenKey)
        } else {
            defaults.removeObject(forKey: Self.listenKey)
        }
        onChange?()
        return restore
    }
}

/// M11 part 5, in the app menu and the menu-bar menu: "Listen for “Hey Jarvis”" (checked and
/// fixed on in Mic Only Mode), "Mic Only Mode", and Push to Talk, which in Mic Only Mode starts
/// a turn without bringing the window forward.
struct HandsFreeMenuItems: View {
    @Bindable var settings: HandsFreeSettings = .shared

    var body: some View {
        Toggle(HandsFreeSettings.listenTitle, isOn: Binding(get: { settings.listening },
                                                            set: { settings.setListening($0) }))
            .disabled(settings.micOnly)
        Toggle(HandsFreeSettings.micOnlyTitle, isOn: Binding(get: { settings.micOnly },
                                                             set: { settings.onMicOnly?($0) }))
        Button(HandsFreeSettings.talkTitle) { settings.onTalk?() }
    }
}
