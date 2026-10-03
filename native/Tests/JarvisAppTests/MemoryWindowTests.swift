import AppKit
import JarvisBrain
import JarvisChat
import JarvisCore
import SwiftUI
import Testing
@testable import JarvisApp

/// Batch C part 3: "Memory…" in both menus, and the window's view builds with and without a store.
@Suite("Batch C memory window, app side", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MemoryWindowTests {
    @Test("both menus list Memory…")
    func menus() throws {
        try BrainMenuTests.withDefaults { defaults in
            let menus = BrainMenuTests.menus(defaults, brain: BrainSetting(defaults: defaults, claudeEnabled: true))
            for menu in [menus.bar, menus.app] {
                menu.update()
                #expect(menu.items.contains { $0.title == MemoryEditor.menuTitle })
            }
        }
    }

    @Test("the window view lays out with no store attached")
    func view() {
        let host = NSHostingView(rootView: MemoryView(editor: MemoryEditor()))
        host.frame = NSRect(origin: .zero, size: MemoryWindowController.size)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }
}

/// Batch C part 4: "Learning Sources…" in both menus once the app hands its opener over; the
/// files toggle stays, and the window lays out.
@Suite("Batch C learning sources, app side", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct LearningSourcesWindowTests {
    @Test("both menus: Learning Sources…, the files toggle kept, Check AirPlay")
    func menus() throws {
        try BrainMenuTests.withDefaults { defaults in
            let learn = FileLearningConsent(defaults: defaults)
            let bar = NSHostingMenu(rootView: AppMenuItems(
                stopSpeaking: {}, speakEarly: SpeakEarlySetting(defaults: defaults), brain: BrainSetting(defaults: defaults, claudeEnabled: true),
                chatgpt: ChatGPTAccount(runner: BrainMenuTests.StatusOnly(answer: .signedOut)), learn: learn,
                showHUD: ShowHUDSetting(defaults: defaults), hud: HUDModel(), briefing: MorningBriefingSetting(defaults: defaults),
                updates: UpdateWatcher(folders: nil), voice: VoiceprintStatus(defaults: defaults), forgetVoice: {},
                openMemory: {}, quietHours: QuietHoursSetting(defaults: defaults, environment: [:]),
                openLearningSources: {}, checkAirPlay: {}, repairAirPlay: {}))
            bar.update()
            let titles = bar.items.map(\.title)
            #expect(titles.contains(LearningSources.menuTitle))
            #expect(titles.contains(FileLearningConsent.menuTitle))
            #expect(titles.contains(MemoryEditor.menuTitle))
            #expect(titles.contains(AirPlayMenuItems.checkTitle) && titles.contains(AirPlayMenuItems.repairTitle))
            #expect(titles.contains("Quiet Hours (22:00–07:00)"))
            #expect(!titles.contains("Learn From My Music"))
        }
    }

    struct NoPermissions: SourcePermissions {
        func status(_ id: LearningSourceID) -> SourcePermission { .notAsked }
        func request(_ id: LearningSourceID) async -> Bool { false }
    }

    @Test("the window lays out")
    func view() throws {
        try BrainMenuTests.withDefaults { defaults in
            let s = LearningSources(files: FileLearningConsent(defaults: defaults), media: MediaConsent(defaults: defaults),
                                    permissions: NoPermissions(), defaults: defaults)
            let host = NSHostingView(rootView: LearningSourcesView(sources: s, chooseFolders: {}))
            host.frame = NSRect(origin: .zero, size: LearningSourcesWindowController.size)
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.width > 0)
        }
    }
}

/// Batch C parts 3 and 4: pictures of both windows with invented content, written only when
/// UI1_SNAPSHOT_DIR is set (as the other UI1 snapshots).
@Suite("Batch C window snapshots", .serialized, .timeLimit(.minutes(1)), .enabled(if: UISnapshot.enabled))
@MainActor
struct BatchCSnapshotTests {
    @Test func memoryWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(store: try StateStore(root: root.path(percentEncoded: false), lease: nil))
        let now = Date().timeIntervalSince1970
        _ = memory.updateFacts { f in
            f.facts = [MemoryFact(id: "a", text: "The user is learning an invented instrument.", source: "conversation", created: now, updated: now, by: .claude),
                       MemoryFact(id: "b", text: "Avery's birthday is in invented May.", about: "Avery", relation: "sister", source: "manual", created: now, updated: now - 3600, by: .user),
                       MemoryFact(id: "c", text: "The user's most played artists are The Inventions and Mara Quill.", source: "music", created: now, updated: now - 7200, by: .local)]
            return true
        }
        let editor = MemoryEditor(store: memory)
        editor.reload()
        try await UISnapshot.write(MemoryView(editor: editor), size: MemoryWindowController.size, name: "batchc-memory-window")
    }

    @Test func learningSources() async throws {
        try await withDefaultsAsync { defaults in
            let s = LearningSources(files: FileLearningConsent(defaults: defaults), media: MediaConsent(defaults: defaults),
                                    permissions: LearningSourcesWindowTests.NoPermissions(), defaults: defaults)
            s.add(CustomLearningSource(kind: .appUsage, name: "Invented Notes", value: "/Applications/Invented Notes.app"))
            try await UISnapshot.write(LearningSourcesView(sources: s, chooseFolders: {}), size: LearningSourcesWindowController.size,
                                       name: "batchc-learning-sources")
        }
    }

    func withDefaultsAsync(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "jarvis-tests-snap-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        try await body(d)
    }
}
