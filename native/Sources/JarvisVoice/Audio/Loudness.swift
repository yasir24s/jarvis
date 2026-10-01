import Foundation

/// ITU-R BS.1770 loudness, the gain that brings one part of speech to `targetLUFS`, and a
/// look-ahead limiter that keeps its sample peak at or below `peakCeilingDBFS`.
///
/// K-weighting is the standard's two biquads: a high shelf of about +4 dB above 1.5 kHz, then a
/// high pass at about 38 Hz. Both are designed for the signal's own rate the way libebur128 does
/// it, which at 48 kHz gives the coefficients the standard publishes. Blocks are 400 ms long and
/// start every 100 ms. Blocks at or below the absolute gate (-70 LUFS) are dropped, then those at
/// or below the relative gate (10 LU under the loudness of the blocks left). A part shorter than
/// one block is measured as a single block.
enum Loudness {
    /// What every part is brought to, in LUFS.
    static let targetLUFS = -14.0
    /// The highest sample peak a part may have after the limiter, in dBFS.
    static let peakCeilingDBFS = -1.0
    /// The limiter's look-ahead, which is also its attack: the gain ramps down over this long
    /// before a peak and is at the peak's level when it arrives.
    static let lookAheadSeconds = 0.005
    /// The limiter's release: the time constant the gain recovers with after a peak.
    static let releaseSeconds = 0.05
    /// The most a part is ever raised, in dB, so near-silence and very short parts stay quiet.
    static let maxGainDB = 20.0
    static let blockSeconds = 0.4
    static let stepSeconds = 0.1
    static let absoluteGateLUFS = -70.0
    static let relativeGateLU = 10.0

    /// One second-order section, `y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]`.
    struct Biquad: Equatable {
        var b0, b1, b2, a1, a2: Double

        func apply(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for n in x.indices {
                let out = b0 * x[n] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x[n]
                y2 = y1
                y1 = out
                y[n] = out
            }
            return y
        }
    }

