import Foundation
@testable import JarvisApp
import JarvisVoice
import Synchronization
import Testing

/// A streaming voice (Qwen's shape) that answers each sentence with one piece of
/// `10 × characters` samples and records what it was asked, in order.
actor EarlyStreamEngine: SpeechEngine {
    nonisolated let id: EngineID = .qwen
    private(set) var asked: [String] = []

    func streaming() async -> Bool { true }
    func expectedSeconds(for text: String) async -> Double? { 1.0 }

    func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        asked.append(sentence)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let task = Task {
            try? await Task.sleep(for: .milliseconds(5))
            if !Task.isCancelled {
                continuation.yield(PCMChunk(samples: [Float](repeating: 0, count: sentence.unicodeScalars.count * 10),
                                            sampleRate: 24_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func release() async {}
}

/// Records the player's calls; each streamed reply is one "stream" with its pieces.
final class EarlyRecordingPlayer: SpeechPlayer {
    let events = Mutex<[String]>([])
    var all: [String] { events.withLock { $0 } }
    private func note(_ e: String) { events.withLock { $0.append(e) } }

    func play(_ chunk: PCMChunk) async throws { note("play \(chunk.samples.count)") }
    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        note("stream")
        for try await piece in pieces {
            note("piece \(piece.samples.count)")
            if Task.isCancelled { break }
        }
        note("stream ended")
    }
    func stop() async { note("stop") }
    func replyStarting() async { note("replyStarting") }
    func replyReady() async {}
    func replyEnded() async { note("replyEnded") }
    func lastStream() async -> StreamReport? { nil }
}

/// V8, with fakes: Speak First Sentence Early with Qwen speaks a typed reply as the brain writes
/// it (`EarlySpeech` feeding a real `SpeechQueue`).
@Suite("V8 speak a reply as it is written (EarlySpeech)", .timeLimit(.minutes(1)))
@MainActor
struct EarlySpeechTests {
    @MainActor
    final class Rig {
        let engine: EarlyStreamEngine
        let player: EarlyRecordingPlayer
        let logs: Lines
        let queue: SpeechQueue
        var applies = true
        var stops = 0
        var began: [String] = []
        var over = 0
        var early: EarlySpeech!

        @MainActor
        init() {
            let logs = Lines()
            self.logs = logs
            let engine = EarlyStreamEngine()
            let player = EarlyRecordingPlayer()
            self.engine = engine
            self.player = player
            queue = SpeechQueue(engine: engine, fallback: EarlyStreamEngine(), player: player,
                                log: { logs.append($0) })
            early = EarlySpeech(queue: queue, hooks: .init(
                applies: { [unowned self] in self.applies },
                stops: { [unowned self] in self.stops },
                began: { [unowned self] first in self.began.append(first) },
                over: { [unowned self] in self.over += 1 },
                handed: { _ in },
                log: { logs.append($0) }))
        }

        var log: [String] { logs.all }

        /// What the app's stop does: EarlySpeech first, then the queue's cancelAll.
        func stop() async {
            early.stop()
            stops += 1
            await queue.cancelAll(through: stops)
        }
    }

    /// A brain that streams its reply in chunks, `gap` apart, into `early`, then says it is done.
    @MainActor
    final class FakeStreamingBrain {
        let chunks: [String]
        let gap: Duration
        /// After this many chunks the brain waits for `release()`; nil never waits.
        let holdAfter: Int?
        private(set) var done = false
        private var released = false

        init(_ chunks: [String], gap: Duration = .milliseconds(40), holdAfter: Int? = nil) {
            self.chunks = chunks
            self.gap = gap
            self.holdAfter = holdAfter
        }

        var reply: String { chunks.joined() }

        func release() { released = true }

        @MainActor
        func run(into early: EarlySpeech, turn: UUID) async {
            for (n, chunk) in chunks.enumerated() {
                if n == holdAfter {
                    while !released { try? await Task.sleep(for: .milliseconds(5)) }
                }
                try? await Task.sleep(for: gap)
                early.delta(chunk, turn: turn)
            }
            done = true
        }
    }

    static func eventually(_ condition: () async -> Bool) async -> Bool {
        let clock = SuspendingClock()
        let end = clock.now + .seconds(30)
        while clock.now < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    static let reply = ["The meeting is ", "at three on ", "Friday. Bring ", "the quarterly ", "notes. I shall ",
                        "remind you an ", "hour before."]
    static let sentences = ["The meeting is at three on Friday.", "Bring the quarterly notes.",
                            "I shall remind you an hour before."]

    @Test func theFirstSentenceIsSpokenBeforeTheBrainFinishesThenTheRestInOrderAsOneStream() async throws {
        let rig = Rig()
        // The brain stops after its first sentence until the test has heard it: load-proof.
        let brain = FakeStreamingBrain(Self.reply, gap: .milliseconds(20), holdAfter: 3)
        let turn = UUID()
        let writing = Task { await brain.run(into: rig.early, turn: turn) }
        #expect(await Self.eventually { rig.player.all.contains("piece \(Self.sentences[0].count * 10)") })
        #expect(!brain.done, "the first sentence was played while the brain still wrote")
        #expect(await rig.engine.asked == [Self.sentences[0]])
        brain.release()
        await writing.value
        #expect(rig.early.finished(brain.reply, turn: turn))
        #expect(await Self.eventually { rig.over == 1 })
        #expect(await rig.engine.asked == Self.sentences)
        let pieces = Self.sentences.map { "piece \($0.count * 10)" }
        #expect(rig.player.all == ["replyStarting", "stream"] + pieces + ["stream ended", "replyEnded"])
        #expect(rig.began == [Self.sentences[0]])
        #expect(rig.log.contains { $0.hasPrefix("voice: speak-early first sentence after ") })
    }

    @Test func abbreviationsDecimalsAndNumbersAreNotSplit() async throws {
        let rig = Rig()
        let brain = FakeStreamingBrain(["Dr. Smith ", "can see you ", "at 3.", "5 past nine. Call ", "020 7946 ",
                                        "0018 or go to example.com/", "book. Thank you, sir."], gap: .milliseconds(5))
        let turn = UUID()
        await brain.run(into: rig.early, turn: turn)
        #expect(rig.early.finished(brain.reply, turn: turn))
        #expect(await Self.eventually { rig.over == 1 })
        #expect(await rig.engine.asked == ["Dr. Smith can see you at 3.5 past nine.",
                                           "Call 020 7946 0018 or go to example.com/book.", "Thank you, sir."])
    }

    @Test func stopMidReplyCancelsWhatIsStillComing() async throws {
        let rig = Rig()
        let brain = FakeStreamingBrain(Self.reply, gap: .milliseconds(60))
        let turn = UUID()
        let writing = Task { await brain.run(into: rig.early, turn: turn) }
        #expect(await Self.eventually { await rig.engine.asked.first == Self.sentences[0] })
        await rig.stop()
        await writing.value
        #expect(rig.early.finished(brain.reply, turn: turn), "handled: a stopped reply is not spoken again")
        #expect(await Self.eventually { rig.over == 1 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await rig.engine.asked == [Self.sentences[0]])
        #expect(rig.player.all.filter { $0 == "replyEnded" }.count == 1)
        #expect(rig.log.contains("voice: speak-early: the reply was stopped; the rest is not spoken"))
    }

    @Test func aBrainThatRepliesWholeTakesTheOldPath() {
        let rig = Rig()
        let turn = UUID()
        #expect(!rig.early.finished(Self.sentences.joined(separator: " "), turn: turn))
        #expect(rig.began.isEmpty)
    }

    @Test func aReplyWhoseOnlySentenceEndsTheStreamTakesTheOldPath() async {
        let rig = Rig()
        let turn = UUID()
        rig.early.delta("Good evening, sir.", turn: turn)
        #expect(!rig.early.finished("Good evening, sir.", turn: turn))
        #expect(await rig.engine.asked.isEmpty)
    }

    @Test func theSettingIsRespected() async throws {
        let rig = Rig()
        rig.applies = false
        let brain = FakeStreamingBrain(Self.reply, gap: .milliseconds(1))
        let turn = UUID()
        await brain.run(into: rig.early, turn: turn)
        rig.applies = true   // switched on mid-turn: the turn stays as it was decided
        rig.early.delta(" More.", turn: turn)
        #expect(!rig.early.finished(brain.reply, turn: turn))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await rig.engine.asked.isEmpty)
        #expect(rig.began.isEmpty)
    }

    @Test func aRewrittenFinalReplyIsNotSpokenAgain() async throws {
        let rig = Rig()
        let turn = UUID()
        rig.early.delta("The meeting is at three on Friday. Bring", turn: turn)
        #expect(rig.early.finished("The meeting is at four on Friday. Bring the notes.", turn: turn))
        #expect(await Self.eventually { rig.over == 1 })
        #expect(await rig.engine.asked == [Self.sentences[0]])
        #expect(rig.log.contains { $0.contains("the final reply differs from what streamed") })
    }

    @Test func theFinalRepliesTailIsSpoken() async throws {
        let rig = Rig()
        let turn = UUID()
        rig.early.delta("The meeting is at three on Friday. Bring the quarterly", turn: turn)
        #expect(rig.early.finished("The meeting is at three on Friday.\n\nBring the quarterly notes. Thank you.", turn: turn))
        #expect(await Self.eventually { rig.over == 1 })
        #expect(await rig.engine.asked == [Self.sentences[0], Self.sentences[1], "Thank you."])
    }

    @Test func theAcknowledgementIsSkippedWhenTheFirstSentenceIsReadyWithinTheWindow() async throws {
        let rig = Rig()
        let played = Lines()
        let sentAt = ContinuousClock.now
        #expect(rig.early.acknowledge(sentAt: sentAt) { played.append("ack") })
        rig.early.delta("Right. The meeting is at three. ", turn: UUID())
        try await Task.sleep(for: .milliseconds(450))
        #expect(played.all.count == 0)
        #expect(rig.log.contains { $0.contains("acknowledgement skipped") })
    }

    @Test func theAcknowledgementPlaysWhenTheFirstSentenceIsSlow() async throws {
        let rig = Rig()
        let played = Lines()
        rig.early.acknowledge(sentAt: .now) { played.append("ack") }
        #expect(await Self.eventually { played.all.count == 1 })
        rig.early.delta("The meeting is at three. ", turn: UUID())
        #expect(!rig.log.contains { $0.contains("acknowledgement skipped") })
    }

    @Test func withoutTheSettingTheAcknowledgementPlaysAtOnce() {
        let rig = Rig()
        rig.applies = false
        let played = Lines()
        #expect(!rig.early.acknowledge(sentAt: .now) { played.append("ack") })
        #expect(played.all.count == 1)
    }

    @Test func aReplyPastTheSpeakLimitStopsBeingHandedOver() async throws {
        let rig = Rig()
        let turn = UUID()
        let sentence = String(repeating: "word ", count: 30) + "end. "   // 154 characters once popped
        rig.early.delta(String(repeating: sentence, count: 5), turn: turn)
        rig.early.notSpoken(turn: turn)
        #expect(await Self.eventually { rig.over == 1 })
        #expect(await rig.engine.asked.count == 3)
        #expect(rig.log.contains { $0.contains("passed 600 chars") })
    }
}

/// Lines kept from any thread.
final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    func append(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
}
