import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import SwiftUI
import Testing

/// M9a part 7 and B2: the "Brain" item in both menus, built into real NSMenus by SwiftUI
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

    /// B2 part 6: a sign-in runner that answers `status` and never runs anything.
    struct StatusOnly: ChatGPTSignInRunning {
        let answer: CodexLoginStatus
        func status() async -> CodexLoginStatus { answer }
        func signIn() async -> CodexSignInResult { .cancelled }
    }

    static func menus(_ defaults: UserDefaults, brain: BrainSetting,
                      chatgpt: ChatGPTAccount = ChatGPTAccount(runner: StatusOnly(answer: .signedOut))) -> Menus {
        _ = NSApplication.shared
        let speak = SpeakRepliesToggle(defaults: defaults)
        let speakEarly = SpeakEarlySetting(defaults: defaults)
        let learn = FileLearningConsent(defaults: defaults)
        let showHUD = ShowHUDSetting(defaults: defaults)
        let hud = HUDModel()
        let updates = UpdateWatcher(folders: nil)
        #if DEBUG
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt,
                              learn: learn, showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates,
                              voice: VoiceprintStatus(defaults: defaults), forgetVoice: {}, stopSpeaking: {},
                              testConfirmation: {})
        #else
        let bar = MenuBarMenu(model: AppModel(), chat: ChatViewModel(), speak: speak, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt,
                              learn: learn, showHUD: showHUD, hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates,
                              voice: VoiceprintStatus(defaults: defaults), forgetVoice: {}, stopSpeaking: {})
        #endif
        let app = AppMenuItems(stopSpeaking: {}, speakEarly: speakEarly, brain: brain, chatgpt: chatgpt, learn: learn, showHUD: showHUD,
                               hud: hud, briefing: MorningBriefingSetting(defaults: defaults), updates: updates, voice: VoiceprintStatus(defaults: defaults), forgetVoice: {})
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
                #expect(items.map(\.title) == ["Claude", "ChatGPT", "On-device"], "\(name)")
                #expect(items.allSatisfy { $0.isEnabled }, "\(name)")
                #expect(items.map { $0.state == .on } == BrainChoice.allCases.map { $0 == choice }, "\(name)")
                let brainItem = try #require(menu.items.first { $0.title == BrainSetting.menuTitle })
                #expect(brainItem.isEnabled, "\(name)")
                try Self.write(Self.tree(menu), name: "m9-part7-\(name)-\(choice.rawValue)")
            }
            // In the menu-bar menu it sits right after Speak replies and V5's Speak First Sentence Early.
            let titles = menus.bar.items.map(\.title)
            let speak = try #require(titles.firstIndex(of: "Speak replies"))
            #expect(titles.indices.contains(speak + 2) && titles[speak + 1] == SpeakEarlySetting.menuTitle
                    && titles[speak + 2] == BrainSetting.menuTitle)
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
        #expect(Self.brainItems(menus.app)?.map { $0.state == .on } == [false, false, true])
        #expect(Self.brainItems(menus.bar)?.map { $0.state == .on } == [false, false, true])

        // B2: and ChatGPT, from the app menu this time.
        let chatgpt = try #require(Self.brainItems(menus.app)?.first { $0.title == "ChatGPT" })
        let pick = try #require(chatgpt.action)
        NSApp.sendAction(pick, to: chatgpt.target, from: chatgpt)
        #expect(brain.choice == .chatgpt)
        #expect(BrainSetting.stored(in: defaults) == .chatgpt)
        for _ in 0..<200 where Self.brainItems(menus.bar)?[1].state != .on {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(Self.brainItems(menus.bar)?.map { $0.state == .on } == [false, true, false])
        #expect(Self.brainItems(menus.app)?.map { $0.state == .on } == [false, true, false])
    }

    @Test("JARVIS_USE_CLAUDE=0 and JARVIS_USE_CHATGPT=0: On-device checked, the item off, the reason in its help")
    func forced() throws {
        try Self.withDefaults { defaults in
            let brain = BrainSetting(defaults: defaults, claudeEnabled: false, chatgptEnabled: false)
            let menus = Self.menus(defaults, brain: brain)
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let items = try #require(Self.brainItems(menu), "\(name)")
                #expect(items.map { $0.state == .on } == [false, false, true], "\(name)")
                let brainItem = try #require(menu.items.first { $0.title == BrainSetting.menuTitle })
                let reachable = brainItem.isEnabled && items.contains { $0.isEnabled }
                #expect(!reachable, "\(name): \(Self.tree(menu))")
                #expect(brainItem.toolTip == BrainSetting.forcedHelp, "\(name)")
                try Self.write(Self.tree(menu), name: "m9-part7-\(name)-forced-on-device")
            }
        }
    }

    /// B2: one brain switched off: its entry is disabled and a pick of it shows On-device; the
    /// other two stay reachable, and the help names the switch.
    @Test("one brain off for the launch: its entry off, a pick of it on On-device", arguments: [BrainChoice.claude, .chatgpt])
    func oneBrainOff(_ off: BrainChoice) throws {
        try Self.withDefaults { defaults in
            let brain = BrainSetting(defaults: defaults, claudeEnabled: off != .claude, chatgptEnabled: off != .chatgpt)
            brain.choice = off
            let menus = Self.menus(defaults, brain: brain)
            for (name, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
                let items = try #require(Self.brainItems(menu), "\(name)")
                #expect(items.map(\.title) == ["Claude", "ChatGPT", "On-device"], "\(name)")
                #expect(items.map { $0.state == .on } == [false, false, true], "\(name)")
                #expect(items.map(\.isEnabled) == BrainChoice.allCases.map { $0 != off }, "\(name): \(Self.tree(menu))")
                let brainItem = try #require(menu.items.first { $0.title == BrainSetting.menuTitle })
                #expect(brainItem.isEnabled, "\(name)")
                #expect(brainItem.toolTip == brain.help, "\(name)")
                try Self.write(Self.tree(menu), name: "b2-\(name)-\(off.rawValue)-off")
            }
        }
    }

    /// B2 part 6: the item right after Brain in both menus, in each state: a button to sign in
    /// (or to cancel while the browser flow runs), or a disabled line.
    @Test("the ChatGPT sign-in item after Brain, in each state", arguments: [
        (CodexLoginStatus.signedOut, "Sign in to ChatGPT…", true, "signed-out"),
        (.signedIn, "Signed in to ChatGPT", false, "signed-in"),
        (.unavailable("Codex CLI not found"), "Sign in to ChatGPT… (needs the ChatGPT app)", false, "no-codex"),
    ])
    func signInItem(_ status: CodexLoginStatus, _ title: String, _ enabled: Bool, _ name: String) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = ChatGPTAccount(runner: StatusOnly(answer: status))
        await account.refresh()
        let menus = Self.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true), chatgpt: account)
        for (menuName, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
            menu.update()
            let titles = menu.items.map(\.title)
            let brain = try #require(titles.firstIndex(of: BrainSetting.menuTitle), "\(menuName): \(Self.tree(menu))")
            #expect(titles.indices.contains(brain + 1) && titles[brain + 1] == title, "\(menuName): \(Self.tree(menu))")
            let item = menu.items[brain + 1]
            #expect(item.isEnabled == enabled, "\(menuName): \(Self.tree(menu))")
            #expect(item.toolTip == account.help, "\(menuName)")
            try Self.write(Self.tree(menu), name: "b2-part6-\(menuName)-\(name)")
        }
    }

    /// While a sign-in runs the item is "Cancel ChatGPT Sign-in", and choosing it cancels.
    @Test("signing in: the item cancels")
    func signingInItem() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = folder.appending(path: "defaults").path(percentEncoded: false)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let account = ChatGPTAccount(runner: HangingSignIn())
        await account.refresh()
        account.signIn()
        let menus = Self.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true), chatgpt: account)
        for (menuName, menu) in [("menu-bar", menus.bar), ("app-menu", menus.app)] {
            menu.update()
            let item = try #require(menu.items.first { $0.title == ChatGPTAccount.cancelTitle }, "\(menuName): \(Self.tree(menu))")
            #expect(item.isEnabled, "\(menuName)")
            try Self.write(Self.tree(menu), name: "b2-part6-\(menuName)-signing-in")
        }
        let cancel = try #require(menus.bar.items.first { $0.title == ChatGPTAccount.cancelTitle })
        let action = try #require(cancel.action)
        NSApp.sendAction(action, to: cancel.target, from: cancel)
        await account.waitForSignIn()
        #expect(account.state == .signedOut)
    }

    /// A sign-in that waits until it is cancelled.
    struct HangingSignIn: ChatGPTSignInRunning {
        func status() async -> CodexLoginStatus { .signedOut }
        func signIn() async -> CodexSignInResult {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            return .cancelled
        }
    }
}
