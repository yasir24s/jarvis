import AVFAudio
import Foundation
import Testing
@testable import JarvisVoice

/// BS.1770 measurement, and every part played at -14 LUFS with its peak at or below -1 dBFS.
/// The played tests run the real EnginePlayer with its engine in offline manual rendering mode
/// and measure what comes out of the main mixer.
@Suite("P5 voice loudness")
struct LoudnessTests {
    static let rate = EnginePlayer.sampleRate

    /// Two phrases of a 110 Hz voice with 30 harmonics under a 4 Hz syllable envelope, with
    /// silence around and between them: 3 s at 24 kHz, scaled to `lufs`. Its peak is 13.05 dB
    /// above its loudness.
    static func speechLike(lufs: Double) throws -> [Float] {
        var x = [Float](repeating: 0, count: Int(3 * rate))
        for (start, length) in [(0.3, 1.0), (1.6, 1.1)] {
            for n in Int(start * rate)..<Int((start + length) * rate) {
                let t = Double(n) / rate - start
                var v = 0.0
                for k in 1...30 { v += sin(2 * Double.pi * 110 * Double(k) * t + Double(k * k) * 0.7) / Double(k) }
                x[n] = Float((0.5 - 0.5 * cos(2 * Double.pi * 4 * t)) * v)
            }
        }
        let measured = try #require(Loudness.integrated([x], sampleRate: rate))
        let scale = Float(pow(10, (lufs - measured) / 20))
        return x.map { $0 * scale }
    }

    static func sine(_ frequency: Double, amplitude: Double, seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    static func dB(_ x: Float) -> Double { 20 * log10(Double(x)) }

    /// `part` played by a real EnginePlayer rendering offline to `outputRate` Hz stereo: one array
    /// per channel, the part's length and half a second more.
    static func played(_ part: [Float], outputRate: Double) async throws -> [[Float]] {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2))
        let player = try EnginePlayer(offline: output)
        let playing = Task { try await player.play(PCMChunk(samples: part, sampleRate: rate)) }
        let needed = Int(Double(part.count) * outputRate / rate + 0.5 * outputRate)
        var out: [[Float]] = [[], []]
        var waits = 0
        while out[0].count < needed {
            let next = try await player.renderOffline(frames: EnginePlayer.offlineFrames)
            guard !next.isEmpty else {
                // play has not started the engine yet.
                waits += 1
                try #require(waits < 2000, "the player never started its engine")
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            for c in out.indices { out[c] += next[c] }
        }
        await player.stop()
        try await playing.value
        return out
    }

    // MARK: measurement

