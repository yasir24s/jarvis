import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import SwiftUI
import Testing

/// M11 part 5: "Listen for “Hey Jarvis”" and "Mic Only Mode": the settings' rules, kept in a
/// defaults suite of each test's own, and the items in both menus, built into real NSMenus.
@MainActor
@Suite("M11 hands-free settings and menus", .serialized)
struct HandsFreeSettingsTests {
    final class Changes {
        var count = 0
    }

    @Test("listening follows the voiceprint until the user chooses; the choice then stands, across launches")
    func listening() throws {
        try BrainMenuTests.withDefaults { defaults in
            let settings = HandsFreeSettings(defaults: defaults)
            let changes = Changes()
            settings.onChange = { changes.count += 1 }
            #expect(!settings.listening)
            settings.enrolled = true
            #expect(settings.listening && changes.count == 1)
            settings.setListening(false)
            #expect(!settings.listening && changes.count == 2)
            settings.enrolled = false
            settings.enrolled = true
            #expect(!settings.listening)
            let next = HandsFreeSettings(defaults: defaults)
            next.enrolled = true
            #expect(!next.listening, "the choice is kept")
            next.setListening(true)
            next.enrolled = false
            #expect(next.listening)
        }
    }

    @Test("Mic Only Mode listens whatever the choice, lasts across launches, and puts everything back")
    func micOnly() throws {
        try BrainMenuTests.withDefaults { defaults in
            let settings = HandsFreeSettings(defaults: defaults)
            settings.setListening(false)
            let restore = MicOnlyRestore(chatWindowOpen: true, showHUD: false, listenChoice: false)
            settings.enterMicOnly(restore)
            #expect(settings.micOnly && settings.listening)
            settings.setListening(false)
            #expect(settings.listening, "fixed on in Mic Only Mode")
            #expect(HandsFreeSettings.micOnlyAtLaunch(defaults: defaults))
            let relaunched = HandsFreeSettings(defaults: defaults)
            #expect(relaunched.micOnly && relaunched.listening)
            #expect(relaunched.leaveMicOnly() == restore)
            #expect(!relaunched.micOnly && !relaunched.listening)
            #expect(!HandsFreeSettings.micOnlyAtLaunch(defaults: defaults))
            #expect(relaunched.leaveMicOnly() == nil)
            // With no choice made before, none is made after: listening follows the voiceprint again.
            let fresh = HandsFreeSettings(defaults: defaults)
            fresh.setListening(true)
            defaults.removeObject(forKey: HandsFreeSettings.listenKey)
            let undecided = HandsFreeSettings(defaults: defaults)
            undecided.enterMicOnly(MicOnlyRestore(chatWindowOpen: false, showHUD: true, listenChoice: nil))
            #expect(undecided.leaveMicOnly()?.listenChoice == nil)
            #expect(undecided.listenChoice == nil)
            undecided.enrolled = true
            #expect(undecided.listening)
        }
    }

    static func titles(_ menu: NSMenu) -> [String] {
        menu.update()
        return menu.items.map(\.title)
    }

    @Test("both menus have the three items, after Show HUD")
    func inBothMenus() throws {
        try BrainMenuTests.withDefaults { defaults in
            let menus = BrainMenuTests.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true))
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let titles = Self.titles(menu)
                let hud = try #require(titles.firstIndex(of: ShowHUDSetting.menuTitle), "\(name): \(titles)")
                #expect(Array(titles[(hud + 1)...].prefix(3))
                        == [HandsFreeSettings.listenTitle, HandsFreeSettings.micOnlyTitle, HandsFreeSettings.talkTitle],
                        "\(name): \(titles)")
                try BrainMenuTests.write(BrainMenuTests.tree(menu), name: "m11-part5-\(name)")
            }
        }
    }

    @Test("the items show the settings, and choosing them reaches the app")
    func items() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-handsfree-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        do {
            _ = NSApplication.shared
            let settings = HandsFreeSettings(defaults: defaults)
            settings.enrolled = true
            var asked: [Bool] = []
            var talked = 0
            settings.onMicOnly = { asked.append($0) }
            settings.onTalk = { talked += 1 }
            let menu = NSHostingMenu(rootView: HandsFreeMenuItems(settings: settings))
            menu.update()
            func item(_ title: String) throws -> NSMenuItem { try #require(menu.items.first { $0.title == title }) }
            #expect(try item(HandsFreeSettings.listenTitle).state == .on)
            #expect(try item(HandsFreeSettings.listenTitle).isEnabled)
            #expect(try item(HandsFreeSettings.micOnlyTitle).state == .off)
            for title in [HandsFreeSettings.listenTitle, HandsFreeSettings.micOnlyTitle, HandsFreeSettings.talkTitle] {
                let it = try item(title)
                _ = NSApp.sendAction(try #require(it.action), to: it.target, from: it)
            }
            #expect(settings.listenChoice == false, "the Listen item turned it off")
            #expect(asked == [true])
            #expect(talked == 1)
            settings.enterMicOnly(MicOnlyRestore(chatWindowOpen: false, showHUD: true, listenChoice: false))
            // SwiftUI rebuilds the menu on a later turn of the run loop.
            for _ in 0..<100 where try item(HandsFreeSettings.micOnlyTitle).state != .on {
                try await Task.sleep(for: .milliseconds(10))
                menu.update()
            }
            #expect(try item(HandsFreeSettings.listenTitle).state == .on)
            #expect(try item(HandsFreeSettings.listenTitle).isEnabled == false)
            #expect(try item(HandsFreeSettings.micOnlyTitle).state == .on)
        }
    }
}
