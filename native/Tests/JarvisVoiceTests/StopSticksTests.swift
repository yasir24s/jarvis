import Foundation
import Testing
@testable import JarvisVoice

/// Stop Speaking sticks, the queue's part: `cancelAll(through:)` stops what is in hand, and a
/// reply or acknowledgement asked for before that stop is dropped however late it arrives. One
/// asked for after it speaks. Fake engines and players only: nothing reaches the speakers.
@Suite("Stop Speaking sticks: SpeechQueue")
struct StopSticksQueueTests {
    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    static let clip = PCMChunk(samples: [Float](repeating: 0.2, count: 500), sampleRate: 24_000)

    private func queue(_ engine: any SpeechEngine, _ player: any SpeechPlayer) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: FakeEngine(.say, respond: Self.quick), player: player, log: { _ in })
    }

    @Test func stopDuringGenerationStopsItAndNothingPlays() async {
        let f5 = FakeEngine(.f5) { _ in
            try await Task.sleep(for: .seconds(30))
            return [0.1]
        }
        let player = FakePlayer()
        let speech = queue(f5, player)
        await speech.say("A slow reply.", turn: UUID(), stops: 0)
        #expect(await eventually { await f5.asked.count == 1 })
        await speech.cancelAll(through: 1)
        await speech.idle()
        #expect(await player.played.isEmpty)
    }

    @Test func stopDuringTheAcknowledgementStopsItAndTheReplyAfterIt() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let speech = queue(f5, player)
        await speech.acknowledge(Self.clip, line: "Right away, sir.", sentAt: .now, stops: 0)
        #expect(await eventually { await player.waiting == 1 })
        await speech.cancelAll(through: 1)
        // The reply to that message comes after the stop, asked for before it.
        await speech.say("Here is the answer.", turn: UUID(), stops: 0)
        await speech.idle()
        #expect(await player.played == [500])
        #expect(await f5.asked.isEmpty)
        #expect(await player.stops >= 1)
    }

    @Test func stopDuringPlaybackStopsTheReply() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let speech = queue(f5, player)
        await speech.say("One one. Two two.", turn: UUID(), stops: 0)
        #expect(await eventually { await player.waiting == 1 })
        await speech.cancelAll(through: 1)
        await speech.idle()
        #expect(await player.waiting == 0)
        #expect(await player.played == [17])
    }

    /// The report: Stop, then the reply of the request he was answering arrives and was spoken.
    @Test func aLateReplyAskedForBeforeTheStopIsDropped() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer()
        let speech = queue(f5, player)
        await speech.cancelAll(through: 1)
        await speech.say("A late reply.", turn: UUID(), stops: 0)
        await speech.acknowledge(Self.clip, line: "Right away, sir.", sentAt: .now, stops: 0)
        await speech.idle()
        #expect(await f5.asked.isEmpty)
        #expect(await player.played.isEmpty)
    }

    @Test func aReplyAskedForAfterTheStopSpeaks() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer()
        let speech = queue(f5, player)
        await speech.cancelAll(through: 1)
        await speech.say("A new request.", turn: UUID(), stops: 1)
        await speech.idle()
        #expect(await f5.asked == ["A new request."])
        #expect(await player.played == [14])
        // Without a count (the tests and callers that predate the gate) nothing is dropped.
        await speech.say("No count.", turn: UUID())
        await speech.idle()
        #expect(await player.played == [14, 9])
    }

    @Test func aSpeakEarlyReplysLaterPartIsNotPlayedAfterTheStop() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: player,
                                 speakEarly: { true }, sentences: SpeakEarlyTests.sentences, log: { _ in })
        await speech.say(SpeakEarlyTests.reply, turn: UUID(), stops: 0)
        #expect(await eventually { await player.waiting == 1 })
        await speech.cancelAll(through: 1)
        await speech.idle()
        #expect(await player.played.count == 1, "only the first part played")
    }

    @Test func aStreamedReplysLaterPiecesAreNotPlayedAfterTheStop() async {
        let engine = FakeStreamEngine(pieces: QwenVoiceTests.pieces([100, 200, 300]))
        let player = StreamRecordingPlayer()
        let speech = SpeechQueue(engine: engine, fallback: FakeEngine(.say) { _ in [1] }, player: player, log: { _ in })
        await speech.say("Good evening, sir.", turn: UUID(), stops: 0)
        #expect(await eventually { player.events.all.contains("piece 100") })
        await speech.cancelAll(through: 1)
        #expect(await eventually { await engine.terminated >= 1 })
        // The same request's reply handed over again after the stop is dropped too.
        await speech.say("Good evening, sir.", turn: UUID(), stops: 0)
        await speech.idle()
        #expect(!player.events.all.contains("piece 300"))
        #expect(await engine.asked == ["Good evening, sir."])
    }
}
