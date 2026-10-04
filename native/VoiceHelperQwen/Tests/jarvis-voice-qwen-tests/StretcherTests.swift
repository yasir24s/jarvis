import Foundation
import Testing
@testable import jarvis_voice_qwen

/// V7: the stretcher as a slow, uneven stream feeds it. It is offline, so a stall in generation
/// changes nothing but when `push` is called: the output must be the same whatever the pieces,
/// and come out at exactly `1 / rate` of the input.
@Suite("V7 stretcher rate")
struct StretcherTests {
    static let sampleRate = 24_000.0
    static let rate = 1.5
    /// How far the output may trail 1/1.5 of the input, in output samples: the hold-back, one block
    /// of input still to come, and the unit's own latency (a tenth of a second, generously).
    static let lagBound = (Double(Stretcher.margin) + Double(Stretcher.block) * rate) / rate + 0.1 * sampleRate

    /// Seconds of a voice-like signal: a gliding tone with a slower one under it.
    static func signal(seconds: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { n in
            let t = Double(n) / sampleRate
            return Float(0.3 * sin(2 * .pi * (180 + 40 * t) * t) + 0.1 * sin(2 * .pi * 3 * t) * sin(2 * .pi * 900 * t))
        }
    }

    static func stretched(_ input: [Float], in sizes: [Int]) throws -> (out: [Float], perPush: [(Int, Int)], starved: Int) {
        let stretcher = try Stretcher(rate: rate, sampleRate: sampleRate)
        var out: [Float] = []
        var perPush: [(Int, Int)] = []
        var at = 0
        var k = 0
        while at < input.count {
            let end = min(input.count, at + sizes[k % sizes.count])
            let piece = try stretcher.push(Array(input[at..<end]))
            perPush.append((end - at, piece.count))
            out += piece
            at = end
            k += 1
        }
        out += try stretcher.finish()
        return (out, perPush, stretcher.starved)
    }

    /// The model's own pieces (0.32 s, 7,680 samples): once the hold-back is filled, every piece
    /// comes out at 1/1.5 of its length, to the sample.
    @Test func eachModelPieceComesOutAtTheRate() throws {
        let input = Self.signal(seconds: 12.8)
        let (out, perPush, starved) = try Self.stretched(input, in: [7_680])
        #expect(starved == 0)
        #expect(out.count == Int((Double(input.count) / Self.rate).rounded()))
        for (k, (inCount, outCount)) in perPush.enumerated() where k >= 2 {
            let ratio = Double(outCount) / Double(inCount)
            #expect(abs(ratio * Self.rate - 1) < 0.01, "piece \(k): \(inCount) in, \(outCount) out")
        }
    }

    /// A stalled, uneven stream (tiny pieces after a stall, then a burst) gives the same output,
    /// sample for sample, as the same audio stretched in model-sized pieces: no reset, no early
    /// flush, no second stretch. Over the stream the output never runs ahead of 1/1.5 of the input
    /// and never falls behind it by more than the hold-back and one block.
    @Test(arguments: [[100, 37, 3, 480], [960, 7_680, 25, 15_000, 1], [3, 3, 3, 30_000]])
    func anUnevenStreamComesOutTheSame(sizes: [Int]) throws {
        let input = Self.signal(seconds: 9.6)
        let steady = try Self.stretched(input, in: [7_680])
        let uneven = try Self.stretched(input, in: sizes)
        #expect(uneven.starved == 0)
        #expect(uneven.out.count == steady.out.count)
        let worst = zip(uneven.out, steady.out).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(worst < 1e-6, "largest difference \(worst)")
        var fedIn = 0
        var gotOut = 0
        var ahead = -Double.infinity
        var behind = 0.0
        for (inCount, outCount) in uneven.perPush {
            fedIn += inCount
            gotOut += outCount
            let due = Double(fedIn) / Self.rate
            ahead = max(ahead, Double(gotOut) - due)
            behind = max(behind, due - Double(gotOut))
        }
        print("stretcher \(sizes): at most \(ahead) ahead, \(behind) behind")
        #expect(ahead <= 1)
        #expect(behind <= Self.lagBound, "\(behind) samples behind")
    }
}
