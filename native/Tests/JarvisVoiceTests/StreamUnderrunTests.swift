import AVFAudio
import Foundation
import Testing
@testable import JarvisVoice

/// V7: a streamed reply whose voice falls behind (a hot, loaded Mac) pauses and carries on at the
/// same speed. The player puts silence in and never drops, repeats or squeezes a sample; the next
/// reply's pre-roll grows to cover the measured shortfall; the queue logs how often it ran dry.
@Suite("V7 stream underrun")
struct StreamUnderrunTests {
    static let rate = EnginePlayer.sampleRate

    /// A piece of a signal with no exact zeros, so inserted silence cannot pass for it.
    static func piece(_ index: Int, count: Int = 5_120) -> [Float] {
        (0..<count).map { n in
            let t = Double(index * count + n) / rate
            return Float(0.3 * sin(2 * .pi * 220 * t) + 0.05 * sin(2 * .pi * 1_330 * t)) + 0.01
        }
    }

    /// What `EnginePlayer.playStream` queues for `pieces`, in order: the same LoudnessStream and
    /// PreRoll, worked out without a player.
    static func queued(_ pieces: [[Float]], hold: Double = PreRoll.seconds) -> [Float] {
        let level = LoudnessStream(sampleRate: rate, lift: EnginePlayer.outputLiftDB, prior: nil)
        var preroll = PreRoll(sampleRate: rate, seconds: hold)
        var out: [Float] = []
        for piece in pieces { out += preroll.take(level.push(piece)) }
        let rest = level.finish()
        return out + preroll.flush() + rest
    }

