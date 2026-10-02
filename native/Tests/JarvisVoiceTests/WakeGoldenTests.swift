import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing
@testable import JarvisVoice

/// The M11 wake corpus (Tests/Fixtures/golden/voice/wake: synthetic `say` voices) and its
/// derived inputs, rebuilt exactly as tools/golden_m11_wake.py builds them.
enum WakeCorpus {
    static let folder: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // JarvisVoiceTests/
        .deletingLastPathComponent()        // Tests/
        .appending(path: "Fixtures/golden/voice/wake", directoryHint: .isDirectory)

    static func clip(_ name: String) throws -> [Int16] {
        try WAVFile.samples(folder.appending(path: "\(name).wav"))
    }

    /// A corpus clip, or one of the suite's DERIVED inputs.
    static func input(_ name: String) throws -> [Int16] {
        let frame = WakeWordDetector.frameSamples
        switch name {
        case "silence_21s":
            return [Int16](repeating: 0, count: 260 * frame)
        case "min_every_100":
            var pcm = [Int16](repeating: 0, count: 260 * frame)
            for i in stride(from: 0, to: pcm.count, by: 100) { pcm[i] = .min }
            return pcm
        case "silence_gap":
            var pcm = [Int16](repeating: 0, count: 260 * frame)
            let noise = try clip("noise_m40dbfs")
            pcm.replaceSubrange(200 * frame..<201 * frame, with: noise[0..<frame])
            return pcm
        default:
            return try clip(name)
        }
    }

    /// Whole 1280-sample frames, as `for start in range(0, len(pcm) - FRAME + 1, FRAME)` takes them.
    static func frames(_ pcm: [Int16]) -> [MicFrame] {
        let n = WakeWordDetector.frameSamples
        return stride(from: 0, through: pcm.count - n, by: n).enumerated().map {
            MicFrame(samples: Array(pcm[$0.element..<$0.element + n]), index: UInt64($0.offset))
        }
    }
}

/// The seed noise the golden child gives openwakeword in place of np.random.randint: the k-th
/// draw of a 32-bit LCG (tools/golden_m11_wake.py's seed_noise).
final class WakeSeed: Sendable {
    private let draws = Mutex(0)

    static func noise(_ k: Int) -> [Int16] {
        var x = UInt32(truncatingIfNeeded: UInt64(k) &* 2_654_435_761 &+ 1)
        return (0..<WakeWordDetector.seedSamples).map { _ in
            x = 1_664_525 &* x &+ 1_013_904_223
            return Int16(Int(x >> 8) % 2000 - 1000)
        }
    }

    /// The next draw.
    func next() -> [Int16] {
        let k = draws.withLock { k in
            defer { k += 1 }
            return k
        }
        return Self.noise(k)
    }

    var count: Int { draws.withLock { $0 } }
}

enum WakeModels {
    static func detector(_ seed: WakeSeed) throws -> WakeWordDetector {
        let assets = try Vendor.assets(needing: [\.onnxRuntime, \.wakeMelModel, \.wakeEmbeddingModel,
                                                 \.wakeClassifierModel])
        return try WakeWordDetector(runtime: try OrtRuntime.load(dylib: assets.onnxRuntime), assets: assets,
                                    noise: { seed.next() })
    }
}

/// M11 part 2: openWakeWord's "hey jarvis" against the real openwakeword Model (golden suite
/// m11_oww), and `wait_for_wake_word` against jarvis.py's own (m11_wake_watch).
@Suite("M11 wake word (golden)", .serialized)
struct WakeGoldenTests {
    static let tolerance: Float = 1e-4

    @Test("the seed noise is the suite's LCG")
    func seed() {
        let first = WakeSeed.noise(0)
        #expect(first.count == 64_000)
        #expect(first.allSatisfy { (-1000..<1000).contains($0) })
        // x1 = 1664525 * 1 + 1013904223 = 1015568748; (x1 >> 8) % 2000 - 1000 = 65
        #expect(first[0] == 65)
        #expect(WakeSeed.noise(1) != first)
    }

