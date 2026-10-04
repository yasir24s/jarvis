import Foundation
import JarvisVoice
import Observation
import SwiftUI

/// V5: "Speak First Sentence Early", kept as `speakEarly` in the voice's defaults suite
/// (`SpeechQueue.defaultsSuite`) and off until the user switches it on. SpeechQueue reads the
/// stored value for each reply, so a switch holds from the next reply. V6 showed the item only
/// while F5 was the voice in use. V8: it shows for Qwen too, where it has Qwen start speaking
/// once the reply's first sentence has streamed in, while the brain is still writing the rest.
@MainActor
@Observable
final class SpeakEarlySetting {
    static let menuTitle = "Speak First Sentence Early"

    var isOn: Bool {
        didSet { defaults?.set(isOn, forKey: SpeechQueue.speakEarlyKey) }
    }

    /// Whether the setting acts on the voice in use (V8: both voices do). AppDelegate sets it
    /// from the voice once it is built, and again after every reply.
    var applies: Bool

    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = SpeechQueue.sharedDefaults) {
        self.defaults = defaults
        isOn = defaults?.object(forKey: SpeechQueue.speakEarlyKey) as? Bool ?? false
        applies = true
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