    @Test func anUnderrunPutsInSilenceAndPlaysEverySampleOnceAtTheSameSpeed() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let pieces = (0..<8).map { Self.piece($0) }
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 1.7) }
        var played: [Float] = []
        func render(_ frames: Int) async throws {
            var left = frames
            while left > 0 {
                let next = try await player.renderOffline(frames: AVAudioFrameCount(min(left, Int(EnginePlayer.offlineFrames))))
                if next.isEmpty {
                    try await Task.sleep(for: .milliseconds(1))
                    continue
                }
                played += next[0]
                left -= next[0].count
            }
        }
        // Three pieces, then the voice stalls: everything queued plays, then a second of silence.
        for piece in pieces[0..<3] { feed.yield(PCMChunk(samples: piece, sampleRate: Self.rate)) }
        try await render(Int(Self.rate))
        // Then the rest, one stall of half a second between each pair.
        for (k, piece) in pieces[3...].enumerated() {
            feed.yield(PCMChunk(samples: piece, sampleRate: Self.rate))
            try await Task.sleep(for: .milliseconds(20))   // queued before the play head gets there
            if k % 2 == 1 { try await render(Int(Self.rate / 2)) }
        }
        feed.finish()
        try await Task.sleep(for: .milliseconds(20))
        try await render(Int(Self.rate))
        await player.stop()
        try await playing.value

        let expected = Self.queued(pieces)
        let check = SilenceOnlyMatch.compare(played: played, expected: expected)
        #expect(check.mismatchAt == nil, "\(check.summary)")
        #expect(check.matched == expected.count, "every sample played once, in order: \(check.summary)")
        #expect(check.gaps.count >= 2, "the stalls left pauses: \(check.summary)")
        // Played at 24 kHz into a 24 kHz output, the speech itself lasts exactly as long as it was
        // given: what is not inserted silence is the input, sample for sample.
        let nonSilent = played.count - played.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
        #expect(nonSilent == expected.count)
    }

    @Test(arguments: [
        // (expected s, delivery rate, hold s)
        (10.0, nil as Double?, 0.2),
        (10.0, 1.0, 0.2),
        (10.0, 1.4, 0.2),
        (10.0, 0.75, 2.7),
        (6.0, 0.5, 3.2),
        (0.0, 0.5, 0.2),
    ])
    func thePreRollCoversTheShortfall(_ expected: Double, _ rate: Double?, _ hold: Double) {
        #expect(abs(PreRoll.hold(expected: expected, deliveryRate: rate) - hold) < 1e-9)
    }

    /// The rate, from arrival times given outright (no clock, so no load can move it).
    @Test func theMeterMeasuresFromTheSecondPieceToTheLast() {
        let t0 = ContinuousClock.now
        func meter(_ arrivals: [(ms: Int, samples: Int)]) -> Double? {
            var m = DeliveryMeter(sampleRate: Self.rate)
            for a in arrivals { m.arrived(samples: a.samples, at: t0 + .milliseconds(a.ms)) }
            return m.rate
        }
        // 0.12 s of audio every 0.2 s for 1.4 s: 0.6x.
        let slow = meter((0..<8).map { ($0 * 200, 2_880) })
        #expect(slow.map { abs($0 - 0.6) < 1e-9 } == true)
        // Short and faster than real time (0.12 s every 0.05 s): measured, 2.4x.
        let fast = meter((0..<4).map { ($0 * 50, 2_880) })
        #expect(fast.map { abs($0 - 2.4) < 1e-9 } == true)
        // Short and slow: too little to go on.
        #expect(meter((0..<3).map { ($0 * 250, 2_880) }) == nil)
        #expect(meter([(0, 2_880), (200, 2_880)]) == nil)
    }

    /// Plays a stream of eight 0.12 s pieces at least 0.2 s apart (about 0.6x real time).
    static func playSlowStream(on player: EnginePlayer) async throws {
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 2) }
        for k in 0..<8 {
            feed.yield(PCMChunk(samples: Self.piece(k, count: 2_880), sampleRate: Self.rate))
            try await Task.sleep(for: .milliseconds(200))
        }
        feed.finish()
        try await Task.sleep(for: .milliseconds(20))
        await player.stop()
        try await playing.value
    }

    /// Delivered slower than real time, the stream holds the next reply back for its shortfall.
    /// The exact rate is the meter's test; under load the sleeps only stretch, so here it is below 1.
    @Test func aSlowDeliveryRaisesTheNextPreRoll() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        try await Self.playSlowStream(on: player)
        let first = try #require(await player.lastStream())
        let measured = try #require(first.deliveryRate)
        #expect(first.preroll == PreRoll.seconds, "nothing measured before the first reply")
        #expect(first.holdRate == nil)
        #expect(measured < 0.8, "measured \(measured)")
        // Played from when each piece was queued: 0.12 s of audio every 0.2 s or more runs dry
        // each time after the pre-roll.
        #expect(first.dry >= 4, "ran dry \(first.dry) times")

        let (next, nextFeed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let again = Task { try await player.playStream(next, expectedSeconds: 10) }
        nextFeed.finish()
        try await again.value
        let second = try #require(await player.lastStream())
        #expect(abs(second.preroll - PreRoll.hold(expected: 10, deliveryRate: measured)) < 1e-9)
        #expect(second.preroll > PreRoll.seconds + 2)
        #expect(second.holdRate == measured)
    }

    /// A stream that keeps up keeps the 0.2 s pre-roll, and its first audio plays as soon as 0.2 s
    /// is in hand, as before V7; a short fast reply after a slow one clears the slow rate.
    @Test func aFastStreamKeepsTheUsualPreRollAndFirstAudio() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        func fastStream(pieces: Int) async throws -> StreamReport {
            let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
            let playing = Task { try await player.playStream(stream, expectedSeconds: 4) }
            for k in 0..<pieces {
                feed.yield(PCMChunk(samples: Self.piece(k, count: 2_880), sampleRate: Self.rate))
                try await Task.sleep(for: .milliseconds(20))
            }
            feed.finish()
            try await Task.sleep(for: .milliseconds(20))
            await player.stop()
            try await playing.value
            return try #require(await player.lastStream())
        }
        let fresh = try await fastStream(pieces: 6)
        #expect(fresh.preroll == PreRoll.seconds)
        #expect(fresh.holdRate == nil)

        try await Self.playSlowStream(on: player)
        let fast = try await fastStream(pieces: 6)
        #expect(fast.preroll > PreRoll.seconds, "held for the slow reply before it")
        #expect((fast.deliveryRate ?? 0) >= 1, "measured \(String(describing: fast.deliveryRate))")

        // The next reply: 0.2 s again, and audio is queued once three pieces (0.36 s) are in.
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 4) }
        for k in 0..<3 { feed.yield(PCMChunk(samples: Self.piece(k, count: 2_880), sampleRate: Self.rate)) }
        var heard = false
        let began = ContinuousClock.now
        while !heard, ContinuousClock.now - began < .seconds(2) {
            let next = try await player.renderOffline(frames: EnginePlayer.offlineFrames)
            heard = next.first?.contains { $0 != 0 } ?? false
            if !heard { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(heard, "the first audio played with only three pieces in hand")
        feed.finish()
        await player.stop()
        try await playing.value
        let report = try #require(await player.lastStream())
        #expect(report.preroll == PreRoll.seconds)
        #expect(report.holdRate == nil)
    }

    /// Stop, barge-in and a message sent while he speaks all reach the queue's `cancelAll`. During
    /// a long pre-roll it returns at once, ends the voice's stream, and nothing held ever plays.
    @Test func stoppingDuringThePreRollPlaysNothing() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        try await Self.playSlowStream(on: player)
        let engine = FakeStreamEngine(pieces: (0..<20).map { Self.piece($0, count: 2_880) })
        let log = LogLines()
        let queue = SpeechQueue(engine: engine, fallback: SayEngine(), player: player,
                                helperFootprintMB: { nil }, log: { log.append($0) })
        let speaking = Task { await queue.say("A reply that will be stopped.", turn: UUID()) }
        for _ in 0..<3 { await engine.next() }   // four pieces, 0.48 s: under the hold
        try await Task.sleep(for: .milliseconds(150))
        let stopping = ContinuousClock.now
        await queue.cancelAll()
        let took = ContinuousClock.now - stopping
        await speaking.value
        #expect(took < .milliseconds(500), "cancelAll took \(took)")
        var played: [Float] = []
        for _ in 0..<50 {
            played += (try await player.renderOffline(frames: EnginePlayer.offlineFrames)).first ?? []
        }
        #expect(!played.contains { $0 != 0 }, "nothing held played after the stop")
        #expect(await engine.terminated >= 1, "the voice's stream was ended")
        #expect(log.all.contains { $0.contains("stopped") })
    }

    @Test func theQueueLogsHowOftenTheStreamRanDry() {
        #expect(SpeechQueue.dryLine(StreamReport(dry: 3, dryMilliseconds: 412, preroll: 0.2, deliveryRate: nil))
                == "voice: stream ran dry 3 times, 412 ms")
        #expect(SpeechQueue.dryLine(StreamReport(dry: 2, dryMilliseconds: 90, preroll: 2.7, deliveryRate: 0.8))
                == "voice: stream ran dry 2 times, 90 ms; delivered at 0.80x real time")
        #expect(SpeechQueue.prerollLine(StreamReport(dry: 0, dryMilliseconds: 0, preroll: 0.2, deliveryRate: 1.3))
                == "voice: pre-roll 0.2 s (stream keeping up)")
        #expect(SpeechQueue.prerollLine(StreamReport(dry: 0, dryMilliseconds: 0, preroll: 1.4, holdRate: 0.8, deliveryRate: nil))
                == "voice: pre-roll 1.4 s (stream slow: x0.80)")
    }
}

