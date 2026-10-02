import Foundation
import JarvisCore

/// `analyze_tone` (J:1006-1048, plan M08-M13 §3.4): a rough prosody read of one utterance for
/// the prompt ("hurried and tense"), from its loudness, the spread of its pitch and its speaking
/// rate; "" when it is too short or too quiet to read. `CoreState.setTone` keeps it (set_tone).
///
/// Ported in float32 where numpy works in float32, with numpy 2's rules: a Python float meets a
/// float32 array as float32, and a float32 mean is numpy's pairwise sum. The autocorrelation is
/// summed in double; it decides only which lag is largest.
public enum ToneAnalyzer {
    /// What one read found, for tests.
    public struct Reading: Sendable, Equatable {
        public var loudDB: Double
        public var f0s: [Double]
        public var f0Std: Double
        public var rate: Double
        public var voicedFrames: Int
        public var descriptor: String
    }

    static let rate = 16_000
    static let frame = 320
    static let window = 640

    /// `analyze_tone(audio, text)`.
    public static func analyze(_ samples: [Int16], text: String?) -> String {
        reading(samples, text: text)?.descriptor ?? ""
    }

    public static func reading(_ samples: [Int16], text: String?) -> Reading? {
        let x = samples.map { Float($0) / 32768 }
        guard Double(x.count) >= Double(rate) * 0.4 else { return nil }
        let nf = x.count / frame
        var rms = [Float](repeating: 0, count: nf)
        for i in 0..<nf {
            let squares = x[(i * frame)..<((i + 1) * frame)].map { $0 * $0 }
            rms[i] = (pairwiseSum(squares[...]) / Float(frame)).squareRoot()
        }
        let top = Double(rms.max() ?? 0)
        let bar = Float(max(0.01, top * 0.2))
        let voiced = rms.map { $0 > bar }
        let voicedCount = voiced.filter { $0 }.count
        guard voicedCount >= 5 else { return nil }
        let loudness = pairwiseSum(rms.indices.filter { voiced[$0] }.map { rms[$0] }[...]) / Float(voicedCount)
        let loudDB = 20 * log10(Double(loudness) + 1e-9)
        var f0s: [Double] = []
        let (lo, hi) = (rate / 400, rate / 70)
        for i in largestTen(rms) {
            let start = i * frame
            guard start + window <= x.count else { continue }
            let s = Array(x[start..<(start + window)])
            let mean = pairwiseSum(s[...]) / Float(window)
            let centred = s.map { $0 - mean }
            var ac = [Double](repeating: 0, count: window)
            for lag in 0..<window {
                var sum = 0.0
                for n in 0..<(window - lag) { sum += Double(centred[n]) * Double(centred[n + lag]) }
                ac[lag] = sum
            }
            var lag = lo
            for k in lo..<hi where Float(ac[k]) > Float(ac[lag]) { lag = k }
            if Float(ac[lag]) > Float(0.3) * Float(ac[0]) { f0s.append(Double(rate) / Double(lag)) }
        }
        let f0Std = f0s.count >= 4 ? standardDeviation(f0s) : 0
        let words = Py.split(text ?? "").count
        let rate = Double(words) / max(0.3, Double(voicedCount) * Double(frame) / Double(Self.rate))
        let descriptor: String
        if rate >= 3.6 && loudDB > -26 {
            descriptor = "hurried and tense"
        } else if loudDB > -22 && f0Std < 12 && rate >= 2.0 {
            descriptor = "clipped, possibly irritated"
        } else if f0Std > 28 && rate >= 2.4 {
            descriptor = "animated and upbeat"
        } else if loudDB < -34 && rate < 2.2 {
            descriptor = "quiet and subdued"
        } else {
            descriptor = "calm and even"
        }
        return Reading(loudDB: loudDB, f0s: f0s, f0Std: f0Std, rate: rate, voicedFrames: voicedCount,
                       descriptor: descriptor)
    }

    /// `np.argsort(rms)[-10:]`: the indices of the ten largest, smallest of them first. Ties keep
    /// index order (numpy's sort is not stable, so a tie may order differently there; it changes
    /// only the order of the pitches, not their spread).
    static func largestTen(_ rms: [Float]) -> [Int] {
        let order = rms.indices.sorted { rms[$0] != rms[$1] ? rms[$0] < rms[$1] : $0 < $1 }
        return Array(order.suffix(10))
    }

    /// numpy's pairwise float32 sum (`pairwise_sum` in loops_utils.h): eight accumulators for up
    /// to 128 values, and halves (rounded down to a multiple of 8) above that.
    static func pairwiseSum(_ a: ArraySlice<Float>) -> Float {
        let n = a.count
        let base = a.startIndex
        if n < 8 {
            var res: Float = 0
            for v in a { res += v }
            return res
        }
        if n <= 128 {
            var r = [Float](a[base..<(base + 8)])
            var i = 8
            while i < n - (n % 8) {
                for j in 0..<8 { r[j] += a[base + i + j] }
                i += 8
            }
            var res = ((r[0] + r[1]) + (r[2] + r[3])) + ((r[4] + r[5]) + (r[6] + r[7]))
            while i < n {
                res += a[base + i]
                i += 1
            }
            return res
        }
        var n2 = n / 2
        n2 -= n2 % 8
        return pairwiseSum(a[base..<(base + n2)]) + pairwiseSum(a[(base + n2)...])
    }

    /// `np.std` of a list of Python floats: the population standard deviation, in double.
    static func standardDeviation(_ v: [Double]) -> Double {
        let mean = v.reduce(0, +) / Double(v.count)
        let variance = v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)
        return variance.squareRoot()
    }
}