    @Test("every frame's score, after a reset", arguments: try Golden.cases("m11_oww"))
    func scores(_ c: GoldenCase) async throws {
        let pcm = try WakeCorpus.input(try #require(c.input.string("clip")))
        let want = try #require(SpeakerCorpus.f32(c.expected.string("scores")))
        let seed = WakeSeed()
        let detector = try WakeModels.detector(seed)
        try detector.reset()
        var got: [Float] = []
        for frame in WakeCorpus.frames(pcm) {
            got.append(try detector.process(frame.samples))
            // A frame is three model runs: leave the cooperative pool to the timing-sensitive M8
            // tests in this target between them.
            await Task.yield()
        }
        #expect(got.count == want.count)
        let delta = SpeakerCorpus.maxDelta(got, want)
        #expect(delta <= Self.tolerance, "\(c.name): max |Δ| \(delta)")
        #expect(seed.count == Int(c.expected.int("seed_draws") ?? -1))
        // Fire or not at 0.5 and 0.15, frame by frame, unless a score is within the tolerance of
        // the threshold.
        for (threshold, key) in [(Float(0.5), "fires_05"), (Float(0.15), "fires_015")] {
            let pyFires = Set((c.expected.array(key) ?? []).compactMap { v -> Int? in
                if case .int(let i) = v { Int(i) } else { nil }
            })
            for (i, score) in got.enumerated() where abs(want[i] - threshold) > Self.tolerance {
                #expect((score >= threshold) == pyFires.contains(i), "\(c.name) frame \(i) at \(threshold)")
            }
        }
        print("M11 oww \(c.name): \(got.count) frames, max |Δ| \(delta), top \(got.max() ?? 0)")
    }

    @Test("the melspectrogram rows of four frames", arguments: try Golden.cases("m11_oww").filter { $0.expected.has("mel") })
    func mel(_ c: GoldenCase) throws {
        let pcm = try WakeCorpus.input(try #require(c.input.string("clip")))
        let detector = try WakeModels.detector(WakeSeed())
        let mels = try #require(c.expected.object("mel"))
        let n = WakeWordDetector.frameSamples
        for frame in [0, 1, 10, 30] {
            let entry = try #require(mels.object(String(frame)))
            let want = try #require(SpeakerCorpus.f32(entry.string("f32")))
            // _streaming_melspectrogram: the last n + 480 samples, all of them on the first frame.
            let window = pcm[max(0, frame * n - WakeWordDetector.lookback)..<(frame + 1) * n]
            let got = try detector.melspectrogram(window)
            #expect(got.count / WakeWordDetector.melBins == Int(entry.int("rows") ?? -1))
            #expect(SpeakerCorpus.maxDelta(got, want) <= Self.tolerance, "\(c.name) frame \(frame)")
        }
    }

    /// A frame source that counts what was read, and a clock that moves 80 ms a read, like the
    /// suite's stream.
    final class Reads: Sendable {
        private let count = Mutex(0)
        func read() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    struct CountingFrames: AsyncSequence, Sendable {
        typealias Element = MicFrame
        typealias Failure = Never
        let frames: [MicFrame]
        let reads: Reads

        struct AsyncIterator: AsyncIteratorProtocol {
            typealias Failure = Never
            let frames: [MicFrame]
            let reads: Reads
            var next = 0

            mutating func next() async -> MicFrame? {
                guard next < frames.count else { return nil }
                reads.read()
                next += 1
                return frames[next - 1]
            }
        }

        func makeAsyncIterator() -> AsyncIterator { AsyncIterator(frames: frames, reads: reads) }
    }

    final class Confirms: Sendable {
        private let state: Mutex<(heard: [String?], calls: [(after: Int, samples: Int)])>
        init(_ heard: [String?]) { state = Mutex((heard, [])) }

        func confirm(_ clip: [Int16], reads: Int) -> String? {
            state.withLock { s in
                s.calls.append((reads, clip.count))
                guard !s.heard.isEmpty, let t = s.heard.removeFirst() else { return nil }
                // _apply_corrections(whisper_transcribe(...).lower().strip()), with no corrections.
                return Py.strip(Py.lower(t))
            }
        }

        var calls: [(after: Int, samples: Int)] { state.withLock { $0.calls } }
    }

    @Test("wait_for_wake_word, case by case", arguments: try Golden.cases("m11_wake_watch"))
    func watch(_ c: GoldenCase) async throws {
        let clip = try #require(c.input.string("clip"))
        let soft = c.input["soft"] == .bool(true)
        let heard: [String?] = (c.input.array("heard") ?? []).map(\.stringValue)
        let frames = WakeCorpus.frames(try WakeCorpus.input(clip))
        let seed = WakeSeed()
        let reads = Reads()
        let confirms = Confirms(heard)
        let watcher = WakeWatcher(settings: WakeSettings(), makeDetector: { try WakeModels.detector(seed) },
                                  now: { 1_790_582_400 + 0.08 * Double(reads.value) })
        let confirm: WakeWatcher.Confirm? = soft ? { @Sendable clip in confirms.confirm(clip, reads: reads.value) } : nil
        let result = try await watcher.wait(frames: CountingFrames(frames: frames, reads: reads), confirm: confirm)
        let e = c.expected
        switch result {
        case .hard(let samples):
            #expect(e.string("kind") == "hard")
            #expect(samples.count == Int(e.int("samples") ?? -1))
        case .soft(let text, let samples):
            #expect(e.string("kind") == "soft")
            #expect(text == e.string("text"))
            #expect(samples.count == Int(e.int("samples") ?? -1))
        case .deadStream:
            #expect(e.string("kind") == "false" && e["dead_stream"] == .bool(true))
        case .ended:
            #expect(e.string("kind") == "false" && e["read_error"] == .bool(true))
        }
        #expect(reads.value == Int(e.int("reads") ?? -1), "reads")
        let want = (e.array("confirms") ?? []).compactMap(\.objectValue).map {
            (after: Int($0.int("after_read") ?? -1), samples: Int($0.int("samples") ?? -1))
        }
        #expect(confirms.calls.map(\.after) == want.map(\.after), "confirm reads")
        #expect(confirms.calls.map(\.samples) == want.map(\.samples), "confirm clip lengths")
        #expect(seed.count == Int(e.int("seed_draws") ?? -1), "seed draws (resets)")
    }
}

/// M11 part 2: the watcher's own rules, on synthetic frames.
@Suite("M11 wake watcher")
struct WakeWatcherTests {
    @Test("a frame is silent as numpy sees it: abs(-32768) stays -32768")
    func flat() {
        #expect(WakeWatcher.isFlat([0, 0, 0]))
        #expect(WakeWatcher.isFlat([0, .min, 0]))
        #expect(!WakeWatcher.isFlat([.min, .min]))
        #expect(!WakeWatcher.isFlat([0, 1, 0]))
        #expect(!WakeWatcher.isFlat([0, -1]))
    }

    @Test("WAKE_THRESHOLD and WAKE_SOFT come from the environment, as jarvis.py reads them")
    func settings() {
        #expect(WakeSettings.from([:]) == WakeSettings(threshold: 0.5, soft: 0.15))
        #expect(WakeSettings.from(["JARVIS_WAKE_THRESHOLD": " 0.6 ", "JARVIS_WAKE_SOFT": "0"])
                == WakeSettings(threshold: 0.6, soft: 0))
        var lines: [String] = []
        #expect(WakeSettings.from(["JARVIS_WAKE_SOFT": "low"], log: { lines.append($0) }).soft == 0.15)
        #expect(lines.count == 1)
    }

    @Test("WAKE_SOFT=0 turns the soft tier off; a frame stream that ends ends the wait")
    func softOff() async throws {
        let frames = WakeCorpus.frames(try WakeCorpus.clip("wake_bare_ralph_200"))
        let watcher = WakeWatcher(settings: WakeSettings(threshold: 0.5, soft: 0),
                                  makeDetector: { try WakeModels.detector(WakeSeed()) })
        let asked = WakeGoldenTests.Reads()
        let result = try await watcher.wait(frames: WakeGoldenTests.CountingFrames(frames: frames, reads: WakeGoldenTests.Reads()),
                                            confirm: { _ in asked.read(); return "jarvis" })
        #expect(result == .ended)
        #expect(asked.value == 0)
    }

    @Test("the soft tier asks M9a's transcriber, and gets its kept text lowercased and stripped")
    func confirmThroughTranscriber() async {
        let clip = [Int16](repeating: 100, count: 45 * MicFrame.sampleCount)
        let heard = FakeRecognizer(segments: [RecognizedSegment(text: " Hey Jarvis, what's the time? ", confidence: 0.9)])
        let transcriber = Transcriber(recognizer: heard, minimumConfidence: 0.3, research: CountingResearch(),
                                      corrections: { $0 }, log: { _ in })
        let confirm = WakeWatcher.confirming(with: transcriber, vocabulary: { ["Jarvis"] })
        #expect(await confirm(clip) == "hey jarvis, what's the time?")
        #expect(heard.appended == 45)
        #expect(heard.vocabulary == ["Jarvis"])
        let nothing = Transcriber(recognizer: FakeRecognizer(segments: []), research: CountingResearch(),
                                  corrections: { $0 }, log: { _ in })
        #expect(await WakeWatcher.confirming(with: nothing, vocabulary: { [] })(clip) == "")
        let broken = Transcriber(recognizer: FakeRecognizer(segments: [], readiness: .failed("fake")),
                                 research: CountingResearch(), corrections: { $0 }, log: { _ in })
        #expect(await WakeWatcher.confirming(with: broken, vocabulary: { [] })(clip) == nil)
    }
}
