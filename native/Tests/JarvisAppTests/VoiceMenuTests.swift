import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisVoice
import SwiftUI
import Testing

/// M10 parts 4 and 5 in both menus, built into real NSMenus from the app's views: "Set Up
/// JARVIS…", the voiceprint's line and "Forget My Voice…", and the confirmation before the
/// voiceprint goes. With UI1_SNAPSHOT_DIR set, each menu's item tree is written there as text.
@MainActor
@Suite("M10 voice menu items", .serialized)
struct VoiceMenuTests {
    struct Menus {
        let bar: NSMenu
        let app: NSMenu
    }

    static func menus(_ defaults: UserDefaults, status: VoiceprintStatus, forget: @escaping () -> Void) -> Menus {
        _ = NSApplication.shared
        let speak = SpeakRepliesToggle(defaults: defaults)
        let speakEarly = SpeakEarlySetting(defaults: defaults)
        let brain = BrainSetting(defaults: defaults, claudeEnabled: true)
        let chatgpt = ChatGPTAccount(runner: BrainMenuTests.StatusOnly(answer: .signedOut))
        let learn = FileLearningConsent(defaults: defaults)
        let showHUD = ShowHUDSetting(defaults: defaults)
        let hud = HUDModel()
        let updates = UpdateWatcher(folders: nil)
        #if DEBUG
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt, learn: learn,
                              showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates, voice: status, forgetVoice: forget,
                              stopSpeaking: {}, testConfirmation: {})
        #else
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt, learn: learn,
                              showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates, voice: status, forgetVoice: forget,
                              stopSpeaking: {})
        #endif
        let app = AppMenuItems(stopSpeaking: {}, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt, learn: learn, showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults),
                               updates: updates, voice: status, forgetVoice: forget)
        return Menus(bar: NSHostingMenu(rootView: bar), app: NSHostingMenu(rootView: app))
    }

    static func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? {
        menu.update()
        return menu.items.first { $0.title == title }
    }

    /// Waits for SwiftUI's next menu update to show `title`.
    static func shows(_ menu: NSMenu, _ title: String) async throws -> NSMenuItem? {
        for _ in 0 ..< 200 where item(menu, title) == nil { try await Task.sleep(for: .milliseconds(5)) }
        return item(menu, title)
    }

    @Test func notEnrolledShowsTheLineAndForgetIsOff() throws {
        try BrainMenuTests.withDefaults { defaults in
            let status = VoiceprintStatus(defaults: defaults)
            status.loaded(enrolled: false)
            let menus = Self.menus(defaults, status: status, forget: {})
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                #expect(Self.item(menu, SetUpItem.title) != nil, "\(name): \(BrainMenuTests.tree(menu))")
                #expect(Self.item(menu, "Voice: not enrolled") != nil, "\(name)")
                let forget = try #require(Self.item(menu, ForgetMyVoice.menuTitle), "\(name)")
                #expect(!forget.isEnabled, "\(name): nothing to forget")
                try BrainMenuTests.write(BrainMenuTests.tree(menu), name: "m10-part5-\(name)-not-enrolled")
            }
            // In the menu-bar menu the three sit after Open Chat, and Brain still follows Speak replies
            // (V5's Speak First Sentence Early, between them, is hidden while Qwen is the voice: V6).
            let titles = menus.bar.items.map(\.title)
            let open = try #require(titles.firstIndex(of: "Open Chat"))
            #expect(Array(titles[open + 1 ... open + 3]) == [SetUpItem.title, "Voice: not enrolled", ForgetMyVoice.menuTitle])
            let speak = try #require(titles.firstIndex(of: "Speak replies"))
            #expect(titles[speak + 1] == BrainSetting.menuTitle)
        }
    }

    @Test func enrolledEnablesForgetAndItCallsTheFlow() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let status = VoiceprintStatus(defaults: defaults)
        status.loaded(enrolled: false)
        var pressed = 0
        let menus = Self.menus(defaults, status: status, forget: { pressed += 1 })
        status.loaded(enrolled: true)
        for (label, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
            #expect(try await Self.shows(menu, "Voice: enrolled") != nil, "\(label) follows the status")
            let forget = try #require(Self.item(menu, ForgetMyVoice.menuTitle))
            #expect(forget.isEnabled, "\(label)")
            let action = try #require(forget.action)
            NSApp.sendAction(action, to: forget.target, from: forget)
            try BrainMenuTests.write(BrainMenuTests.tree(menu), name: "m10-part5-\(label)-enrolled")
        }
        #expect(pressed == 2)
    }

    /// The confirmation comes first: Cancel leaves the files; Forget My Voice deletes the
    /// voiceprint and the one kept before it, and the menus say not enrolled.
    @Test func forgetAsksFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let url = folder.appending(path: "voiceprint.npy")
        let previous = Voiceprint.previousURL(for: url)
        try Voiceprint.save((0 ..< 256).map { Float($0) / 256 }, to: url)
        try Data(contentsOf: url).write(to: previous)
        // The encoder is never used to forget, so it needs no vendored files.
        let encoder = SpeakerEncoder(assets: .checkout(vendor: folder, buildProducts: folder))
        let voiceprint = Voiceprint(url: url, encoder: encoder, research: NoCounting(), log: { _ in })
        await voiceprint.load()
        let status = VoiceprintStatus(defaults: defaults)
        status.recorded(at: Date())
        #expect(status.enrolled && status.menuLine == "Voice: enrolled")

        var asked = 0
        #expect(await !ForgetMyVoice.run(ask: { asked += 1; return false }, voiceprint: voiceprint, status: status))
        let stillEnrolled = await voiceprint.isEnrolled
        #expect(asked == 1 && status.enrolled && stillEnrolled)
        #expect(FileManager.default.fileExists(atPath: url.path) && FileManager.default.fileExists(atPath: previous.path))

        #expect(await ForgetMyVoice.run(ask: { asked += 1; return true }, voiceprint: voiceprint, status: status))
        #expect(asked == 2 && !status.enrolled && status.menuLine == "Voice: not enrolled")
        #expect(await !voiceprint.isEnrolled)
        #expect(!FileManager.default.fileExists(atPath: url.path) && !FileManager.default.fileExists(atPath: previous.path))
        #expect(defaults.object(forKey: VoiceprintStatus.recordedKey) == nil)

        // With nothing enrolled it does not ask.
        #expect(await !ForgetMyVoice.run(ask: { asked += 1; return true }, voiceprint: voiceprint, status: status))
        #expect(asked == 2)
    }

    struct NoCounting: ResearchCounting {
        func bump(_ key: String, by n: Int) {}
    }
}
