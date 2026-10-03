import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// The media catalogue refreshed in a loop: a burst of refresh calls at launch each read the whole
/// library and rewrote the music facts, because every call checked whether a refresh was due
/// before the first had finished. Fakes only: nothing reads the real Music or TV library.
@Suite("Media refresh: once per burst", .timeLimit(.minutes(1)))
struct MediaRefreshLoopTests {
    /// A TV library whose read waits until it is let go, so calls overlap as they did live.
    final class SlowTV: TVLibraryReading, Sendable {
        private let state = Mutex<(reads: Int, held: [CheckedContinuation<Void, Never>], open: Bool)>((0, [], false))
        var reads: Int { state.withLock { $0.reads } }
        var waiting: Int { state.withLock { $0.held.count } }
        func read() async -> [MediaItem]? {
            await withCheckedContinuation { c in
                let resumeNow = state.withLock { s -> Bool in
                    s.reads += 1
                    if s.open { return true }
                    s.held.append(c)
                    return false
                }
                if resumeNow { c.resume() }
            }
            return []
        }
        func open() {
            let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.open = true
                defer { s.held = [] }
                return s.held
            }
            held.forEach { $0.resume() }
        }
    }

    /// A sleep that returns only when the test lets it go, and records what it was asked.
    final class HeldSleep: Sendable {
        private let state = Mutex<(asked: [Duration], held: [CheckedContinuation<Void, Never>])>(([], []))
        var asked: [Duration] { state.withLock { $0.asked } }
        func sleep(_ d: Duration) async {
            await withCheckedContinuation { c in state.withLock { $0.asked.append(d); $0.held.append(c) } }
        }
        func release() {
            let held = state.withLock { s -> [CheckedContinuation<Void, Never>] in defer { s.held = [] }; return s.held }
            held.forEach { $0.resume() }
        }
    }

    final class LogBox: Sendable {
        private let v = Mutex<[String]>([])
        func append(_ line: String) { v.withLock { $0.append(line) } }
        var all: [String] { v.withLock { $0 } }
    }

    struct Rig {
        let root: URL
        let store: StateStore
        let memory: MemoryStore
        let fake = MediaLibraryTests.Fake()
        let tv = SlowTV()
        let held = HeldSleep()
        let clock = ManualClock(1_791_000_000)
        let logs = LogBox()
        let media: MediaLibrary

        init(library: Bool) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-media-loop-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try StateStore(root: root.path(percentEncoded: false), lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock)
            fake.state.withLock { $0.music = MediaLibraryTests.songs }
            let held = self.held, logs = self.logs
            media = MediaLibrary(store: store, memory: memory, music: fake, tv: tv, folders: fake, scripts: fake, opener: fake,
                                 clock: clock, timeZone: TimeZone(identifier: "Europe/London")!,
                                 switches: .init(music: { true }, library: { library }),
                                 sleep: { await held.sleep($0) },
                                 log: { line in logs.append(line) })
        }

        var musicReads: Int { fake.state.withLock { $0.reads } }
        var lines: [String] { logs.all }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = SuspendingClock.now + .seconds(30)
        while SuspendingClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("a burst of refresh calls while one runs reads the library once")
    func burstReadsOnce() async throws {
        let rig = try Rig(library: true)
        defer { rig.remove() }
        let media = rig.media
        let first = Task { await media.refresh() }
        #expect(await Self.eventually { rig.tv.waiting == 1 })
        let burst = (0..<20).map { _ in Task { await media.refresh() } }
        try? await Task.sleep(for: .milliseconds(50))   // let them all ask; none may start a read
        #expect(rig.tv.waiting == 1)
        rig.tv.open()
        let result = await first.value
        #expect(result != nil)
        for task in burst { #expect(await task.value == result) }
        #expect(rig.musicReads == 1)
        #expect(rig.tv.reads == 1)
        #expect(rig.lines.filter { $0.hasPrefix("media: catalogue refreshed") }.count == 1)
    }

    @Test("forced refreshes in a burst make one, and one asked for soon after the last waits out the debounce")
    func forcedBurstDebounced() async throws {
        let rig = try Rig(library: false)
        defer { rig.remove() }
        let media = rig.media
        #expect(await media.refresh(force: true) != nil)
        #expect(rig.musicReads == 1)
        rig.clock.advance(5)
        for _ in 0..<10 { #expect(await media.refresh(force: true) == nil) }
        #expect(rig.musicReads == 1, "held, not read")
        #expect(await Self.eventually { rig.held.asked.count == 1 }, "one held refresh for the whole burst")
        #expect(rig.held.asked == [.seconds(595)])
        let heldTask = try #require(media.heldRefresh)
        rig.clock.advance(595)
        rig.held.release()
        await heldTask.value
        #expect(rig.musicReads == 2)
    }

    @Test("JARVIS's own writes are not a change: after a refresh nothing is read again until a day has passed")
    func ownWritesDoNotRetrigger() async throws {
        let rig = try Rig(library: false)
        defer { rig.remove() }
        let media = rig.media
        #expect(await media.refresh() != nil)
        // The refresh wrote the catalogue and the music facts; asking again (as the six-hourly
        // check and the media tools do) reads nothing.
        rig.clock.advance(3600)
        for _ in 0..<5 { #expect(await media.refresh() == nil) }
        #expect(rig.musicReads == 1)
        rig.clock.advance(MediaLibrary.refreshEvery)
        #expect(await media.refresh() != nil)
        #expect(rig.musicReads == 2)
    }

    @Test("music facts the same as the saved ones are not rewritten")
    func unchangedFactsNotRewritten() async throws {
        let rig = try Rig(library: false)
        defer { rig.remove() }
        let media = rig.media
        #expect(await media.refresh() != nil)
        let first = (rig.memory.loadFacts()?.facts ?? []).filter { $0.source == "music" }
        #expect(!first.isEmpty)
        let path = rig.store.path(.facts)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        // The same day, nothing played: forced past the debounce, the facts come out the same.
        rig.clock.advance(MediaLibrary.changeDebounce)
        #expect(await media.refresh(force: true) != nil)
        #expect(rig.musicReads == 2)
        let again = (rig.memory.loadFacts()?.facts ?? []).filter { $0.source == "music" }
        #expect(again.map(\.id) == first.map(\.id))
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date == before)
        #expect(rig.lines.contains { $0.hasSuffix("music fact(s) unchanged") })
    }
}
