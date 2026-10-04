import AVFAudio
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

/// V9 part 2: a reply measures its own first pieces before it plays. Offline renders; nothing plays.
@Suite("V9 first reply warm: the in-reply pre-roll")
struct InReplyPreRollTests {
    static let rate = EnginePlayer.sampleRate
    static func piece(_ k: Int) -> PCMChunk {
        PCMChunk(samples: StreamUnderrunTests.piece(k, count: 2_880), sampleRate: rate)   // 0.12 s
    }

    @Test(arguments: [
        (4.0, 0.2, nil, 0.2),          // nothing measured yet
        (4.0, 0.2, 1.2, 0.2),          // keeping up: as before
        (4.0, 0.2, 0.6, 1.8),          // 0.2 + 4 x 0.4
        (20.0, 0.2, 0.5, 4.0),         // capped
        (4.0, 2.6, 0.8, 2.6),          // never below the last reply's hold
    ] as [(Double, Double, Double?, Double)])
    func theHoldFollowsTheReplysOwnRate(_ expected: Double, _ prior: Double, _ rate: Double?, _ hold: Double) {
        #expect(abs(PreRoll.hold(expected: expected, prior: prior, inReplyRate: rate) - hold) < 1e-9)
    }

    @Test func theLogNamesTheInReplyRate() {
        #expect(SpeechQueue.prerollLine(StreamReport(dry: 0, dryMilliseconds: 0, preroll: 0.92, deliveryRate: nil,
                                                     inReplyRate: 0.85))
            == "voice: pre-roll 0.9 s (in-reply rate x0.85)")
    }

    /// A cold start: the first five pieces come about 0.6x real time, then the voice catches up.
    /// The reply waits for its own shortfall and never runs dry.
    @Test func aColdStartGetsALongerPreRollAndNoUnderruns() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 1.44) }
        var played: [Float] = []
        let render = Task {
            var out: [Float] = []
            while !Task.isCancelled {
                out += (try await player.renderOffline(frames: EnginePlayer.offlineFrames)).first ?? []
                try? await Task.sleep(for: .milliseconds(2))
            }
            return out
        }
        for k in 0..<5 {
            feed.yield(Self.piece(k))
            try await Task.sleep(for: .milliseconds(200))
        }
        for k in 5..<12 { feed.yield(Self.piece(k)) }
        feed.finish()
        try await Task.sleep(for: .milliseconds(50))
        await player.stop()
        try await playing.value
        render.cancel()
        played = try await render.value
        let report = try #require(await player.lastStream())
        #expect(report.preroll > PreRoll.seconds, "held \(report.preroll) s")
        #expect((report.inReplyRate ?? 1) < 1)
        #expect(report.dry == 0, "ran dry \(report.dry) times, \(report.dryMilliseconds) ms")
        #expect(played.contains { $0 != 0 }, "the offline render pulled the reply")
    }

    /// A fresh player and a stream that keeps up: 0.2 s, and audio with three pieces in hand.
    @Test func aFastReplyKeepsTheUsualPreRollAndFirstAudio() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 4) }
        for k in 0..<3 { feed.yield(Self.piece(k)) }
        let heard = await QwenWarmUpTests.eventually {
            let next = try? await player.renderOffline(frames: EnginePlayer.offlineFrames)
            return next?.first?.contains { $0 != 0 } ?? false
        }
        #expect(heard, "the first audio played with only three pieces in hand")
        feed.finish()
        await player.stop()
        try await playing.value
        let report = try #require(await player.lastStream())
        #expect(report.preroll == PreRoll.seconds)
        #expect(report.inReplyRate == nil)
    }

    /// Stop during a hold the reply's own pace raised: nothing held plays.
    @Test func stoppingDuringTheRaisedHoldPlaysNothing() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 10) }
        for k in 0..<3 {
            feed.yield(Self.piece(k))
            try await Task.sleep(for: .milliseconds(200))
        }
        playing.cancel()
        await player.stop()
        try? await playing.value
        feed.finish()
        var played: [Float] = []
        for _ in 0..<50 { played += (try await player.renderOffline(frames: EnginePlayer.offlineFrames)).first ?? [] }
        #expect(!played.contains { $0 != 0 }, "nothing held played after the stop")
    }
}

/// V9 part 3: a cold voice with no warm-up starts its reply's estimate at x0.85.
@Suite("V9 first reply warm: a cold start without the warm-up")
struct ColdVoiceTests {
    static func emptyStream(_ player: EnginePlayer, expected: Double) async throws -> StreamReport {
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        feed.finish()
        try await player.playStream(stream, expectedSeconds: expected)
        return try #require(await player.lastStream())
    }

    @Test func theNextReplyIsHeldForAColdVoiceOnce() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: EnginePlayer.sampleRate, channels: 2))
        let player = try EnginePlayer(offline: output)
        await player.expectColdVoice(true)
        let cold = try await Self.emptyStream(player, expected: 10)
        #expect(abs(cold.preroll - PreRoll.hold(expected: 10, deliveryRate: EnginePlayer.coldStartRate)) < 1e-9)
        #expect(cold.holdRate == EnginePlayer.coldStartRate)
        let next = try await Self.emptyStream(player, expected: 10)
        #expect(next.preroll == PreRoll.seconds, "used once")
        await player.expectColdVoice(true)
        await player.expectColdVoice(false)
        #expect(try await Self.emptyStream(player, expected: 10).preroll == PreRoll.seconds)
    }
}
