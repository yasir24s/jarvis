import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import JarvisVoice
import SwiftUI
import Testing

/// V5: "Speak First Sentence Early" in both menus, off until switched on, kept as `speakEarly`;
/// and the queue's two parts as the app's own sentence splitter makes them. V6: the item shows only
/// while F5 is the voice (`voiceEngine` set to `f5`); with Qwen it is hidden.
@MainActor
@Suite("V5 Speak First Sentence Early menu item", .serialized)
struct SpeakEarlyMenuTests {
    static func menus(_ defaults: UserDefaults, setting: SpeakEarlySetting) -> VoiceMenuTests.Menus {
        _ = NSApplication.shared
        let speak = SpeakRepliesToggle(defaults: defaults)
        let brain = BrainSetting(defaults: defaults, claudeEnabled: true)
        let chatgpt = ChatGPTAccount(runner: BrainMenuTests.StatusOnly(answer: .signedOut))
        let learn = FileLearningConsent(defaults: defaults)
        let showHUD = ShowHUDSetting(defaults: defaults)
        let hud = HUDModel()
        let updates = UpdateWatcher(folders: nil)
        let status = VoiceprintStatus(defaults: defaults)
        #if DEBUG
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: setting, brain: brain,
                              chatgpt: chatgpt, learn: learn, showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates,
                              voice: status, forgetVoice: {}, stopSpeaking: {}, testConfirmation: {})
        #else
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: setting, brain: brain,
                              chatgpt: chatgpt, learn: learn, showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates,
                              voice: status, forgetVoice: {}, stopSpeaking: {})
        #endif
        let app = AppMenuItems(stopSpeaking: {}, speakEarly: setting, brain: brain, chatgpt: chatgpt, learn: learn,
                               showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates, voice: status, forgetVoice: {})
        return VoiceMenuTests.Menus(bar: NSHostingMenu(rootView: bar), app: NSHostingMenu(rootView: app))
    }

    /// Waits for SwiftUI's next menu update to show the item in `state`.
    static func shows(_ menu: NSMenu, _ state: NSControl.StateValue) async throws -> NSMenuItem? {
        for _ in 0 ..< 200 where VoiceMenuTests.item(menu, SpeakEarlySetting.menuTitle)?.state != state {
            try await Task.sleep(for: .milliseconds(5))
        }
        return VoiceMenuTests.item(menu, SpeakEarlySetting.menuTitle).flatMap { $0.state == state ? $0 : nil }
    }

    @Test func offByDefaultInBothMenusAndChoosingItSwitchesItOn() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-early-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("f5", forKey: VoiceEngineChoice.key)   // V6: the item is F5's

        let setting = SpeakEarlySetting(defaults: defaults)
        #expect(setting.applies)
        #expect(!setting.isOn)
        #expect(!SpeechQueue.speakEarly(in: defaults), "nothing stored: the queue reads it as off")
        let menus = Self.menus(defaults, setting: setting)
        menus.bar.update()
        menus.app.update()
        // Menu bar: right after Speak replies. App menu: right after Stop Speaking.
        let bar = menus.bar.items.map(\.title)
        let speak = try #require(bar.firstIndex(of: "Speak replies"))
        #expect(bar[speak + 1] == SpeakEarlySetting.menuTitle)
        let app = menus.app.items.map(\.title)
        let stop = try #require(app.firstIndex(of: "Stop Speaking"))
        #expect(app[stop + 1] == SpeakEarlySetting.menuTitle)
        for menu in [menus.bar, menus.app] {
            #expect(try await Self.shows(menu, .off) != nil, "unticked by default")
        }

        let item = try #require(VoiceMenuTests.item(menus.bar, SpeakEarlySetting.menuTitle))
        NSApp.sendAction(try #require(item.action), to: item.target, from: item)
        #expect(setting.isOn)
        #expect(defaults.object(forKey: SpeechQueue.speakEarlyKey) as? Bool == true)
        #expect(SpeechQueue.speakEarly(in: defaults))
        for menu in [menus.bar, menus.app] {
            #expect(try await Self.shows(menu, .on) != nil, "both menus follow")
        }
        #expect(SpeakEarlySetting(defaults: defaults).isOn, "kept across launches")
    }

    /// V8: with Qwen, the voice by default, the item is in both menus again, off by default, and
    /// kept under the same key. (V6 hid it while Qwen spoke.)
    @Test func shownWhileQwenIsTheVoice() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-early-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let setting = SpeakEarlySetting(defaults: defaults)
        #expect(setting.applies)
        #expect(!setting.isOn)
        let menus = Self.menus(defaults, setting: setting)
        menus.bar.update()
        menus.app.update()
        for menu in [menus.bar, menus.app] {
            #expect(try await Self.shows(menu, .off) != nil)
        }
        setting.isOn = true
        #expect(defaults.object(forKey: SpeechQueue.speakEarlyKey) as? Bool == true)
    }

    /// The parts as the app makes them, with the app's own `SentenceSplitter` (`AppVoice.sentences`).
    @Test func thePartsWithTheAppsSentenceSplitter() {
        let first = "I've taken the liberty of silencing your notifications, sir."
        let rest = "Shall I also alert the fire brigade? Or would you rather handle that one yourself?"
        #expect(SpeechQueue.parts(first + " " + rest, early: true, sentences: AppVoice.sentences) == [first, rest])
        #expect(SpeechQueue.parts(first + " " + rest, early: false, sentences: AppVoice.sentences) == [first + " " + rest])
        #expect(SpeechQueue.parts(first, early: true, sentences: AppVoice.sentences) == [first])
        let short = "Very good, sir. The meeting has moved to three."
        #expect(SpeechQueue.parts(short, early: true, sentences: AppVoice.sentences) == [short])
    }
}
