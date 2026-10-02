import Foundation
import JarvisCore
import Synchronization
import Testing
@testable import JarvisVoice

/// M9 part 2: the transcriber's logic over a fake recogniser, so no test loads the speech model
/// or asks for a permission. The real SpeechTranscriber runs only in `TranscriberLiveTests`.
@Suite("M9 transcriber")
struct TranscriberTests {
    static func frames(_ n: Int) -> AsyncStream<MicFrame> {
        AsyncStream { c in
            for i in 0..<n { c.yield(MicFrame(samples: [Int16](repeating: 100, count: MicFrame.sampleCount), index: UInt64(i))) }
            c.finish()
        }
    }

    static func transcriber(_ fake: FakeRecognizer, counter: CountingResearch = CountingResearch(),
                            log: LogLines = LogLines(), minimum: Double = 0.5,
                            corrections: @escaping @Sendable (String) async -> String = { $0 }) -> Transcriber {
        Transcriber(recognizer: fake, minimumConfidence: minimum, research: counter, corrections: corrections,
                    log: { log.append($0) })
    }

    @Test("the guard drops results under the floor and keeps those without a confidence")
    func guardFilter() {
        let s = [RecognizedSegment(text: "a", confidence: 0.9), RecognizedSegment(text: "b", confidence: 0.49),
                 RecognizedSegment(text: "c", confidence: nil), RecognizedSegment(text: "d", confidence: 0.5)]
        let (kept, dropped) = ConfidenceGuard.filter(s, minimum: 0.5)
        #expect(kept.map(\.text) == ["a", "c", "d"])
        #expect(dropped.map(\.text) == ["b"])
        #expect(ConfidenceGuard.join([RecognizedSegment(text: " Hello.", confidence: 1),
                                      RecognizedSegment(text: "World. ", confidence: 1)]) == "Hello. World.")
        #expect(ConfidenceGuard.join([]) == "")
    }

    @Test("confidence is weighted by each run's duration")
    func weighted() {
        #expect(ConfidenceGuard.weightedMean([]) == nil)
        #expect(ConfidenceGuard.weightedMean([(duration: 3, confidence: 1), (duration: 1, confidence: 0)]) == 0.75)
        #expect(ConfidenceGuard.weightedMean([(duration: 0, confidence: 0.2), (duration: 0, confidence: 0.4)])! - 0.3 < 1e-12)
    }

    @Test("STT_LANG and STT_MIN_CONF come from the environment")
    func environment() {
        #expect(Transcriber.locale(environment: [:]) == "en-GB")
        #expect(Transcriber.locale(environment: ["JARVIS_STT_LANG": "en-US"]) == "en-US")
        #expect(ConfidenceGuard.minimum(environment: [:]) == ConfidenceGuard.defaultMinimum)
        #expect(ConfidenceGuard.minimum(environment: ["JARVIS_STT_MIN_CONF": " 0.3 "]) == 0.3)
        #expect(ConfidenceGuard.minimum(environment: ["JARVIS_STT_MIN_CONF": "lots"]) == ConfidenceGuard.defaultMinimum)
        #expect(ConfidenceGuard.minimum(environment: ["JARVIS_STT_MIN_CONF": "2"]) == ConfidenceGuard.defaultMinimum)
    }

    @Test("frames go in, the live text comes out, and only kept text reaches Corrections")
    func transcribes() async {
        let fake = FakeRecognizer(segments: [RecognizedSegment(text: "Set a timer", confidence: 0.92),
                                             RecognizedSegment(text: "mm", confidence: 0.21),
                                             RecognizedSegment(text: "for ten minutes.", confidence: 0.81)])
        let counter = CountingResearch()
        let log = LogLines()
        let seen = LogLines()
        let t = Self.transcriber(fake, counter: counter, log: log, corrections: { text in
            seen.append(text)
            return text.replacingOccurrences(of: "timer", with: "kitchen timer")
        })
        let previews = LogLines()
        let outcome = await t.transcribe(Self.frames(7), vocabulary: ["Jarvis", "timer"],
                                         preview: { previews.append($0) })
        #expect(outcome == .text("Set a kitchen timer for ten minutes.", dropped: 1))
        #expect(seen.all == ["Set a timer for ten minutes."])
        #expect(fake.appended == 7)
        #expect(fake.vocabulary == ["Jarvis", "timer"])
        #expect(previews.all == (1...7).map { "partial \($0)" })
        #expect(counter.counts == [ResearchKey.sttSegmentsDropped: 1])
        // The drop is logged with its measure, never the words.
        #expect(log.all == ["speech: 3 results, 1 dropped, confidence 0.92 0.21 0.81",
                            "STT dropped low-confidence segment (confidence 0.21, 2 chars)"])
    }

    @Test("every result dropped sends nothing, and each one counts")
    func allDropped() async {
        let fake = FakeRecognizer(segments: [RecognizedSegment(text: "the", confidence: 0.1),
                                             RecognizedSegment(text: "uh", confidence: 0.3)])
        let counter = CountingResearch()
        let outcome = await Self.transcriber(fake, counter: counter).transcribe(Self.frames(3), vocabulary: [],
                                                                                preview: { _ in })
        #expect(outcome == .nothing(dropped: 2))
        #expect(counter.counts == [ResearchKey.sttSegmentsDropped: 2])
    }

    @Test("no speech at all, and a release before the first frame, send nothing")
    func silence() async {
        let empty = FakeRecognizer(segments: [])
        #expect(await Self.transcriber(empty).transcribe(Self.frames(4), vocabulary: [], preview: { _ in })
                == .nothing(dropped: 0))
        let quick = FakeRecognizer(segments: [RecognizedSegment(text: "x", confidence: 1)])
        #expect(await Self.transcriber(quick).transcribe(Self.frames(0), vocabulary: [], preview: { _ in })
                == .nothing(dropped: 0))
        #expect(quick.cancelled)
    }

    @Test("a missing model is logged, nothing is downloaded, and the frames are still read")
    func missingAsset() async {
        let fake = FakeRecognizer(segments: [], readiness: .assetMissing("en-GB: supported"))
        let log = LogLines()
        let frames = Self.frames(5)
        let outcome = await Self.transcriber(fake, log: log).transcribe(frames, vocabulary: [], preview: { _ in })
        #expect(outcome == .unavailable(.assetMissing("en-GB: supported")))
        #expect(fake.begun == 0)
        #expect(log.all == ["speech: the speech model is not installed (en-GB: supported); not downloading it"])
        var rest = 0
        for await _ in frames { rest += 1 }
        #expect(rest == 0)
    }

    @Test("a recogniser that fails to start or finish is reported, not thrown")
    func failures() async {
        let noStart = FakeRecognizer(segments: [], failBegin: true)
        #expect(await Self.transcriber(noStart).transcribe(Self.frames(2), vocabulary: [], preview: { _ in })
                == .unavailable(.failed("fake: no start")))
        let noFinish = FakeRecognizer(segments: [], failFinish: true)
        #expect(await Self.transcriber(noFinish).transcribe(Self.frames(2), vocabulary: [], preview: { _ in })
                == .unavailable(.failed("fake: no finish")))
    }

    @Test("cancelling mid-utterance cancels the session")
    func cancel() async {
        let fake = FakeRecognizer(segments: [RecognizedSegment(text: "x", confidence: 1)])
        let t = Self.transcriber(fake)
        let (stream, c) = AsyncStream.makeStream(of: MicFrame.self)
        let task = Task { await t.transcribe(stream, vocabulary: [], preview: { _ in }) }
        c.yield(MicFrame(samples: [Int16](repeating: 0, count: MicFrame.sampleCount), index: 0))
        for _ in 0..<200 where fake.appended == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        c.yield(MicFrame(samples: [Int16](repeating: 0, count: MicFrame.sampleCount), index: 1))
        c.finish()
        #expect(await task.value == .cancelled)
        #expect(fake.cancelled)
    }
}

