import Foundation

/// ITU-R BS.1770 loudness, and the gain that brings one part of speech to `targetLUFS` without its
/// sample peak passing `peakCeilingDBFS`.
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
    /// The highest sample peak a part may have after its gain, in dBFS.
    static let peakCeilingDBFS = -1.0
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
    /// it gains on its way to the output is counted, at most `maxGainDB`, then lowered as needed so
    /// the part's sample peak stays at or below `peakCeilingDBFS`. Silence keeps a gain of 1.
    static func gain(for samples: [Float], sampleRate: Double, lift: Double = 0) -> Float {
        guard let measured = integrated([samples], sampleRate: sampleRate) else { return 1 }
        var db = min(targetLUFS - measured - lift, maxGainDB)
        let peak = Double(samplePeak(samples))
        if peak > 0 { db = min(db, peakCeilingDBFS - 20 * log10(peak)) }
        return Float(pow(10, db / 20))
    }
}
