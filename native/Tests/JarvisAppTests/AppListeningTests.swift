import AVFAudio
import Foundation
@testable import JarvisApp
import JarvisChat
import JarvisCore
import JarvisTestSupport
import JarvisVoice
import Synchronization
import Testing

/// M9a: the app's push-to-talk composition (`AppListening`): the permissions, MicCapture, the
/// vocabulary from CoreState, the transcriber, the guard's counter and CoreState's corrections.
/// The device, the recogniser and TCC are fakes, so nothing opens the microphone.
@Suite("M9 app listening")
struct AppListeningTests {
    /// A device that pushes `seconds` of a 16 kHz tone as soon as it starts.
    final class PushingInput: MicInput, @unchecked Sendable {
        private let state = Mutex((starts: 0, stops: 0))
        let seconds: Double

        init(seconds: Double) { self.seconds = seconds }

        var starts: Int { state.withLock { $0.starts } }
        var stops: Int { state.withLock { $0.stops } }

        func inputFormat() throws(MicError) -> AVAudioFormat {
            AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        }

        func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
            state.withLock { $0.starts += 1 }
            let total = Int(16_000 * seconds)
            var n = 0
            while n < total {
                let count = min(1600, total - n)
                let b = AVAudioPCMBuffer(pcmFormat: try inputFormat(), frameCapacity: AVAudioFrameCount(count))!
                b.frameLength = AVAudioFrameCount(count)
                for i in 0..<count { b.floatChannelData![0][i] = 0.3 * Float(sin(2 * Double.pi * 300 * Double(n + i) / 16_000)) }
                tap(b, 0)
                n += count
            }
        }

        func stop() { state.withLock { $0.stops += 1 } }
    }

    /// Answers each utterance with fixed results and remembers what it was given.
    final class ScriptRecognizer: SpeechRecognizing, @unchecked Sendable {
        let results: [RecognizedSegment]
        private let state = Mutex((frames: 0, vocabulary: [String]()))

        init(_ results: [RecognizedSegment]) { self.results = results }

        var frames: Int { state.withLock { $0.frames } }
        var vocabulary: [String] { state.withLock { $0.vocabulary } }

        func readiness() async -> TranscriberError? { nil }

        func begin(contextualStrings: [String],
                   preview: @escaping @Sendable (String) -> Void) async throws -> any RecognitionSession {
            state.withLock { $0.vocabulary = contextualStrings }
            return Session(owner: self, preview: preview)
        }

        struct Session: RecognitionSession {
            let owner: ScriptRecognizer
            let preview: @Sendable (String) -> Void
            func append(_ frame: MicFrame) async {
                owner.state.withLock { $0.frames += 1 }
                preview("put the kettle")
            }
            func finish() async throws -> [RecognizedSegment] { owner.results }
            func cancel() async {}
        }
    }

    struct Permissions: PermissionAsking {
        let mic: PermissionStatus
        func microphone() -> PermissionStatus { mic }
        func requestMicrophone() async -> Bool { false }
        func speechRecognition() -> PermissionStatus { .granted }
        func requestSpeechRecognition() async -> Bool { false }
    }

    final class Counter: ResearchCounting, @unchecked Sendable {
        private let counts = Mutex([String: Int]())
        func bump(_ key: String, by n: Int) { counts.withLock { $0[key, default: 0] += n } }
        var all: [String: Int] { counts.withLock { $0 } }
    }

    struct NoFront: FrontAppProviding {
        func frontmostAppName() async -> String { "" }
    }

    static func core(_ sb: Sandbox) throws -> CoreState {
        try sb.write("profile.json", #"{"facts": {"name": {"value": "Ada", "updated": 1790582400.0}}}"#)
        try sb.write("corrections.json", #"[{"heard": "kettle", "meant": "Kettering", "at": 1790582400.0}]"#)
        let clock = JarvisCore.ManualClock(1_790_582_400)
        return CoreState(store: try StateStore(root: sb.root.path(percentEncoded: false), lease: nil, clock: clock),
                         clock: clock, research: Counter(), frontApp: NoFront())
    }

    @Test("an utterance: the vocabulary, the frames, the guard's counter, the corrections, and the mic closed after")
    func utterance() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let input = PushingInput(seconds: 1.6)
        let recognizer = ScriptRecognizer([RecognizedSegment(text: "Put the kettle on.", confidence: 0.93),
                                           RecognizedSegment(text: "mm", confidence: 0.05)])
        let research = Counter()
        let listening = AppListening(core: try Self.core(sb), research: research, permissions: Permissions(mic: .granted),
                                     makeInput: { input }, recognizer: recognizer, log: { _ in })
        #expect(await listening.access() == .granted)
        let previews = Mutex([String]())
        let levels = Mutex([Double]())
        try await listening.begin(level: { v in levels.withLock { $0.append(v) } },
                                  preview: { t in previews.withLock { $0.append(t) } })
        #expect(input.starts == 1)
        for _ in 0..<500 where recognizer.frames < 20 { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await listening.finish() == .text("Put the Kettering on."))
        #expect(input.stops == 1)
        #expect(recognizer.frames == 20)                       // 1.6 s at 16 kHz in 1280-sample frames
        #expect(recognizer.vocabulary.first == "Jarvis")
        #expect(Array(recognizer.vocabulary.suffix(2)) == ["Ada", "Kettering"])
        #expect(research.all == [ResearchKey.sttSegmentsDropped: 1])
        #expect(previews.withLock { $0 }.contains("put the kettle"))
        // A 0.3 tone is -13.5 dBFS rms: the meter reads it as full.
        #expect(levels.withLock { $0 }.allSatisfy { $0 == 1 })
    }

    @Test("denied, nothing opens")
    func denied() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let input = PushingInput(seconds: 0.5)
        let listening = AppListening(core: try Self.core(sb), research: Counter(), permissions: Permissions(mic: .denied),
                                     makeInput: { input }, recognizer: ScriptRecognizer([]), log: { _ in })
        #expect(await listening.access() == .microphoneDenied)
        #expect(input.starts == 0)
    }
}
