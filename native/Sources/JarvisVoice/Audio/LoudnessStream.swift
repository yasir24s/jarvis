import Foundation

/// V6: `Loudness.normalized` for a reply that arrives in pieces (Qwen streams it), so the pieces
/// can play as they come and still meet the whole-part chain: the expander, the gain to
/// `Loudness.targetLUFS`, and the look-ahead limiter under `Loudness.peakCeilingDBFS`.
///
/// What a stream cannot know is its own future, and each stage needs some:
/// - The expander's threshold hangs off the speech level, here the level of everything heard so
///   far. Each piece is expanded in a window that starts `context` before it, so the gain it
///   follows has settled, and the last `expanderHold` (its look-ahead and window) is held back
///   until the next piece shows what follows.
/// - The gain is measured on everything expanded so far, so it converges on the whole reply's
///   gain as the reply goes on. A change of gain is ramped across the piece it applies to, so it
///   never steps. A first piece is a syllable or two, too little to measure well, so with a
///   `prior` (the gain the last reply ended on: the same voice, the same reference) the gain
///   starts there and moves to the measured one over the first `priorSeconds`, in dB.
/// - The limiter runs over a window that starts `context` back, and holds back its look-ahead
///   plus the six samples its in-between peaks read ahead.
/// `finish` processes the rest. The first piece waits for the second, so a stream of one piece
/// (as F5 gives) goes through `Loudness.normalized` whole and plays exactly as before.
///
/// Every sample is handed out once, in order, and the output is as long as the input.
final class LoudnessStream {
    let sampleRate: Double
    let lift: Double
    /// How far back each window starts, so the expander's and the limiter's state has settled.
    static let contextSeconds = 0.3
    /// Held back from the expander: its look-ahead and its level window, with room to spare.
    static let expanderHoldSeconds = 0.05
    /// How much audio it takes for the measured gain to replace the prior entirely.
    static let priorSeconds = 3.0

    private var raw: [Float] = []
    /// The block powers of `raw` and of `expanded`, kept as they grow.
    private var rawMeter: GrowingMeter
    private var expandedMeter: GrowingMeter
    /// Expanded samples, before the gain, for `[0, expandedEnd)`.
    private var expanded: [Float] = []
    /// The same with the gain applied, before the limiter.
    private var gained: [Float] = []
    private var pieces = 0
    /// Samples handed out, after the limiter.
    private(set) var emitted = 0
    /// The gain applied last: where the next reply's `prior` comes from.
    private(set) var gain: Float?
    private let prior: Float?

    init(sampleRate: Double, lift: Double = 0, prior: Float? = nil) {
        self.sampleRate = sampleRate
        self.lift = lift
        self.prior = prior
        rawMeter = GrowingMeter(sampleRate: sampleRate, kWeighted: false)
        expandedMeter = GrowingMeter(sampleRate: sampleRate, kWeighted: true)
    }

    private var context: Int { Int((Self.contextSeconds * sampleRate).rounded()) }
    private var expanderHold: Int { Int((Self.expanderHoldSeconds * sampleRate).rounded()) }
    /// The limiter's look-ahead, plus the six samples `Loudness.between` reads past a sample.
    private var limiterHold: Int { max(1, Int((Loudness.lookAheadSeconds * sampleRate).rounded())) + 8 }

    /// Takes the next piece and returns what is ready to play.
    func push(_ samples: [Float]) -> [Float] {
        raw.append(contentsOf: samples)
        rawMeter.append(samples)
        pieces += 1
        // The first piece waits for the second: a reply of one piece (F5's, when F5 stands in for
        // Qwen) then goes through the whole-part chain exactly, and Qwen's first piece is a few
        // milliseconds of audio that PreRoll would hold back anyway.
        guard pieces > 1 else { return [] }
        return process(final: false)
    }

    /// Ends the stream and returns the rest.
    func finish() -> [Float] {
        if emitted == 0 && expanded.isEmpty {
            emitted = raw.count
            return Loudness.normalized(raw, sampleRate: sampleRate, lift: lift)
        }
        return process(final: true)
    }

