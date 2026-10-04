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

    /// Delivered at about 0.6x real time, the stream holds the next reply back for its shortfall.
    @Test func aSlowDeliveryRaisesTheNextPreRoll() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let (stream, feed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let playing = Task { try await player.playStream(stream, expectedSeconds: 2) }
        // Eight pieces of 0.12 s, at least 0.2 s apart: 0.6 s of audio a second or less (a loaded
        // machine oversleeps). The rate the player should measure is taken from the yields as made.
        var yields: [ContinuousClock.Instant] = []
        for k in 0..<8 {
            yields.append(ContinuousClock.now)
            feed.yield(PCMChunk(samples: Self.piece(k, count: 2_880), sampleRate: Self.rate))
            try await Task.sleep(for: .milliseconds(200))
        }
        let fed = 7 * 2_880 / Self.rate / ((yields[7] - yields[0]) / .seconds(1))
        feed.finish()
        try await Task.sleep(for: .milliseconds(20))
        await player.stop()
        try await playing.value
        let first = try #require(await player.lastStream())
        let measured = try #require(first.deliveryRate)
        #expect(first.preroll == PreRoll.seconds, "nothing measured before the first reply")
        #expect(fed < 0.65)
        #expect(abs(measured / fed - 1) < 0.15, "measured \(measured), fed at \(fed)")
        // Played from when each piece was queued: 0.12 s of audio every 0.2 s runs dry each time
        // after the pre-roll.
        #expect(first.dry >= 4, "ran dry \(first.dry) times")
        #expect(first.dryMilliseconds >= 4 * 50)

        let (next, nextFeed) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let again = Task { try await player.playStream(next, expectedSeconds: 10) }
        nextFeed.finish()
        try await again.value
        let second = try #require(await player.lastStream())
        #expect(abs(second.preroll - PreRoll.hold(expected: 10, deliveryRate: measured)) < 1e-9)
        #expect(second.preroll > PreRoll.seconds + 2)
    }

    @Test func theQueueLogsHowOftenTheStreamRanDry() {
        #expect(SpeechQueue.dryLine(StreamReport(dry: 3, dryMilliseconds: 412, preroll: 0.2, deliveryRate: nil))
                == "voice: stream ran dry 3 times, 412 ms")
        #expect(SpeechQueue.dryLine(StreamReport(dry: 0, dryMilliseconds: 0, preroll: 2.7, deliveryRate: 0.8))
                == "voice: stream ran dry 0 times, 0 ms; pre-roll 2.7 s; delivered at 0.80x real time")
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