/// Whether `played` is `expected` with only silence put in: every expected sample once, in order.
enum SilenceOnlyMatch {
    struct Result {
        var matched = 0
        var gaps: [Int] = []
        var mismatchAt: Int?
        var summary: String {
            let ms = gaps.map { Double($0) / EnginePlayer.sampleRate * 1000 }
            return String(format: "matched %d; silence put in %d time(s), %.0f ms in all (longest %.0f ms)",
                          matched, gaps.count, ms.reduce(0, +), ms.max() ?? 0)
                + (mismatchAt.map { "; MISMATCH at expected sample \($0)" } ?? "")
        }
    }

    /// Exact zeros in `played` that do not match `expected` are inserted silence; anything else
    /// that does not match is a sample dropped, repeated or changed.
    static func compare(played: [Float], expected: [Float], tolerance: Float = 1e-6) -> Result {
        var r = Result()
        var i = 0, j = 0, run = 0
        while i < played.count, j < expected.count {
            if abs(played[i] - expected[j]) <= tolerance {
                if run > 0 { r.gaps.append(run); run = 0 }
                i += 1; j += 1
            } else if played[i] == 0 {
                run += 1; i += 1
            } else {
                r.mismatchAt = j
                break
            }
        }
        r.matched = j
        return r
    }
}
