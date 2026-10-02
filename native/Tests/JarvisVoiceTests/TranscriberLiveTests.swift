import AVFAudio
import Foundation
import JarvisCore
import Speech
import Testing
@testable import JarvisVoice

/// M9 part 2's one live check: WAV files through the real SpeechTranscriber (en-GB, on-device),
/// cut into the mic's 1280-sample frames by the mic's own converter and slicer. Gated by
/// JARVIS_MIC_LIVE=1. It never opens the microphone. The speech clips are made with `say`
/// (Daniel, en-GB); the noise clips are generated. `JARVIS_MIC_LIVE_WAV` adds a WAV of your own.
/// Each result's text and confidence is printed: the numbers `STT_MIN_CONF` is set from.
@Suite("M9 transcriber live", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["JARVIS_MIC_LIVE"] == "1"))
struct TranscriberLiveTests {
    static let sentences = [
        "Jarvis, set a timer for ten minutes.",
        "What's the weather like in London tomorrow?",
        "Turn the volume down and take a screenshot.",
    ]

    /// The file's audio as the mic would deliver it: 16 kHz mono frames of 1280 samples.
    static func frames(of url: URL) throws -> [MicFrame] {
        let file = try AVAudioFile(forReading: url)
        let converter = try MicConverter(from: file.processingFormat)
        var slicer = FrameSlicer()
        var frames: [MicFrame] = []
        while file.framePosition < file.length {
            let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048)!
            try file.read(into: b, frameCount: 2048)
            if b.frameLength == 0 { break }
            frames += slicer.append(converter.convert(b))
        }
        return frames
    }

    static func stream(_ frames: [MicFrame]) -> AsyncStream<MicFrame> {
        AsyncStream { c in
            for f in frames { c.yield(f) }
            c.finish()
        }
    }

    static func say(_ text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/say")
        p.arguments = ["-v", "Daniel", "-o", url.path(percentEncoded: false), "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }

    /// 16 kHz mono Int16 WAV of `samples`.
    static func write(_ samples: [Int16], to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
                                   interleaved: true)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        b.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { b.int16ChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: b)
    }

    /// The results of one clip with their confidences, straight from the session.
    static func segments(_ frames: [MicFrame]) async throws -> [RecognizedSegment] {
        let session = try await AppleSpeechRecognizer().begin(
            contextualStrings: Vocabulary.contextualStrings(base: Vocabulary.defaultPrompt, name: nil, meant: []),
            preview: { _ in })
        for f in frames { await session.append(f) }
        return try await session.finish()
    }

    static func report(_ label: String, _ segs: [RecognizedSegment], seconds: Double) {
        let parts = segs.map { "\($0.text.debugDescription) conf \($0.confidence.map { String(format: "%.3f", $0) } ?? "nil")" }
        print("LIVE \(label) (\(String(format: "%.2f", seconds)) s audio): \(parts.isEmpty ? "no result" : parts.joined(separator: " | "))")
    }

    @Test("the en-GB model is installed and nothing is downloaded")
    func ready() async {
        let installed = await SpeechTranscriber.installedLocales.map(\.identifier).sorted()
        let status = await AssetInventory.status(forModules: [AppleSpeechRecognizer.makeTranscriber(Locale(identifier: "en_GB"))])
        print("LIVE installed locales: \(installed); AssetInventory status for en_GB: \(status)")
        let r = await AppleSpeechRecognizer().readiness()
        print("LIVE readiness: \(r.map(\.description) ?? "ready")")
        #expect(r == nil)
    }

    @Test("spoken sentences come back with their words and a confidence above the floor")
    func speech() async throws {
        let dir = try TempFolder()
        defer { dir.remove() }
        for (i, sentence) in Self.sentences.enumerated() {
            let url = dir.url.appending(path: "s\(i).wav")
            try Self.say(sentence, to: url)
            let frames = try Self.frames(of: url)
            let started = ContinuousClock.now
            let segs = try await Self.segments(frames)
            Self.report("say \(i) \(sentence.debugDescription) [\(ContinuousClock.now - started)]", segs,
                        seconds: Double(frames.count) * 0.08)
            #expect(!segs.isEmpty)
            for s in segs { #expect((s.confidence ?? 0) >= ConfidenceGuard.defaultMinimum, "\(s)") }
        }
        // The whole path, with the guard and a correction.
        let url = dir.url.appending(path: "s0.wav")
        let counter = CountingResearch()
        let t = Transcriber(recognizer: AppleSpeechRecognizer(), research: counter,
                            corrections: { $0.replacingOccurrences(of: "ten", with: "10") }, log: { print("LIVE log: \($0)") })
        let previews = LogLines()
        let outcome = await t.transcribe(Self.stream(try Self.frames(of: url)),
                                         vocabulary: Vocabulary.contextualStrings(base: Vocabulary.defaultPrompt,
                                                                                  name: nil, meant: []),
                                         preview: { previews.append($0) })
        print("LIVE outcome: \(outcome); \(previews.all.count) previews, last \(previews.all.last.debugDescription)")
        guard case .text(let text, _) = outcome else {
            Issue.record("no text: \(outcome)")
            return
        }
        #expect(text.lowercased().contains("timer"))
        #expect(!previews.all.isEmpty)
    }

    @Test("speech in white noise, from 20 dB SNR down to 0 dB: printed for the floor")
    func speechInNoise() async throws {
        let dir = try TempFolder()
        defer { dir.remove() }
        var rng = SplitMix(seed: 7)
        for (i, sentence) in Self.sentences.prefix(2).enumerated() {
            let url = dir.url.appending(path: "clean\(i).wav")
            try Self.say(sentence, to: url)
            let clean = try Self.frames(of: url).flatMap(\.samples)
            let rms = (clean.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(clean.count)).squareRoot()
            for snr in [20.0, 10.0, 5.0, 0.0] {
                let amplitude = rms / pow(10, snr / 20) * 3.0.squareRoot()     // uniform noise of that rms
                let mixed = clean.map { s in
                    Int16(max(-32768, min(32767, Double(s) + Double.random(in: -1...1, using: &rng) * amplitude)))
                }
                let noisy = dir.url.appending(path: "noisy\(i)-\(Int(snr)).wav")
                try Self.write(mixed, to: noisy)
                let frames = try Self.frames(of: noisy)
                Self.report("say \(i) at \(Int(snr)) dB SNR", try await Self.segments(frames),
                            seconds: Double(frames.count) * 0.08)
            }
        }
    }

    @Test("noise, hum and silence: printed for the floor, and none of it sent")
    func noise() async throws {
        let dir = try TempFolder()
        defer { dir.remove() }
        let n = 3 * 16_000
        var clips: [(String, [Int16])] = [
            ("silence", [Int16](repeating: 0, count: n)),
            ("hum 100 Hz + harmonics", (0..<n).map { i in
                let t = Double(i) / 16_000
                return Int16((sin(2 * .pi * 100 * t) + 0.5 * sin(2 * .pi * 200 * t) + 0.25 * sin(2 * .pi * 300 * t)) * 6000)
            }),
            ("chord melody", (0..<n).map { i in
                let t = Double(i) / 16_000
                let f = [261.6, 329.6, 392.0, 523.3][(i / 8000) % 4]
                return Int16((sin(2 * .pi * f * t) + 0.6 * sin(2 * .pi * f * 1.5 * t)) * 7000)
            }),
        ]
        // White noise (uniform, rms = level), seeded so a run can be repeated.
        for dBFS in [-30.0, -20.0, -10.0] {
            for seed in UInt64(1)...4 {
                var g = SplitMix(seed: seed)
                let amplitude = 32767 * pow(10, dBFS / 20) * 3.0.squareRoot()
                clips.append(("white noise \(Int(dBFS)) dBFS seed \(seed)", (0..<n).map { _ in
                    Int16(max(-32768, min(32767, (Double(g.next() >> 11) / Double(1 << 53) * 2 - 1) * amplitude)))
                }))
            }
        }
        let counter = CountingResearch()
        for (label, samples) in clips {
            let url = dir.url.appending(path: "clip.wav")
            try Self.write(samples, to: url)
            let frames = try Self.frames(of: url)
            let segs = try await Self.segments(frames)
            Self.report(label, segs, seconds: Double(frames.count) * 0.08)
            let t = Transcriber(recognizer: AppleSpeechRecognizer(), research: counter,
                                corrections: { $0 }, log: { print("LIVE log: \($0)") })
            let outcome = await t.transcribe(Self.stream(frames), vocabulary: [], preview: { _ in })
            print("LIVE \(label) outcome: \(outcome)")
            if case .text(let text, _) = outcome { Issue.record("\(label) was sent as \(text.debugDescription)") }
        }
        print("LIVE stt_segments_dropped over the noise clips: \(counter.counts[ResearchKey.sttSegmentsDropped] ?? 0)")
    }

    @Test("a WAV of your own (JARVIS_MIC_LIVE_WAV)",
          .enabled(if: ProcessInfo.processInfo.environment["JARVIS_MIC_LIVE_WAV"] != nil))
    func ownFile() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["JARVIS_MIC_LIVE_WAV"])
        let frames = try Self.frames(of: URL(filePath: path))
        let segs = try await Self.segments(frames)
        Self.report(URL(filePath: path).lastPathComponent, segs, seconds: Double(frames.count) * 0.08)
    }
}

/// SplitMix64: a seeded generator, so the noise clips are the same on every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
