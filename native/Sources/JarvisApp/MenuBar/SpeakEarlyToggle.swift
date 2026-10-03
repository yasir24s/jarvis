import Foundation
import JarvisVoice
import Observation
import SwiftUI

/// V5: "Speak First Sentence Early", kept as `speakEarly` in the voice's defaults suite
/// (`SpeechQueue.defaultsSuite`) and off until the user switches it on. SpeechQueue reads the
/// stored value for each reply, so a switch holds from the next reply.
@MainActor
@Observable
final class SpeakEarlySetting {
    static let menuTitle = "Speak First Sentence Early"

    var isOn: Bool {
        didSet { defaults?.set(isOn, forKey: SpeechQueue.speakEarlyKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = UserDefaults(suiteName: SpeechQueue.defaultsSuite)) {
        self.defaults = defaults
        isOn = defaults?.object(forKey: SpeechQueue.speakEarlyKey) as? Bool ?? false
    }
}

/// V5: the "Speak First Sentence Early" item, with a checkmark while it is on, in the app menu
/// and the menu-bar menu.
struct SpeakEarlyToggle: View {
    @Bindable var setting: SpeakEarlySetting

    var body: some View {
        Toggle(SpeakEarlySetting.menuTitle, isOn: $setting.isOn)
    }
}