    private func process(final: Bool) -> [Float] {
        // Expand and gain what the expander can now see past.
        let expandEnd = final ? raw.count : max(expanded.count, raw.count - expanderHold)
        if expandEnd > expanded.count {
            let start = max(0, expanded.count - context)
            let level = rawMeter.gated(offset: 0)   // Loudness.speechLevel(raw)
            let window = Loudness.expanded(Array(raw[start..<raw.count]), sampleRate: sampleRate, level: level)
            let piece = window[(expanded.count - start)..<(expandEnd - start)]
            let from = expanded.count
            expanded.append(contentsOf: piece)
            expandedMeter.append(piece)
            // Loudness.gain(for: expanded), from the meter.
            var target: Float = expandedMeter.gated(offset: -0.691).map {
                Float(pow(10, min(Loudness.targetLUFS - $0 - lift, Loudness.maxGainDB) / 20))
            } ?? 1
            if let prior, prior > 0, target > 0 {
                let weight = min(1, Double(expanded.count) / (Self.priorSeconds * sampleRate))
                let dB = (1 - weight) * 20 * log10(Double(prior)) + weight * 20 * log10(Double(target))
                target = Float(pow(10, dB / 20))
            }
            let previous = gain ?? target
            let count = piece.count
            for (k, i) in (from..<expandEnd).enumerated() {
                let t = Float(k + 1) / Float(count)
                gained.append(expanded[i] * (previous + (target - previous) * t))
            }
            gain = target
        }
        // Limit what the limiter can now see past.
        let limitEnd = final ? gained.count : max(emitted, gained.count - limiterHold)
        guard limitEnd > emitted else { return [] }
        let start = max(0, emitted - context)
        let limited = Loudness.limited(Array(gained[start..<gained.count]), sampleRate: sampleRate)
        let out = Array(limited[(emitted - start)..<(limitEnd - start)])
        emitted = limitEnd
        return out
    }
}

/// V6: holds a streamed reply's audio back until `seconds` of it are in hand (or the stream has
/// ended), then lets everything through as it comes. Qwen's first piece is a few milliseconds
/// once the stretcher and LoudnessStream have kept their look-ahead back, and the next comes about
/// 0.2 s later: played at once, the reply would start with a blip, then a gap. Measured on four
/// replies of 99 to 300 characters, the gaps were all at the start (0.17 to 0.21 s after the first
/// 10 ms, and up to 0.05 s at 0.4 s); after that the stream kept ahead of the play head.
struct PreRoll {
    static let seconds = 0.2

    private let samples: Int
    private var held: [Float] = []
    private(set) var started = false

    init(sampleRate: Double, seconds: Double = PreRoll.seconds) {
        samples = Int((seconds * sampleRate).rounded())
    }

    /// What may play now of `audio`, with whatever was held before it.
    mutating func take(_ audio: [Float]) -> [Float] {
        if started { return audio }
        held += audio
        guard held.count >= samples else { return [] }
        return flush()
    }

    /// Everything held: the stream has ended.
    mutating func flush() -> [Float] {
        started = true
        defer { held = [] }
        return held
    }
}

/// V6: a growing mono signal's 400 ms block powers (every 100 ms), kept up to date as it grows, so
/// LoudnessStream measures the whole stream so far without going over it again for every piece.
/// K-weighted, it gives `Loudness.integrated`; plain, `Loudness.speechLevel`. Both match those
/// functions on the same samples (the tests check it).
struct GrowingMeter {
    private let block: Int
    private let step: Int
    private let filters: (shelf: Loudness.Biquad, highPass: Loudness.Biquad)?
    /// Each filter's x[n-1], x[n-2], y[n-1], y[n-2].
    private var shelfState = (0.0, 0.0, 0.0, 0.0)
    private var highPassState = (0.0, 0.0, 0.0, 0.0)
    /// running[n] is the sum of the first n (weighted) squares.
    private var running: [Double] = [0]
    /// The powers of the whole blocks so far.
    private var powers: [Double] = []

    init(sampleRate: Double, kWeighted: Bool) {
        block = Int((Loudness.blockSeconds * sampleRate).rounded())
        step = Int((Loudness.stepSeconds * sampleRate).rounded())
        filters = kWeighted ? Loudness.kWeighting(sampleRate: sampleRate) : nil
    }

    var count: Int { running.count - 1 }

    mutating func append<C: Collection>(_ samples: C) where C.Element == Float {
        running.reserveCapacity(running.count + samples.count)
        for sample in samples {
            var x = Double(sample)
            if let filters {
                x = Self.filter(x, filters.shelf, &shelfState)
                x = Self.filter(x, filters.highPass, &highPassState)
            }
            running.append(running[running.count - 1] + x * x)
        }
        while powers.count * step + block <= count {
            let start = powers.count * step
            powers.append((running[start + block] - running[start]) / Double(block))
        }
    }

    private static func filter(_ x: Double, _ f: Loudness.Biquad, _ s: inout (Double, Double, Double, Double)) -> Double {
        let out = f.b0 * x + f.b1 * s.0 + f.b2 * s.1 - f.a1 * s.2 - f.a2 * s.3
        s = (x, s.0, out, s.2)
        return out
    }

    /// The gated mean of the block powers in dB (`offset` added: -0.691 for LUFS), with the
    /// gates of `Loudness.integrated`; a signal shorter than a block is one block. nil when no
    /// block is above the absolute gate.
    func gated(offset: Double) -> Double? {
        guard count > 0 else { return nil }
        let all = powers.isEmpty ? [running[count] / Double(count)] : powers
        func dB(_ power: Double) -> Double { offset + 10 * log10(power) }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        let audible = all.filter { dB($0) > Loudness.absoluteGateLUFS }
        guard !audible.isEmpty else { return nil }
        let relativeGate = dB(mean(audible)) - Loudness.relativeGateLU
        return dB(mean(audible.filter { dB($0) > relativeGate }))
    }
}