    /// The two K-weighting stages for `sampleRate`.
    static func kWeighting(sampleRate: Double) -> (shelf: Biquad, highPass: Biquad) {
        var k = tan(Double.pi * 1681.974450955533 / sampleRate)
        var q = 0.7071752369554196
        let vh = pow(10, 3.999843853973347 / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = Biquad(b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0,
                           b2: (vh - vb * k / q + k * k) / a0,
                           a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        k = tan(Double.pi * 38.13547087602444 / sampleRate)
        q = 0.5003270373238773
        a0 = 1 + k / q + k * k
        let highPass = Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0)
        return (shelf, highPass)
    }

    /// The integrated loudness of `channels` in LUFS, every channel weighted 1 (as left and right
    /// are), or nil when no block is above the absolute gate: silence has no loudness.
    static func integrated(_ channels: [[Float]], sampleRate: Double) -> Double? {
        let count = channels.map(\.count).min() ?? 0
        guard count > 0 else { return nil }
        let filters = kWeighting(sampleRate: sampleRate)
        let block = min(Int((blockSeconds * sampleRate).rounded()), count)
        let step = Int((stepSeconds * sampleRate).rounded())
        let starts = Array(stride(from: 0, through: count - block, by: step))
        // Per block, the K-weighted mean square summed over the channels.
        var powers = [Double](repeating: 0, count: starts.count)
        for channel in channels {
            let weighted = filters.highPass.apply(filters.shelf.apply(channel.prefix(count).map(Double.init)))
            var running = [Double](repeating: 0, count: count + 1)
            for n in 0..<count { running[n + 1] = running[n] + weighted[n] * weighted[n] }
            for (j, start) in starts.enumerated() {
                powers[j] += (running[start + block] - running[start]) / Double(block)
            }
        }
        func lufs(_ power: Double) -> Double { -0.691 + 10 * log10(power) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let audible = powers.filter { lufs($0) > absoluteGateLUFS }
        guard !audible.isEmpty else { return nil }
        let relativeGate = lufs(mean(audible)) - relativeGateLU
        // Never empty: the loudest block is above the mean, so above the relative gate.
        return lufs(mean(audible.filter { lufs($0) > relativeGate }))
    }

    /// The largest absolute sample.
    static func samplePeak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    /// The linear gain for one mono part: what brings it to `targetLUFS` once the `lift` (in dB)
    /// it gains on its way to the output is counted, at most `maxGainDB`. Its peaks are left to
    /// `limited`, so a peaky part is not turned down as a whole. Silence keeps a gain of 1.
    static func gain(for samples: [Float], sampleRate: Double, lift: Double = 0) -> Float {
        guard let measured = integrated([samples], sampleRate: sampleRate) else { return 1 }
        return Float(pow(10, min(targetLUFS - measured - lift, maxGainDB) / 20))
    }

    /// One part as the player plays it: `gain`, then `limited`.
    static func normalized(_ samples: [Float], sampleRate: Double, lift: Double = 0) -> [Float] {
        let gain = gain(for: samples, sampleRate: sampleRate, lift: lift)
        return limited(samples.map { $0 * gain }, sampleRate: sampleRate)
    }

    /// A look-ahead peak limiter over a whole part: no sample comes out above `peakCeilingDBFS`,
    /// and samples away from a peak are untouched.
    ///
    /// A sample's peak is the largest of |x| and the part read at a quarter, a half and three
    /// quarters of the way to the samples either side (`between`), since the device's rate
    /// converter draws those in-between values: 3 kHz bursts limited on their samples alone came
    /// out of a 48 kHz render 0.13 dB over the ceiling. Each sample needs a gain of
    /// min(1, ceiling / peak). The gain curve is the lowest need within
    /// the next `lookAheadSeconds` (L samples), recovering after a peak with a `releaseSeconds`
    /// time constant, then averaged over the last L + 1 samples. Every value in that average is at
    /// most the current sample's need, since the current sample is inside each one's look-ahead,
    /// so the curve meets every peak at or below its need, after a linear L-sample attack.
    static func limited(_ samples: [Float], sampleRate: Double) -> [Float] {
        // The largest Float at or below the ceiling, so a sample at the limit reads -1 dBFS or less.
        var limit = Float(pow(10, peakCeilingDBFS / 20))
        if Double(limit) > pow(10, peakCeilingDBFS / 20) { limit = limit.nextDown }
        let ceiling = Double(limit)
        // Values between samples rise above the samples by a few dB at most.
        guard samples.contains(where: { abs($0) > limit / 2 }) else { return samples }
        let peaks = between(samples)
        guard peaks.contains(where: { $0 > ceiling }) else { return samples }
        let look = max(1, Int((lookAheadSeconds * sampleRate).rounded()))
        let recovery = 1 - exp(-1 / (releaseSeconds * sampleRate))
        // L samples of silence on each side, so the first and last peaks get a whole attack.
        let n = samples.count + 2 * look
        var need = [Double](repeating: 1, count: n)
        for (i, peak) in peaks.enumerated() where peak > ceiling { need[i + look] = ceiling / peak }
        // The lowest need in [i, i + L], a sliding minimum kept in a queue of increasing needs.
        var ahead = [Double](repeating: 1, count: n)
        var queue: [Int] = []
        var head = 0
        for j in stride(from: n - 1, through: 0, by: -1) {
            while queue.count > head, need[queue[queue.count - 1]] >= need[j] { queue.removeLast() }
            queue.append(j)
            while queue[head] > j + look { head += 1 }
            ahead[j] = need[queue[head]]
        }
        var curve = [Double](repeating: 1, count: n)
        var level = 1.0
        for j in 0..<n {
            level = min(ahead[j], level + (1 - level) * recovery)
            curve[j] = level
        }
        var out = [Float](repeating: 0, count: samples.count)
        var sum = 0.0
        for j in 0..<n {
            sum += curve[j]
            if j > look { sum -= curve[j - look - 1] }
            let i = j - look
            guard i >= 0, i < samples.count else { continue }
            // Rounding in the running sum must not let a sample over the ceiling.
            out[i] = max(-limit, min(limit, Float(Double(samples[i]) * (sum / Double(look + 1)))))
        }
        return out
    }

    /// The taps that read a part at 1/4, 1/2 and 3/4 of the way from sample n to n + 1: a sinc
    /// under a Hann window six samples wide each side, over samples n - 5 ... n + 6, each set
    /// summing to 1.
    static let quarterTaps: [[Double]] = [0.25, 0.5, 0.75].map { phase in
        let taps = (-5...6).map { k -> Double in
            let t = Double(k) - phase
            return sin(Double.pi * t) / (Double.pi * t) * (0.5 + 0.5 * cos(Double.pi * t / 6))
        }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }

    /// For each sample, the largest of |x[n]| and the values read between it and its neighbours.
    static func between(_ x: [Float]) -> [Double] {
        let n = x.count
        // The largest |value| read between sample i and i + 1.
        var gap = [Double](repeating: 0, count: max(0, n - 1))
        for i in 0..<max(0, n - 1) {
            for taps in quarterTaps {
                var v = 0.0
                for (j, h) in taps.enumerated() {
                    let k = i - 5 + j
                    if k >= 0, k < n { v += h * Double(x[k]) }
                }
                gap[i] = max(gap[i], abs(v))
            }
        }
        return (0..<n).map { i in
            max(Double(abs(x[i])), i > 0 ? gap[i - 1] : 0, i < n - 1 ? gap[i] : 0)
        }
    }
}
