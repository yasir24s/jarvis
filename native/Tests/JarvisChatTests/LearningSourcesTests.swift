import Foundation
import JarvisChat
import JarvisCore
import Synchronization
import Testing

/// Batch C part 4: the Learning Sources logic with fake permissions and a temp defaults suite and
/// state folder. No macOS permission is asked.
@Suite("Batch C learning sources", .timeLimit(.minutes(1)))
@MainActor
struct LearningSourcesTests {
    final class Permissions: SourcePermissions, @unchecked Sendable {
        var allow: Set<LearningSourceID>
        private(set) var asked: [LearningSourceID] = []
        init(allow: Set<LearningSourceID>) { self.allow = allow }
        func status(_ id: LearningSourceID) -> SourcePermission { allow.contains(id) ? .granted : .notAsked }
        func request(_ id: LearningSourceID) async -> Bool {
            asked.append(id)
            return allow.contains(id)
        }
    }

    static func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let name = "jarvis-tests-learning-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        try await body(d)
    }

    @Test("every source starts off; switching on asks its permission; refused, it stays off")
    func switches() async throws {
        try await Self.withDefaults { d in
            let files = FileLearningConsent(defaults: d), media = MediaConsent(defaults: d)
            let perms = Permissions(allow: [.calendar, .music, .files])
            let s = LearningSources(files: files, media: media, permissions: perms, defaults: d)
            #expect(LearningSourceID.allCases.allSatisfy { !s.isOn($0) })
            #expect(await s.set(.calendar, on: true))
            #expect(s.isOn(.calendar) && perms.asked == [.calendar])
            #expect(!(await s.set(.contacts, on: true)))
            #expect(!s.isOn(.contacts) && s.status.contains("did not allow"))
            #expect(await s.set(.music, on: true))
            #expect(media.music)                      // the same switch as the media catalogue's
            #expect(await s.set(.files, on: true))
            #expect(files.isOn)                       // and the files toggle's
            #expect(await s.set(.calendar, on: false))
            #expect(perms.asked.count == 4)           // switching off asks nothing
            let again = LearningSources(files: files, media: media, permissions: perms, defaults: d)
            #expect(!again.isOn(.calendar) && again.isOn(.music))
        }
    }

    @Test("forget passes the source's fact prefix; added sources are kept, switched and removed")
    func forgetAndCustom() async throws {
        try await Self.withDefaults { d in
            let s = LearningSources(files: FileLearningConsent(defaults: d), media: MediaConsent(defaults: d),
                                    permissions: Permissions(allow: []), defaults: d)
            var asked: [(String, LearningSourceID?)] = []
            s.forgetter = { prefix, id in asked.append((prefix, id)); return 3 }
            #expect(s.forget(.files) == 3)
            #expect(asked.first?.0 == "file:" && asked.first?.1 == .files)
            #expect(s.status == "Forgot 3 facts from Files.")
            let app = CustomLearningSource(kind: .appUsage, name: "Invented Notes", value: "/Applications/Invented Notes.app")
            s.add(app)
            s.add(app)
            #expect(s.custom.count == 1 && s.status.contains("already listed"))
            #expect(s.trackedApps.map(\.name) == ["Invented Notes"])
            s.setCustom(app.id, on: false)
            #expect(s.trackedApps.isEmpty)
            #expect(s.remove(app.id) == 3)
            #expect(asked.last?.0 == "appUsage:/Applications/Invented Notes.app" && asked.last?.1 == nil)
            #expect(s.custom.isEmpty)
            #expect(CustomLearningSource(kind: .website, name: "x", value: "https://example.org").learnerBuilt == false)
        }
    }

    @Test("a Safari web app's start URL")
    func webApp() {
        #expect(LearningSources.webAppStartURL(infoPlist: ["Manifest Start URL": "https://example.org/app"], manifest: nil) == "https://example.org/app")
        #expect(LearningSources.webAppStartURL(infoPlist: [:], manifest: ["start_url": "https://example.org/"]) == "https://example.org/")
        #expect(LearningSources.webAppStartURL(infoPlist: ["CFBundleName": "X"], manifest: nil) == nil)
    }

    @Test("forgetting by source moves exactly that source's facts to the bin")
    func sourceForgetting() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = MemoryStore(store: try StateStore(root: root.path(percentEncoded: false), lease: nil))
        let facts = (0..<12).map { MemoryFact(id: "m\($0)", text: "Invented music fact \($0)", source: "music", created: 1, updated: 1, by: .local) }
            + [MemoryFact(id: "f1", text: "From a file", source: "file:abc", created: 1, updated: 1, by: .local),
               MemoryFact(id: "c1", text: "From a chat", source: "conversation", created: 1, updated: 1, by: .local),
               MemoryFact(id: "x1", text: "Musical, not music", source: "musicals", created: 1, updated: 1, by: .local)]
        #expect(memory.updateFacts { $0.facts = facts; return true })
        #expect(SourceForgetting.forget(prefix: "music", in: memory) == 12)   // more than dropLimit: the user's pick
        #expect(memory.loadFacts()?.facts.map(\.id) == ["f1", "c1", "x1"])
        #expect(SourceForgetting.forget(prefix: "file:", in: memory) == 1)
        #expect(SourceForgetting.matches("music:weekly", prefix: "music"))
        #expect(!SourceForgetting.matches("musicals", prefix: "music"))
    }

    @Test("app usage: minutes per day and part of day, one fact, old days pruned")
    func appUsage() {
        var log = AppUsageLog()
        log.add(app: "/A.app", day: "2026-10-01", hour: 20, seconds: 1800)
        log.add(app: "/A.app", day: "2026-10-02", hour: 21, seconds: 1200)
        log.add(app: "/A.app", day: "2026-10-02", hour: 9, seconds: 600)
        #expect(log.fact(app: "/A.app", name: "Invented Notes", from: "2026-09-26")
                == "The user uses Invented Notes for about 30 minutes a day, mostly in the evening.")
        #expect(log.fact(app: "/B.app", name: "B", from: "2026-09-26") == nil)
        log.prune(before: "2026-10-02")
        #expect(log.seconds["/A.app"]?.keys.sorted() == ["2026-10-02"])
        #expect(AppUsageLog(data: log.data) == log)
        #expect(AppUsageLog.part(hour: 3) == "night")
    }
}
