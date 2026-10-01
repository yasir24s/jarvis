import Foundation
import JarvisBrain
import JarvisCore
@testable import JarvisChat
import JarvisTools
import Testing

/// U1 part 5: "Speak replies" is read for each reply, so a change made outside the menu holds
/// from the next one. In a UserDefaults suite of the test's own, never the app's.
@Suite("U1 the speak toggle is read for each reply", .timeLimit(.minutes(1)))
@MainActor
struct LiveSpeakSettingTests {
    @Test("a change to speakReplies made outside the menu holds from the next reply, and the menu shows it")
    func speakRepliesReadPerReply() async throws {
        let turn = await TurnContext(channel: .text).summary()
        let row = ChatMessage(role: .assistant, text: "Done, sir.", phase: .finished)
        try SpeakPolicyTests.withDefaults { defaults in
            let toggle = SpeakRepliesToggle(defaults: defaults)
            @MainActor func spoken() -> Bool {
                SpeakReplies.context(for: row, turn: turn, toggle: toggle, chatWindowIsKey: false,
                                     userIdleSeconds: 0).speakToggleOn
            }
            #expect(!toggle.isOn && !spoken())
            defaults.set(true, forKey: SpeakRepliesToggle.defaultsKey)   // as `defaults write` would
            #expect(spoken())
            #expect(toggle.isOn)
            defaults.set(false, forKey: SpeakRepliesToggle.defaultsKey)
            #expect(!spoken() && !toggle.isOn)
            // The menu's own switch still writes the setting.
            toggle.isOn = true
            #expect(defaults.bool(forKey: SpeakRepliesToggle.defaultsKey))
            #expect(spoken())
        }
    }
}
