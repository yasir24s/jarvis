import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// The app's research path (M4 C2 item 4; D-36, D-37): the lease the state store holds opens
/// research/ too, and the logger and the scheduler bump through the one UsageStore the rest of
/// the app is handed. Everything is written inside a temp folder; nothing is launched.
@Suite("M4 app research path (D-36)", .timeLimit(.minutes(1)))
@MainActor
struct AppResearchTests {
    /// A root StateStore treats as real state (it has jarvis.py, and its folder name is not a
    /// test sandbox's), inside the temp folder.
    struct RealLikeRoot {
        let paths: StatePaths

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appending(path: "m4c2-real-like-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "research", directoryHint: .isDirectory),
                                                    withIntermediateDirectories: true)
            try Data().write(to: root.appending(path: "jarvis.py", directoryHint: .notDirectory))
            paths = StatePaths(root: root)
        }

        func remove() {
            try? FileManager.default.removeItem(at: paths.root)
        }
    }

    /// usage.json's counters for `day`, or nil when the file does not exist.
    static func counters(_ paths: StatePaths, day: String) throws -> [String: Int]? {
        guard let data = FileManager.default.contents(atPath: paths.researchUsage.path(percentEncoded: false)) else {
            return nil
        }
        let usage = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: Int]])
        return usage[day] ?? [:]
    }

    static func acquire(_ paths: StatePaths) throws -> InstanceLock {
        guard case .acquired(let held) = InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) else {
            throw CocoaError(.fileLocking)
        }
        return held
    }

    @Test("on a real-like root the state store's lease opens usage.json; a store without it is refused")
    func sharedLeaseOpensResearch() throws {
        let box = try RealLikeRoot()
        defer { box.remove() }
        let held = try Self.acquire(box.paths)
        let lease = InstanceLockLease(held)
        let logs = LogRecorder()
        let today = ResearchClock().today()

        let leaseless = UsageStore(paths: ResearchPaths(box.paths), log: logs.function)
        leaseless.bump("interactions_text", by: 1)
        #expect(try Self.counters(box.paths, day: today) == nil)
        #expect(logs.lines.count == 1)

        // The app's wiring: one lease, given to the state store and to the one UsageStore.
        _ = try StateStore(root: box.paths.root.path(percentEncoded: false), lease: lease)
        let store = UsageStore(paths: ResearchPaths(box.paths), lease: lease, log: logs.function)
        store.bump("interactions_text", by: 1)
        #expect(try Self.counters(box.paths, day: today) == ["interactions_text": 1])
        #expect(logs.lines.count == 1)
        withExtendedLifetime(held) {}
    }

    @Test("the logger and the scheduler bump through the one store the core and the brain are handed")
    func oneSharedStore() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let held = try Self.acquire(sandbox.paths)
        let lease = InstanceLockLease(held)
        let logs = LogRecorder()
        let paths = ResearchPaths(sandbox.paths)
        let store = UsageStore(paths: paths, lease: lease, log: logs.function)
        let state = try StateStore(root: sandbox.root.path(percentEncoded: false), lease: lease)
        let core = CoreState(store: state, clock: SystemClock(), research: store, frontApp: FixedFrontApp())
        let scheduler = AppResearch.scheduler(
            store: store, paths: paths, here: sandbox.root, core: core,
            runtime: AppResearch.runtime(processStarted: 1_790_582_400, claudeEnabled: true),
            git: { _, _ in nil }, host: { HostSample.current() }, log: logs.function)
        #expect(scheduler.store === store)
        #expect(scheduler.logger.store === store)
        #expect(scheduler.build == .dev)

        scheduler.start()                         // the launch bump, through the logger
        store.bump("text_confirm_approved", by: 1) // a bump the chat's authenticator makes
        scheduler.logger.bump("alive_hours", by: 1)
        scheduler.stop()                          // flushes the logger's queue

        let today = store.clock.today()
        #expect(try Self.counters(sandbox.paths, day: today)
                == [ResearchKey.starts(build: .dev): 1, "text_confirm_approved": 1, "alive_hours": 1])
        #expect(logs.lines.allSatisfy { !$0.contains("lease") })
        withExtendedLifetime(held) {}
    }

    @Test("the snapshot's runtime block: Claude's setting and the local backend's id")
    func runtimeFacts() {
        let runtime = AppResearch.runtime(processStarted: 1_790_582_400, claudeEnabled: true)()
        #expect(runtime.processStarted == 1_790_582_400)
        #expect(runtime.claudeEnabled)
        #expect(runtime.localModel == "apple-foundation-model")
        #expect(LocalBrain.backendName == "local (apple-foundation-model)")
        #expect(!runtime.voice)
    }
}