final class CountingResearch: ResearchCounting {
    private let store = Mutex<[String: Int]>([:])
    func bump(_ key: String, by n: Int) { store.withLock { $0[key, default: 0] += n } }
    var counts: [String: Int] { store.withLock { $0 } }
}

/// Answers with fixed final results; each appended frame sends a preview "partial <n>".
final class FakeRecognizer: SpeechRecognizing {
    private struct State {
        var appended = 0
        var begun = 0
        var cancelled = false
        var vocabulary: [String] = []
    }
    private let state = Mutex(State())
    let segments: [RecognizedSegment]
    let ready: TranscriberError?
    let failBegin: Bool
    let failFinish: Bool

    init(segments: [RecognizedSegment], readiness: TranscriberError? = nil, failBegin: Bool = false,
         failFinish: Bool = false) {
        self.segments = segments
        self.ready = readiness
        self.failBegin = failBegin
        self.failFinish = failFinish
    }

    var appended: Int { state.withLock { $0.appended } }
    var begun: Int { state.withLock { $0.begun } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var vocabulary: [String] { state.withLock { $0.vocabulary } }

    func readiness() async -> TranscriberError? { ready }

    func begin(contextualStrings: [String],
               preview: @escaping @Sendable (String) -> Void) async throws -> any RecognitionSession {
        if failBegin { throw TranscriberError.failed("fake: no start") }
        state.withLock {
            $0.begun += 1
            $0.vocabulary = contextualStrings
        }
        return Session(owner: self, preview: preview)
    }

    struct Session: RecognitionSession {
        let owner: FakeRecognizer
        let preview: @Sendable (String) -> Void

        func append(_ frame: MicFrame) async {
            let n = owner.state.withLock {
                $0.appended += 1
                return $0.appended
            }
            preview("partial \(n)")
        }

        func finish() async throws -> [RecognizedSegment] {
            if owner.failFinish { throw TranscriberError.failed("fake: no finish") }
            return owner.segments
        }

        func cancel() async { owner.state.withLock { $0.cancelled = true } }
    }
}
