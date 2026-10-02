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

    @Test("JARVIS_USE_CLAUDE=0: On-device is shown, the item is off, and the help says why; the stored pick is kept")
    func forcedOnDevice() throws {
        try SpeakPolicyTests.withDefaults { defaults in
            let setting = BrainSetting(defaults: defaults, claudeEnabled: false)
            #expect(setting.claudeOff)
            #expect(setting.shown == .onDevice)
            #expect(setting.choice == .claude)
            #expect(setting.help == BrainSetting.forcedHelp)
            #expect(BrainSetting.forcedHelp.contains("JARVIS_USE_CLAUDE=0"))
        }
    }

    @Test("the item's names, and the help states that only replies follow it")
    func strings() {
        #expect(BrainSetting.menuTitle == "Brain")
        #expect(BrainChoice.allCases.map(BrainSetting.title) == ["Claude", "On-device"])
        for help in [BrainSetting.help, BrainSetting.forcedHelp] {
            #expect(help.contains("File reading, the memory writer and the persona writer keep their own routes."))
        }
    }
}