    @Test func kWeightingAt48kHzIsTheStandardsTable() {
        // ITU-R BS.1770-4, tables 1 and 2.
        let (shelf, highPass) = Loudness.kWeighting(sampleRate: 48_000)
        let expected: [(Double, Double)] = [
            (shelf.b0, 1.53512485958697), (shelf.b1, -2.69169618940638), (shelf.b2, 1.19839281085285),
            (shelf.a1, -1.69065929318241), (shelf.a2, 0.73248077421585),
            (highPass.b0, 1.0), (highPass.b1, -2.0), (highPass.b2, 1.0),
            (highPass.a1, -1.99004745483398), (highPass.a2, 0.99007225036621),
        ]
        for (got, want) in expected { #expect(abs(got - want) < 1e-12, "\(got) against \(want)") }
    }

    /// The standard's calibration: a full-scale 997 Hz sine reads -3.01 LUFS at 48 kHz. The same
    /// filters designed for 24 kHz pass 997 Hz 0.026 dB higher (0.717 dB against 0.691), so -2.98.
    @Test(arguments: [(48_000.0, -3.01), (24_000.0, -2.98)])
    func aFullScale997HzSineReadsMinus3LUFS(rate: Double, expected: Double) throws {
        let lufs = try #require(Loudness.integrated([Self.sine(997, amplitude: 1, seconds: 3, rate: rate)], sampleRate: rate))
        #expect(abs(lufs - expected) < 0.01, "\(lufs)")
    }

    @Test func theGatesDropSilenceAndQuietBlocks() throws {
        // Two seconds of tone are 17 whole blocks. Two seconds after it add three blocks that hold
        // 3/4, 1/2 and 1/4 of tone, which count, and 17 that hold none, which must not: the mean
        // power is 18.5/20 of the tone's, where all 37 would make it 18.5/37 (-3 dB).
        let tone = Self.sine(997, amplitude: 0.5, seconds: 2, rate: Self.rate)
        let alone = try #require(Loudness.integrated([tone], sampleRate: Self.rate))
        let straddling = 10 * log10(18.5 / 20)
        // Silence is under the absolute gate.
        let withSilence = try #require(Loudness.integrated([tone + [Float](repeating: 0, count: 48_000)], sampleRate: Self.rate))
        #expect(abs(withSilence - (alone + straddling)) < 0.01, "\(withSilence - alone)")
        // The tone 40 dB down is under the relative gate.
        let quiet = Self.sine(997, amplitude: 0.005, seconds: 2, rate: Self.rate)
        let withQuiet = try #require(Loudness.integrated([tone + quiet], sampleRate: Self.rate))
        #expect(abs(withQuiet - (alone + straddling)) < 0.01, "\(withQuiet - alone)")
        // Silence has no loudness.
        #expect(Loudness.integrated([[Float](repeating: 0, count: 48_000)], sampleRate: Self.rate) == nil)
        #expect(Loudness.integrated([[]], sampleRate: Self.rate) == nil)
    }

    // MARK: the gain

    /// The speech-like part at `lufs` with a 2 ms burst at `peak` dBFS every 0.6 s, as F5 at 4
    /// steps makes them (the live parts measured -11 to -13 LUFS with peaks up to +5.5 dBFS).
    static func spiky(lufs: Double, peak: Double) throws -> [Float] {
        var x = try speechLike(lufs: lufs)
        let amplitude = pow(10, peak / 20)
        for start in stride(from: Int(0.5 * rate), to: Int(2.6 * rate), by: Int(0.6 * rate)) {
            for k in 0..<48 { x[start + k] = Float(amplitude * cos(2 * Double.pi * 3_000 * Double(k) / rate + 0.3)) }
        }
        return x
    }

    @Test func aPeakDoesNotLowerTheGain() throws {
        // A quiet tone with one loud click: the gain is the loudness's, and the click is left to
        // the limiter.
        var part = Self.sine(220, amplitude: 0.05, seconds: 2, rate: Self.rate)
        part[24_000] = 0.9
        let lufs = try #require(Loudness.integrated([part], sampleRate: Self.rate))
        #expect(abs(Self.dB(Loudness.gain(for: part, sampleRate: Self.rate)) - (Loudness.targetLUFS - lufs)) < 0.001)
    }

    @Test func theLimiterKeepsEverySampleAtOrUnderMinus1dBFS() throws {
        let part = try Self.spiky(lufs: -11, peak: 5.5)
        // The bursts' crests fall between samples: +5.5 dBFS read between them, +5.1 on them.
        #expect(20 * log10(Loudness.between(part).max() ?? 0) > 5.4)
        let out = Loudness.normalized(part, sampleRate: Self.rate, lift: EnginePlayer.outputLiftDB)
        #expect(Self.dB(Loudness.samplePeak(out)) <= Loudness.peakCeilingDBFS)
        #expect(!out.contains { abs($0) > 1 })
        // The bursts are limited, not the part: it still reads the target, less the lift.
        let lufs = try #require(Loudness.integrated([out], sampleRate: Self.rate))
        #expect(abs(lufs - (Loudness.targetLUFS - EnginePlayer.outputLiftDB)) < 0.5, "\(lufs)")
    }

    @Test func theLimiterOnlyTouchesTheSamplesAroundAPeak() {
        // A sine at 0.3 with one sample at 2.0: the gain falls over 5 ms (120 samples) to meet it,
        // then recovers with a 50 ms time constant.
        var part = Self.sine(220, amplitude: 0.3, seconds: 1, rate: Self.rate)
        let p = 6_000
        part[p] = 2
        let out = Loudness.limited(part, sampleRate: Self.rate)
        func gain(_ i: Int) -> Double { Double(out[i]) / Double(part[i]) }
        let look = 120
        // The values read between samples reach a few samples either side of the spike.
        #expect(Array(out[..<(p - look - 6)]) == Array(part[..<(p - look - 6)]), "untouched before the look-ahead")
        #expect(Double(abs(out[p])) <= pow(10, Loudness.peakCeilingDBFS / 20))
        let floor = gain(p)
        #expect(floor < 0.45)
        #expect(gain(p - look / 2) < 1 && gain(p - look / 2) > floor, "halfway down the attack")
        // 50 ms after: about 1 - (1 - floor) e^-1; 250 ms after: back within 1 %.
        let expected = 1 - (1 - floor) * exp(-1)
        #expect(abs(gain(p + 1_200) - expected) < 0.05, "\(gain(p + 1_200)) against \(expected)")
        #expect(gain(p + 6_000) > 0.99)
    }

    /// The in-between reader: a sine a quarter of the rate, sampled 45 degrees off its crests,
    /// has samples at 0.707 of its amplitude and crests between them.
    @Test func theValuesBetweenSamplesFindTheCrests() {
        let x = (0..<2_400).map { Float(0.5 * sin(Double.pi / 2 * Double($0) + Double.pi / 4)) }
        #expect(abs(Double(Loudness.samplePeak(x)) - 0.5 * sqrt(0.5)) < 1e-6)
        let peak = Loudness.between(x)[1_000...1_400].max() ?? 0
        #expect(abs(peak - 0.5) < 0.01, "\(peak)")
    }

    @Test func aPartUnderTheCeilingIsNotLimited() throws {
        let part = try Self.speechLike(lufs: -20)
        #expect(Loudness.limited(part, sampleRate: Self.rate) == part)
    }

    @Test func theGainStopsAt20dB() {
        // At -60 LUFS a part would need +46 dB; a 100 ms part, one short block, the same.
        for seconds in [2.0, 0.1] {
            let part = Self.sine(220, amplitude: 0.001, seconds: seconds, rate: Self.rate)
            #expect(abs(Self.dB(Loudness.gain(for: part, sampleRate: Self.rate)) - 20) < 0.001, "\(seconds) s")
        }
    }

    // MARK: played through the real player

    @Test(arguments: [44_100.0, 48_000.0])
    func aQuietPartPlaysAtMinus14LUFS(outputRate: Double) async throws {
        let part = try Self.speechLike(lufs: -30)
        let out = try await Self.played(part, outputRate: outputRate)
        let lufs = try #require(Loudness.integrated(out, sampleRate: outputRate))
        let peak = out.map { Self.dB(Loudness.samplePeak($0)) }
        print("P5 loudness: a -30 LUFS part plays at \(String(format: "%.2f", lufs)) LUFS at \(Int(outputRate)) Hz, "
              + "peaks \(peak.map { String(format: "%.2f", $0) }) dBFS")
        #expect(abs(lufs - Loudness.targetLUFS) <= 1)
        #expect(peak.allSatisfy { $0 <= Loudness.peakCeilingDBFS })
        // Both channels carry the same signal.
        #expect(out[0] == out[1])
    }

    @Test func aPartWithBurstsOverFullScalePlaysAtMinus14LUFS() async throws {
        let part = try Self.spiky(lufs: -11, peak: 5.5)
        let out = try await Self.played(part, outputRate: 48_000)
        let lufs = try #require(Loudness.integrated(out, sampleRate: 48_000))
        let peak = out.map { Self.dB(Loudness.samplePeak($0)) }
        print("P5 loudness: a -11 LUFS part with +5.5 dBFS bursts plays at \(String(format: "%.2f", lufs)) LUFS, "
              + "peaks \(peak.map { String(format: "%.2f", $0) }) dBFS")
        #expect(abs(lufs - Loudness.targetLUFS) <= 1)
        #expect(peak.allSatisfy { $0 <= Loudness.peakCeilingDBFS })
    }

    @Test func aLoudPartIsTurnedDown() async throws {
        // -6 LUFS: its peak is +7 dBFS.
        let part = try Self.speechLike(lufs: -6)
        #expect(Self.dB(Loudness.samplePeak(part)) > 6)
        let out = try await Self.played(part, outputRate: 48_000)
        let lufs = try #require(Loudness.integrated(out, sampleRate: 48_000))
        let peak = out.map { Self.dB(Loudness.samplePeak($0)) }
        print("P5 loudness: a -6 LUFS part plays at \(String(format: "%.2f", lufs)) LUFS, "
              + "peaks \(peak.map { String(format: "%.2f", $0) }) dBFS")
        #expect(abs(lufs - Loudness.targetLUFS) <= 1)
        #expect(peak.allSatisfy { $0 <= Loudness.peakCeilingDBFS })
    }

    @Test func silenceIsLeftAlone() async throws {
        let silence = [Float](repeating: 0, count: 24_000)
        #expect(Loudness.gain(for: silence, sampleRate: Self.rate) == 1)
        let out = try await Self.played(silence, outputRate: 48_000)
        #expect(out.allSatisfy { Loudness.samplePeak($0) == 0 })
        // A hum under the absolute gate (about -77 LUFS) keeps its level too.
        let hum = Self.sine(220, amplitude: 0.0002, seconds: 1, rate: Self.rate)
        #expect(Loudness.integrated([hum], sampleRate: Self.rate) == nil)
        #expect(Loudness.gain(for: hum, sampleRate: Self.rate) == 1)
        let humOut = try await Self.played(hum, outputRate: 48_000)
        for channel in humOut {
            #expect(abs(Self.dB(Loudness.samplePeak(channel)) - Self.dB(Loudness.samplePeak(hum))) < 0.1)
        }
    }
}
