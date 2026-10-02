import Foundation
import JarvisBrain
@testable import JarvisChat
import Testing

/// M9a part 7: the menus' Brain item, kept in UserDefaults like Speak replies. Each test uses a
/// defaults suite of its own in a temp folder (SpeakPolicyTests.withDefaults), never the app's.
@MainActor
@Suite("M9 brain setting")
struct BrainSettingTests {
    @Test("Claude until the user picks otherwise, and the pick survives a relaunch")
    func persists() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            let first = BrainSetting(defaults: defaults, claudeEnabled: true)
            #expect(first.choice == .claude && first.shown == .claude)
            #expect(BrainSetting.stored(in: defaults) == .claude)
            first.choice = .onDevice
            #expect(defaults.string(forKey: BrainSetting.defaultsKey) == "onDevice")
            #expect(BrainSetting.stored(in: defaults) == .onDevice)
            let relaunched = BrainSetting(defaults: defaults, claudeEnabled: true)
            #expect(relaunched.choice == .onDevice && relaunched.shown == .onDevice)
            #expect(!relaunched.claudeOff)
            #expect(relaunched.help == BrainSetting.help)
        }
    }

    @Test("an unknown stored value reads as Claude; a change made outside the menu shows after refresh")
    func readsDefaults() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            defaults.set("gpt", forKey: BrainSetting.defaultsKey)
            let setting = BrainSetting(defaults: defaults, claudeEnabled: true)
            #expect(setting.choice == .claude)
            defaults.set("onDevice", forKey: BrainSetting.defaultsKey)
            #expect(setting.choice == .claude)
            setting.refresh()
            #expect(setting.choice == .onDevice)
        }
    }

    @Test("JARVIS_USE_CLAUDE=0: a Claude pick shows On-device, Claude's entry is off, the help says why; the pick is kept")
    func forcedOnDevice() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            let setting = BrainSetting(defaults: defaults, claudeEnabled: false)
            #expect(setting.claudeOff && !setting.chatgptOff && !setting.allOff)
            #expect(setting.isOff(.claude) && !setting.isOff(.chatgpt) && !setting.isOff(.onDevice))
            #expect(setting.shown == .onDevice)
            #expect(setting.choice == .claude)
            #expect(setting.help == BrainSetting.claudeOffHelp)
            #expect(BrainSetting.claudeOffHelp.contains("JARVIS_USE_CLAUDE=0"))
            #expect(BrainSetting.forcedHelp.contains("JARVIS_USE_CLAUDE=0"))
            // ChatGPT can still be picked, and shows.
            setting.choice = .chatgpt
            #expect(setting.shown == .chatgpt)
        }
    }

    @Test("B2: JARVIS_USE_CHATGPT=0 does the same for ChatGPT; with both off the item is off on On-device")
    func chatgptOff() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            defaults.set("chatgpt", forKey: BrainSetting.defaultsKey)
            let setting = BrainSetting(defaults: defaults, claudeEnabled: true, chatgptEnabled: false)
            #expect(setting.choice == .chatgpt && setting.shown == .onDevice)
            #expect(setting.isOff(.chatgpt) && !setting.isOff(.claude) && !setting.allOff)
            #expect(setting.help == BrainSetting.chatgptOffHelp)
            #expect(BrainSetting.chatgptOffHelp.contains("JARVIS_USE_CHATGPT=0"))
            let both = BrainSetting(defaults: defaults, claudeEnabled: false, chatgptEnabled: false)
            #expect(both.allOff && both.shown == .onDevice)
            #expect(both.help == BrainSetting.forcedHelp)
            #expect(BrainSetting.forcedHelp.contains("JARVIS_USE_CHATGPT=0"))
        }
    }

    @Test("B2: a ChatGPT pick is stored as \"chatgpt\" and survives a relaunch")
    func chatgptPersists() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            let first = BrainSetting(defaults: defaults, claudeEnabled: true)
            first.choice = .chatgpt
            #expect(defaults.string(forKey: BrainSetting.defaultsKey) == "chatgpt")
            #expect(BrainSetting.stored(in: defaults) == .chatgpt)
            let relaunched = BrainSetting(defaults: defaults, claudeEnabled: true)
            #expect(relaunched.choice == .chatgpt && relaunched.shown == .chatgpt)
            #expect(relaunched.help == BrainSetting.help)
        }
    }

    @Test("the item's names, and the help states that only replies follow it")
    func strings() {
        #expect(BrainSetting.menuTitle == "Brain")
        #expect(BrainChoice.allCases.map(BrainSetting.title) == ["Claude", "ChatGPT", "On-device"])
        for help in [BrainSetting.help, BrainSetting.claudeOffHelp, BrainSetting.chatgptOffHelp, BrainSetting.forcedHelp] {
            #expect(help.contains("File reading, the memory writer and the persona writer keep their own routes."))
        }
        #expect(BrainSetting.help.contains("ChatGPT (through Codex, on your ChatGPT sign-in)"))
    }
}
