import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing
@testable import JarvisVoice

/// The inputs of tools/golden_m11_listen.py, rebuilt sample for sample: say clips from the speaker
/// and wake corpora, the wake corpus's -60 dBFS floor, and integer operations on them.
enum ListenInputs {
    static let voice: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Fixtures/golden/voice", directoryHint: .isDirectory)

    static func read(_ folder: String, _ clip: String) throws -> [Int16] {
        try WAVFile.samples(voice.appending(path: "\(folder)/\(clip).wav"))
    }

    static func floor(_ n: Int) throws -> [Int16] {
        let one = Array(try read("wake", "wake_hey_daniel_200").prefix(16_000))
        return (0..<n).map { one[$0 % one.count] }
    }

    static func saturate(_ v: Int) -> Int16 { Int16(max(-32768, min(32767, v))) }

    static func mix(_ pcm: [Int16]) throws -> [Int16] {
        let f = try floor(pcm.count)
        return zip(pcm, f).map { saturate(Int($0) + Int($1)) }
    }

    static func part(_ spec: [JSONValue]) throws -> [Int16] {
        func int(_ i: Int) -> Int? { if case .int(let v) = spec[i] { Int(v) } else { nil } }
        func text(_ i: Int) -> String { spec[i].stringValue ?? "" }
        switch text(0) {
        case "floor": return try floor(int(1) ?? 0)
        case "mix": return try mix(try read(text(1), text(2)))
        case "clip": return try read(text(1), text(2))
        case "slice": return try mix(Array(try read(text(1), text(2))[(int(3) ?? 0)..<(int(4) ?? 0)]))
        case "gain": return try read(text(1), text(2)).map { saturate(Int($0) * (int(3) ?? 1)) }
        case "shift": return try read(text(1), text(2)).map { $0 >> Int16(int(3) ?? 0) }
        default: throw ListenInputError(spec: "\(spec)")
        }
    }

    static func build(_ parts: [JSONValue]) throws -> [Int16] {
        try parts.compactMap(\.arrayValue).flatMap { try part($0) }
    }

    /// 1280-sample reads, the last one short as PyAudio's slice would be.
    static func reads(_ pcm: [Int16]) -> [[Int16]] {
        stride(from: 0, to: pcm.count, by: EnergyEndpointer.chunk).map {
            Array(pcm[$0..<min($0 + EnergyEndpointer.chunk, pcm.count)])
        }
    }

    struct ListenInputError: Error { let spec: String }
}

/// M11 part 3: energy endpointing, listen_sentence and analyze_tone against the real code
/// (golden suites m11_endpoint, m11_sentence and m11_tone).
/// Serialized, and yielding between steps: the timing-sensitive M8 tests in this target share the
/// cooperative pool (see SpeakerCorpus.sharedEncoder).
@Suite("M11 listening (golden)", .serialized)
struct ListenGoldenTests {
    static func number(_ v: JSONValue?) -> Double? {
        switch v {
        case .double(let d)?: d
        case .int(let i)?: Double(i)
        default: nil
        }
    }

    @Test("SENT_PAUSE, PHRASE_LIMIT and the chunk are jarvis.py's")
    func constants() throws {
        let c = try #require(try Golden.cases("m11_endpoint").first { $0.name == "constants" })
        #expect(Self.number(c.expected["SENT_PAUSE"]) == SentenceListener.pause(environment: [:]))
        #expect(Self.number(c.expected["PHRASE_LIMIT"]) == SentenceListener.phraseLimit)
        #expect(c.expected.int("CHUNK") == Int64(EnergyEndpointer.chunk))
    }

    struct Outcome {
        var reads = 0
        var samples: Int?
        var timeout = false
        var threshold = 0.0
    }

