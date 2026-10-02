import Foundation
import Testing
@testable import JarvisVoice

/// V1 part 3: the downward expander before the gain and the limiter. The quiet tail after a word
/// drops by up to 12 dB; speech is never turned down.
@Suite("V1 expander")
struct ExpanderTests {
    static let rate = EnginePlayer.sampleRate

    /// A "word": `seconds` of a 150 Hz voice with harmonics at `amplitude`.
    static func word(seconds: Double, amplitude: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { n in
            let t = Double(n) / rate
            var v = 0.0
            for k in 1...8 { v += sin(2 * Double.pi * 150 * Double(k) * t) / Double(k) }
            return Float(amplitude * v / 2)
        }
    }

    /// Noise falling `dbPerSecond` from `startDB` (relative to full scale) for `seconds`: a room's
    /// tail after a word. Deterministic.
    static func tail(seconds: Double, startDB: Double, dbPerSecond: Double) -> [Float] {
        var state: UInt64 = 0x1234_5678
        return (0..<Int(seconds * rate)).map { n in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let noise = Double(Int64(bitPattern: state >> 11) % 2001 - 1000) / 1000
            let level = startDB - dbPerSecond * Double(n) / rate
            return Float(noise * pow(10, level / 20))
        }
    }

    static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        10 * log10(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    @Test func theSpeechLevelIsTheGatedMeanSquare() throws {
        let tone = Self.word(seconds: 2, amplitude: 0.5)
        let level = try #require(Loudness.speechLevel(tone, sampleRate: Self.rate))
        #expect(abs(level - Self.rmsDB(tone[...])) < 0.05)
        // Silence and a hum under the absolute gate have no speech level.
        #expect(Loudness.speechLevel([Float](repeating: 0, count: 24_000), sampleRate: Self.rate) == nil)
        #expect(Loudness.speechLevel(Self.word(seconds: 1, amplitude: 0.0001), sampleRate: Self.rate) == nil)
    }

    /// Two words, each followed by 400 ms of room tail starting 20 dB under the word and falling
    /// 60 dB a second. The words come out sample for sample; the tail's late part is cut by 6 to 12
    /// dB, never more.
    @Test func theTailDropsAndTheWordsDoNot() throws {
        let w = Self.word(seconds: 0.5, amplitude: 0.5)
        let wordDB = Self.rmsDB(w[...])
        let t = Self.tail(seconds: 0.4, startDB: wordDB - 20, dbPerSecond: 60)
        let part = w + t + w + t
        let out = Loudness.expanded(part, sampleRate: Self.rate)
        #expect(out.count == part.count)
        let wordRange = 0..<w.count
        let second = (w.count + t.count)..<(2 * w.count + t.count)
        for range in [wordRange, second] {
            let worst = range.map { i in part[i] == 0 ? 1.0 : Double(out[i] / part[i]) }.min() ?? 1
            #expect(worst > pow(10, -0.1 / 20), "a word lost \(20 * log10(worst)) dB")
        }
        // The last 200 ms of each tail.
        for start in [w.count + t.count / 2, 2 * w.count + t.count + t.count / 2] {
            let range = start..<(start + t.count / 2)
            let drop = Self.rmsDB(part[range]) - Self.rmsDB(out[range])
            #expect(drop >= 6 && drop <= Loudness.expanderRangeDB + 0.01, "the late tail dropped \(drop) dB")
        }
        // The first 20 ms of each tail, right after the word, is still mostly there (80 ms release).
        let early = w.count..<(w.count + Int(0.02 * Self.rate))
        #expect(Self.rmsDB(part[early]) - Self.rmsDB(out[early]) < 3)
    }

    @Test func aLongQuietStretchEndsTwelveDecibelsDown() {
        let w = Self.word(seconds: 1, amplitude: 0.5)
        let quiet = Self.word(seconds: 1, amplitude: 0.5 * pow(10, -50.0 / 20))
        let part = w + quiet
        let out = Loudness.expanded(part, sampleRate: Self.rate)
        let last = (part.count - 2_400)..<part.count
        let drop = Self.rmsDB(part[last]) - Self.rmsDB(out[last])
        #expect(abs(drop - Loudness.expanderRangeDB) < 0.1, "\(drop)")
    }

    @Test func steadySpeechAndSilencePassUnchanged() {
        let tone = Self.word(seconds: 1, amplitude: 0.3)
        #expect(Loudness.expanded(tone, sampleRate: Self.rate) == tone)
        let silence = [Float](repeating: 0, count: 12_000)
        #expect(Loudness.expanded(silence, sampleRate: Self.rate) == silence)
        let hum = Self.word(seconds: 1, amplitude: 0.0001)
        #expect(Loudness.expanded(hum, sampleRate: Self.rate) == hum)
    }

    /// The player's chain still brings a part with tails to the target.
    @Test func theChainStillReadsTheTarget() throws {
        let w = Self.word(seconds: 0.5, amplitude: 0.1)
        let t = Self.tail(seconds: 0.4, startDB: Self.rmsDB(w[...]) - 20, dbPerSecond: 60)
        let out = Loudness.normalized(w + t + w + t, sampleRate: Self.rate)
        let lufs = try #require(Loudness.integrated([out], sampleRate: Self.rate))
        #expect(abs(lufs - Loudness.targetLUFS) < 0.5, "\(lufs)")
    }
}
