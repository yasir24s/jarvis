import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

// V9: the first reply after an idle spell. Fakes only: no helper starts, nothing plays.
@Suite("V9 first reply warm: the engine's warm-up")
struct QwenWarmUpTests {
    /// A clock the test moves.
    final class Clock: Sendable {
        let start = ContinuousClock.now
        let offset = Mutex(Duration.zero)
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
        var now: @Sendable () -> ContinuousClock.Instant { { self.start + self.offset.withLock { $0 } } }
    }

    static func eventually(_ condition: () async -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test func warmUpGeneratesTheShortLineAndHandsNothingOn() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(QwenVoiceTests.pieces([100, 200])))
        let engine = QwenEngine(launcher: launcher)
        #expect(await engine.idleSeconds() == nil)
        #expect(await engine.warmUp())
        #expect(launcher.launched.first?.requests == [QwenEngine.warmUpLine])
        #expect(launcher.launched.first?.cancelled == [])
        #expect(folder.files.isEmpty)   // its audio was read and thrown away
    }

    @Test func idleSecondsCountFromTheLastGeneration() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let clock = Clock()
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(QwenVoiceTests.pieces([100])))
        let engine = QwenEngine(launcher: launcher, now: clock.now)
        for try await _ in await engine.synthesize("Good evening, sir.", context: SynthesisContext(turnID: UUID())) {}
        #expect(await engine.idleSeconds() == 0)
        clock.advance(.seconds(150))
        #expect(await engine.idleSeconds() == 150)
    }

    @Test func theRealRequestCutsTheWarmUpShortBeforeItIsSent() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(QwenVoiceTests.pieces([100, 200, 300])),
                                        gated: true)
        let engine = QwenEngine(launcher: launcher)
        let warming = Task { await engine.warmUp() }
        #expect(await Self.eventually { launcher.launched.first?.requests.count == 1 })
        let stream = await engine.synthesize("Good evening, sir.", context: SynthesisContext(turnID: UUID()))
        // The cancel went out in the same actor step, before the reply's request line.
        let connection = try #require(launcher.launched.first)
        #expect(connection.cancelled.count == 1)
        #expect(await warming.value == false)
        let consumer = Task {
            var sizes: [Int] = []
            for try await piece in stream { sizes.append(piece.samples.count) }
            return sizes
        }
        for _ in 0..<6 { connection.release() }
        #expect(try await consumer.value == [100, 200, 300])
        #expect(connection.requests == [QwenEngine.warmUpLine, "Good evening, sir."])
    }

    @Test func cancelWarmUpStopsItInTheHelper() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(QwenVoiceTests.pieces([100, 200])),
                                        gated: true)
        let engine = QwenEngine(launcher: launcher)
        let warming = Task { await engine.warmUp() }
        #expect(await Self.eventually { launcher.launched.first?.requests.count == 1 })
        await engine.cancelWarmUp()
        #expect(await warming.value == false)
        #expect(launcher.launched.first?.cancelled.count == 1)
        await engine.cancelWarmUp()   // nothing left to cancel
        #expect(launcher.launched.first?.cancelled.count == 1)
    }
}