    @Test("adjust_for_ambient_noise and listen, read by read", arguments: try Golden.cases("m11_endpoint").filter { $0.name != "constants" })
    func endpoint(_ c: GoldenCase) throws {
        let frames = ListenInputs.reads(try ListenInputs.build(try #require(c.input.array("parts"))))
        var e = EnergyEndpointer(pauseThreshold: 0.9)
        var pos = 0
        var thresholds: [Double] = []
        var results: [Outcome] = []
        for op in (c.input.array("ops") ?? []).compactMap(\.arrayValue) {
            let kind = op[0].stringValue ?? ""
            let arg = Self.number(op[1]) ?? 0
            let before = pos
            var outcome = Outcome()
            if kind == "calibrate" {
                for _ in 0..<e.calibrationBuffers(duration: arg) {
                    thresholds.append(e.energyThreshold)
                    e.calibrate(frames[pos])
                    pos += 1
                }
                e.energyThreshold = min(e.energyThreshold, SentenceListener.calibrationCap)
            } else {
                e.begin(timeout: arg, phraseTimeLimit: SentenceListener.phraseLimit)
                var done = false
                while !done {
                    switch e.next() {
                    case .timedOut:
                        outcome.timeout = true
                        done = true
                    case .ended(let clip):
                        outcome.samples = clip.count
                        done = true
                    case .read:
                        thresholds.append(e.energyThreshold)
                        let frame = frames[pos]
                        pos += 1
                        if case .ended(let clip) = e.feed(frame) {
                            outcome.samples = clip.count
                            done = true
                        }
                    }
                }
            }
            outcome.reads = pos - before
            outcome.threshold = e.energyThreshold
            results.append(outcome)
        }
        let want = (c.expected.array("results") ?? []).compactMap(\.objectValue)
        #expect(results.count == want.count)
        for (k, (got, py)) in zip(results, want).enumerated() {
            #expect(got.reads == Int(py.int("reads") ?? -1), "\(c.name) op \(k): reads")
            #expect(got.samples == py.int("samples").map { Int($0) }, "\(c.name) op \(k): samples")
            #expect(got.timeout == py.has("timeout"), "\(c.name) op \(k): timeout")
            #expect(got.threshold == Self.number(py["threshold"]), "\(c.name) op \(k): threshold")
        }
        let pyThresholds = (c.expected.array("thresholds") ?? []).compactMap { Self.number($0) }
        #expect(thresholds.count == pyThresholds.count, "\(c.name): reads")
        let worst = zip(thresholds, pyThresholds).map { abs($0 - $1) }.max() ?? 0
        #expect(worst <= 1e-9, "\(c.name): threshold trajectory max |Δ| \(worst)")
    }

    /// A transcriber that hears each utterance's frames and answers with the case's texts in turn.
    final class ScriptedTranscriber: Sendable {
        private let state: Mutex<(texts: [String], calls: [Int])>
        init(_ texts: [String]) { state = Mutex((texts, [])) }

        func transcribe(_ frames: AsyncStream<MicFrame>) async -> String {
            var samples = 0
            for await frame in frames { samples += frame.samples.count }
            // A phrase dropped as too short, or a listen that timed out, is never transcribed in
            // Python: a cancelled session neither counts nor takes a text.
            if Task.isCancelled { return "" }
            return state.withLock { s in
                s.calls.append(samples)
                return s.texts.isEmpty ? "" : s.texts.removeFirst()
            }
        }

        var calls: [Int] { state.withLock { $0.calls } }
    }

    @Test("listen_sentence", arguments: try Golden.cases("m11_sentence"))
    func sentence(_ c: GoldenCase) async throws {
        let pcm = try ListenInputs.build(try #require(c.input.array("parts")))
        let reads = ListenInputs.reads(pcm).enumerated().map { MicFrame(samples: $0.element, index: UInt64($0.offset)) }
        let pulled = Mutex(0)
        let stream = AsyncStream<MicFrame>(unfolding: {
            pulled.withLock { n -> MicFrame? in
                guard n < reads.count else { return nil }
                n += 1
                return reads[n - 1]
            }
        })
        let source = FrameSource(stream)
        let script = ScriptedTranscriber((c.input.array("texts") ?? []).compactMap(\.stringValue))
        let listener = SentenceListener(pause: 0.9, transcribe: { await script.transcribe($0) })
        #expect(await listener.calibrate(source))
        let calibrated = pulled.withLock { $0 }
        let e = c.expected
        do {
            let heard = try await listener.listen(source, timeout: Self.number(c.input["timeout"]) ?? 0)
            #expect(heard.text == e.string("text"))
            #expect(heard.clip.count == Int(e.int("samples") ?? -1))
        } catch {
            #expect(error == .timedOut && e.has("timeout"), "\(error)")
        }
        #expect(pulled.withLock { $0 } - calibrated == Int(e.int("reads") ?? -1), "reads")
        let calls = (e.array("calls") ?? []).compactMap(\.objectValue).map { Int($0.int("samples") ?? -1) }
        #expect(script.calls == calls, "transcribed clips")
        #expect(await listener.energyThreshold == Self.number(e["threshold"]))
    }

    @Test("analyze_tone", arguments: try Golden.cases("m11_tone"))
    func tone(_ c: GoldenCase) throws {
        let pcm = try ListenInputs.build(try #require(c.input.array("parts")))
        let text = c.input.string("text")
        let reading = ToneAnalyzer.reading(pcm, text: text)
        #expect((reading?.descriptor ?? "") == c.expected.string("descriptor"))
        #expect(ToneAnalyzer.analyze(pcm, text: text) == c.expected.string("descriptor"))
        if let loud = Self.number(c.expected["loud_db"]) {
            #expect(abs((reading?.loudDB ?? .nan) - loud) <= 1e-3, "loud_db \(String(describing: reading?.loudDB)) vs \(loud)")
        }
        if let f0s = c.expected.array("f0s")?.compactMap({ Self.number($0) }) {
            #expect(reading?.f0s.count == f0s.count, "pitches")
            #expect(zip(reading?.f0s ?? [], f0s).allSatisfy { abs($0 - $1) <= 1e-3 }, "pitches")
            #expect(abs((reading?.f0Std ?? .nan) - (Self.number(c.expected["f0_std"]) ?? 0)) <= 1e-3, "f0_std")
        }
    }
}
