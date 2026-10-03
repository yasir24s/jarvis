import Foundation
import JarvisVoice
import Observation
import SwiftUI

/// V5: "Speak First Sentence Early", kept as `speakEarly` in the voice's defaults suite
/// (`SpeechQueue.defaultsSuite`) and off until the user switches it on. SpeechQueue reads the
/// stored value for each reply, so a switch holds from the next reply. V6: the item shows only
/// while F5 is the voice in use (`applies`); Qwen streams, so its first audio comes within a second
/// and the setting is moot.
@MainActor
@Observable
final class SpeakEarlySetting {
    static let menuTitle = "Speak First Sentence Early"

    var isOn: Bool {
        didSet { defaults?.set(isOn, forKey: SpeechQueue.speakEarlyKey) }
    }

    /// V6: whether the voice in use is F5, the one engine the setting acts on. AppDelegate sets it
    /// from the voice once it is built, and again after every reply.
    var applies: Bool

    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: SpeechQueue.defaultsSuite)) {
        self.defaults = defaults
        isOn = defaults?.object(forKey: SpeechQueue.speakEarlyKey) as? Bool ?? false
        applies = VoiceEngineChoice.choice(in: defaults) == .f5
    }
}

/// V5: the "Speak First Sentence Early" item, with a checkmark while it is on, in the app menu
/// and the menu-bar menu.
struct SpeakEarlyToggle: View {
    @Bindable var setting: SpeakEarlySetting

    var body: some View {
        if setting.applies {
            Toggle(SpeakEarlySetting.menuTitle, isOn: $setting.isOn)
        }
    }
}
