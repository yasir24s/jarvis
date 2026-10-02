import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import SwiftUI
import Testing

/// M9a part 7: the "Brain" item in both menus, built into real NSMenus by SwiftUI
/// (`NSHostingMenu`) from the same views the app uses: the menu-bar menu and the app menu's
/// items. Each test's settings live in a defaults suite of its own. With `UI1_SNAPSHOT_DIR` set,
/// each menu's item tree is written there as text, one file per menu and choice.
@MainActor
@Suite("M9 brain menu", .serialized)
struct BrainMenuTests {
    /// A defaults suite in a temp folder, removed afterwards (as SpeakPolicyTests does).
    static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// The menu's items, one line each: [x] when checked, "(off)" when disabled, the tooltip.
    static func tree(_ menu: NSMenu, indent: String = "") -> [String] {
        menu.update()
        var out: [String] = []
        for item in menu.items {
            if item.isSeparatorItem {
                out.append(indent + "-----")
                continue
            }
            let mark = item.state == .on ? "[x] " : "[ ] "
            let off = item.isEnabled ? "" : " (off)"
            let tip = item.toolTip.map { " {help: \($0)}" } ?? ""
            out.append(indent + mark + item.title + off + tip)
            if let sub = item.submenu { out += tree(sub, indent: indent + "    ") }
        }
        return out
    }

    struct Menus {
        let bar: NSMenu
        let app: NSMenu
    }

    static func menus(_ defaults: UserDefaults, brain: BrainSetting) -> Menus {
        _ = NSApplication.shared
        let speak = SpeakRepliesToggle(defaults: defaults)
        let learn = FileLearningConsent(defaults: defaults)
        let showHUD = ShowHUDSetting(defaults: defaults)
        let hud = HUDModel()
        let updates = UpdateWatcher(folders: nil)
        #if DEBUG
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, brain: brain, learn: learn,
                              showHUD: showHUD, hud: hud, updates: updates, voice: VoiceprintStatus(defaults: defaults),
                              forgetVoice: {}, stopSpeaking: {}, testConfirmation: {})
        #else
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, brain: brain, learn: learn,
                              showHUD: showHUD, hud: hud, updates: updates, voice: VoiceprintStatus(defaults: defaults),
                              forgetVoice: {}, stopSpeaking: {})
        #endif
        let app = AppMenuItems(stopSpeaking: {}, brain: brain, learn: learn, showHUD: showHUD, hud: hud,
                               updates: updates, voice: VoiceprintStatus(defaults: defaults), forgetVoice: {})
        return Menus(bar: NSHostingMenu(rootView: bar), app: NSHostingMenu(rootView: app))
    }

    /// The Brain item's submenu in `menu`.
    static func brainItems(_ menu: NSMenu) -> [NSMenuItem]? {
        menu.update()
        return menu.items.first { $0.title == BrainSetting.menuTitle }?.submenu?.items
    }

    static func write(_ lines: [String], name: String) throws {
        guard let folder = UISnapshot.folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "\(name).txt")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("M9 menu snapshot \(url.path)")
    }

    @Test("both menus show Brain next to the other settings, with a checkmark on the choice", arguments: BrainChoice.allCases)
    func eachChoice(_ choice: BrainChoice) throws {
        try Self.withDefaults { defaults in
            let brain = BrainSetting(defaults: defaults, claudeEnabled: true)
            brain.choice = choice
            let menus = Self.menus(defaults, brain: brain)
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let items = try #require(Self.brainItems(menu), "\(name) has no Brain item: \(Self.tree(menu))")
                #expect(items.map(\.title) == ["Claude", "On-device"], "\(name)")
                #expect(items.map { $0.state == .on } == BrainChoice.allCases.map { $0 == choice }, "\(name)")
                let brainItem = try #require(menu.items.first { $0.title == BrainSetting.menuTitle })
                #expect(brainItem.isEnabled, "\(name)")
                try Self.write(Self.tree(menu), name: "m9-part7-\(name)-\(choice.rawValue)")
            }
            // In the menu-bar menu it sits right after Speak replies.
            let titles = menus.bar.items.map(\.title)
            let speak = try #require(titles.firstIndex(of: "Speak replies"))
            #expect(titles.indices.contains(speak + 1) && titles[speak + 1] == BrainSetting.menuTitle)
        }
    }

    @Test("choosing in the menu changes the setting, and both menus follow")
    func choosing() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        let brain = BrainSetting(defaults: defaults, claudeEnabled: true)
        let menus = Self.menus(defaults, brain: brain)
        let onDevice = try #require(Self.brainItems(menus.bar)?.first { $0.title == "On-device" })
        let action = try #require(onDevice.action)
        NSApp.sendAction(action, to: onDevice.target, from: onDevice)
        #expect(brain.choice == .onDevice)
        #expect(BrainSetting.stored(in: defaults) == .onDevice)
        // SwiftUI redraws the menus on its next update.
        for _ in 0..<200 where Self.brainItems(menus.app)?.last?.state != .on {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Self.brainItems(menus.app)?.map { $0.state == .on } == [false, true])
        #expect(Self.brainItems(menus.bar)?.map { $0.state == .on } == [false, true])
    }

    @Test("JARVIS_USE_CLAUDE=0: On-device checked, the item off, the reason in its help")
    func forced() throws {
        try Self.withDefaults { defaults in
            let brain = BrainSetting(defaults: defaults, claudeEnabled: false)
            let menus = Self.menus(defaults, brain: brain)
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let items = try #require(Self.brainItems(menu), "\(name)")
                #expect(items.map { $0.state == .on } == [false, true], "\(name)")
                let brainItem = try #require(menu.items.first { $0.title == BrainSetting.menuTitle })
                let reachable = brainItem.isEnabled && items.contains { $0.isEnabled }
                #expect(!reachable, "\(name): \(Self.tree(menu))")
                try Self.write(Self.tree(menu), name: "m9-part7-\(name)-forced-on-device")
            }
        }
    }
}
