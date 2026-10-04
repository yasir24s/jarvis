import Foundation
import Testing
@testable import JarvisVoice

/// A streaming voice that answers each sentence with two pieces of `10 × characters` samples,
/// `delay` apart, and records what it was asked and which streams were ended early.
actor SentenceStreamEngine: SpeechEngine {
    nonisolated let id: EngineID = .qwen
    private let delay: Duration
    private(set) var asked: [String] = []
    private(set) var cancelled = 0

    init(delay: Duration = .milliseconds(5)) {
        self.delay = delay
    }

    func streaming() async -> Bool { true }
    func expectedSeconds(for text: String) async -> Double? { 1.0 }

    static func size(_ sentence: String) -> Int { sentence.unicodeScalars.count * 10 }

    func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        asked.append(sentence)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let delay = self.delay
        let task = Task {
            for _ in 0..<2 {
                try? await Task.sleep(for: delay)
                if Task.isCancelled { break }
                continuation.yield(PCMChunk(samples: [Float](repeating: 0, count: Self.size(sentence)), sampleRate: 24_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { termination in
            task.cancel()
            if case .cancelled = termination { Task { await self.ended() } }
        }
        return stream
    }

    private func ended() { cancelled += 1 }

    func release() async {}
}

@Suite("V8 a reply spoken as it is written (SpeechQueue.begin)", .timeLimit(.minutes(1)))
struct SpeakAsWrittenTests {
    static func queue(_ engine: any SpeechEngine, _ player: any SpeechPlayer, log: LogLines = LogLines()) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: FakeEngine(.say) { _ in [1] }, player: player, log: { log.append($0) })
    }

    static let first = "The meeting is at three on Friday."
    static let second = "Bring the quarterly notes."
    static let third = "I shall remind you an hour before."

    @Test func theFirstSentenceIsSpokenBeforeTheReplyEndsAndAllPlayAsOneStream() async throws {
        let engine = SentenceStreamEngine()
        let player = StreamRecordingPlayer()
        let log = LogLines()
        let queue = Self.queue(engine, player, log: log)
        let turn = UUID()
        await queue.begin(turn: turn, sentAt: .now)
        await queue.sentence(Self.first, turn: turn)
        // The brain is still writing: the first sentence is already being played.
        let firstPiece = "piece \(SentenceStreamEngine.size(Self.first))"
        #expect(await eventually { player.events.all.contains(firstPiece) })
        #expect(await engine.asked == [Self.first])
        await queue.sentence(Self.second, turn: turn)
        await queue.sentence(Self.third, turn: turn)
        await queue.end(turn: turn)
        await queue.idle()
        #expect(await engine.asked == [Self.first, Self.second, Self.third])
        let sizes = [Self.first, Self.second, Self.third].map(SentenceStreamEngine.size)
        let pieces = sizes.flatMap { ["piece \($0)", "piece \($0)"] }
        #expect(player.events.all == ["replyStarting", "replyReady", "stream 1.0"] + pieces + ["stream ended", "replyEnded"])
        #expect(log.all.contains { $0.hasPrefix("voice: speak-early first sentence after ") && $0.hasSuffix(" s (audio)") })
        #expect(log.all.contains { $0.hasPrefix("voice: \(sizes.map { $0 / 10 }.reduce(0, +)) chars in 3 part(s); first audio after") })
    }

    @Test func stopMidReplyCancelsTheSentencesNotYetGenerated() async throws {
        let engine = SentenceStreamEngine(delay: .milliseconds(200))
        let player = StreamRecordingPlayer()
        let queue = Self.queue(engine, player)
        let turn = UUID()
        await queue.begin(turn: turn)
        await queue.sentence(Self.first, turn: turn)
        await queue.sentence(Self.second, turn: turn)
        #expect(await eventually { player.events.all.contains("piece \(SentenceStreamEngine.size(Self.first))") })
        await queue.cancelAll(through: 1)
        await queue.sentence(Self.third, turn: turn)   // the brain is still writing: ignored
        await queue.end(turn: turn)
        await queue.idle()
        #expect(await !queue.isTaking(turn: turn))
        #expect(await !engine.asked.contains(Self.third))
        let events = player.events.all
        #expect(!events.contains("piece \(SentenceStreamEngine.size(Self.second))"))
        #expect(events.filter { $0 == "replyEnded" }.count == 1)
        #expect(events.contains("stop"))
        // A reply begun with the stop count from before that stop is dropped.
        #expect(await !queue.begin(turn: UUID(), stops: 0))
    }

    @Test func aShortAcknowledgementOpeningTheReplyIsNotSaidAgain() async throws {
        let engine = SentenceStreamEngine()
        let player = StreamRecordingPlayer()
        let queue = Self.queue(engine, player)
        await queue.acknowledge(PCMChunk(samples: [Float](repeating: 0, count: 12), sampleRate: 24_000),
                                line: "Certainly, sir.", sentAt: .now)
        let turn = UUID()
        await queue.begin(turn: turn)
        await queue.sentence("Certainly, sir.", turn: turn)
        await queue.sentence(Self.first, turn: turn)
        await queue.end(turn: turn)
        await queue.idle()
        #expect(await engine.asked == [Self.first])
        let events = player.events.all
        #expect(try #require(events.firstIndex(of: "play 12")) < #require(events.firstIndex(of: "replyReady")))
    }

    @Test func aReplyThatIsOnlyAShortAcknowledgementIsStillSaid() async throws {
        let engine = SentenceStreamEngine()
        let queue = Self.queue(engine, StreamRecordingPlayer())
        await queue.acknowledge(PCMChunk(samples: [Float](repeating: 0, count: 12), sampleRate: 24_000),
                                line: "Right away, sir.", sentAt: .now)
        let turn = UUID()
        await queue.begin(turn: turn)
        await queue.sentence("Very good, sir.", turn: turn)
        await queue.end(turn: turn)
        await queue.idle()
        #expect(await engine.asked == ["Very good, sir."])
    }

    @Test func aVoiceThatDoesNotStreamGetsTheReplyWholeAtTheEnd() async throws {
        let engine = FakeEngine(.f5) { _ in [Float](repeating: 0, count: 5) }
        let player = StreamRecordingPlayer()
        let queue = Self.queue(engine, player)
        let turn = UUID()
        await queue.begin(turn: turn)
        await queue.sentence(Self.first, turn: turn)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await engine.asked.isEmpty)
        await queue.sentence(Self.second, turn: turn)
        await queue.end(turn: turn)
        await queue.idle()
        #expect(await engine.asked == [Self.first + " " + Self.second])
        #expect(player.events.all == ["replyStarting", "replyReady", "play 5", "replyEnded"])
    }

    @Test func aNewReplyReplacesOneStillBeingWritten() async throws {
        let engine = SentenceStreamEngine()
        let player = StreamRecordingPlayer()
        let queue = Self.queue(engine, player)
        let one = UUID()
        await queue.begin(turn: one)
        await queue.sentence(Self.first, turn: one)
        await queue.say("Good evening, sir.", turn: UUID())
        await queue.sentence(Self.second, turn: one)   // the old reply's: ignored
        await queue.idle()
        #expect(await !engine.asked.contains(Self.second))
        #expect(await engine.asked.last == "Good evening, sir.")
        let events = player.events.all
        #expect(events.filter { $0 == "replyStarting" }.count == events.filter { $0 == "replyEnded" }.count)
    }
}
