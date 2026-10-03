import AppKit
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import Testing

/// F1: "Morning Briefing" in both menus, after the hands-free items, checked by default and
/// following the `morningBriefing` setting.
@Suite("F1 briefing menu item", .serialized)
@MainActor
struct BriefingMenuTests {
    @Test func inBothMenusOnByDefault() throws {
        try BrainMenuTests.withDefaults { defaults in
            let menus = BrainMenuTests.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true))
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let titles = HandsFreeSettingsTests.titles(menu)
                let talk = try #require(titles.firstIndex(of: HandsFreeSettings.talkTitle), "\(name): \(titles)")
                #expect(titles[talk + 1] == MorningBriefingSetting.menuTitle, "\(name): \(titles)")
                #expect(VoiceMenuTests.item(menu, MorningBriefingSetting.menuTitle)?.state == .on, "\(name)")
            }
        }
    }

    @Test func showsTheStoredSetting() throws {
        try BrainMenuTests.withDefaults { defaults in
            defaults.set(false, forKey: MorningBriefingSetting.defaultsKey)
            let menus = BrainMenuTests.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true))
            #expect(VoiceMenuTests.item(menus.bar, MorningBriefingSetting.menuTitle)?.state == .off)
            #expect(VoiceMenuTests.item(menus.app, MorningBriefingSetting.menuTitle)?.state == .off)
        }
    }
}
