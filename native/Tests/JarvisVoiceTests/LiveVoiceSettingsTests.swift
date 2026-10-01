import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// U1 part 5: the voice settings are read when they are used, never once for the life of the
/// process. voiceSpeed for each reply and at each helper launch; voiceChunkChars for each reply.
/// The settings come through injected closures here: nothing reads or writes the app's defaults.
@Suite("U1 voice settings are read live")
struct LiveVoiceSettingsTests {
    /// A setting the test changes between replies.
    final class Setting<Value: Sendable>: Sendable {
        private let value: Mutex<Value>
        init(_ value: Value) { self.value = Mutex(value) }
        var current: Value { value.withLock { $0 } }
        func set(_ newValue: Value) { value.withLock { $0 = newValue } }
    }

    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    /// 83 + 1 + 36 characters: at speed 1 the first part's audio covers the second's generation,
    /// so they are two parts; at 1.4 it does not, and the reply is one part.
    static let first = "I've taken the liberty of silencing your notifications until the meeting ends, sir."
    static let second = "Shall I also alert the fire brigade?"

    @Test func theHelperIsLaunchedWithTheSpeedAsItIsAtThatLaunch() {
        let speed = Setting(1.15)
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                     assets: URL(fileURLWithPath: "/tmp"), outDirectory: URL(fileURLWithPath: "/tmp"),
                                     log: nil, speed: { speed.current })
        func argument(_ args: [String]) -> String? {
            args.firstIndex(of: "--speed").map { args[$0 + 1] }
        }
        #expect(argument(setup.arguments) == "1.15")
        speed.set(1.3)
        #expect(setup.speed == 1.3)
        #expect(argument(setup.arguments) == "1.3", "the next launch gets the new speed")
        // A fixed speed stays fixed, as before.
        let fixed = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                     assets: URL(fileURLWithPath: "/tmp"), outDirectory: URL(fileURLWithPath: "/tmp"),
                                     log: nil)
        #expect(argument(fixed.arguments) == String(VoiceHelperSetup.defaultSpeed))
    }

    @Test func eachReplyIsTimedAtTheSpeedReadForIt() async {
        #expect(SpeechQueue.chunks(Self.first + " " + Self.second, limit: 160) == [Self.first, Self.second])
        #expect(SpeechQueue.chunks(Self.first + " " + Self.second, limit: 160,
                                   timing: SpeechQueue.f5Timing.at(speed: 1.4)) == [Self.first + " " + Self.second])
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let speed = Setting(1.0)
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: FakePlayer(),
                                 chunkChars: { 160 }, timing: SpeechQueue.f5Timing, speed: { speed.current },
                                 log: { _ in })
        await speech.say(Self.first + " " + Self.second, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.first, Self.second])
        speed.set(1.4)
        await speech.say(Self.first + " " + Self.second, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.first, Self.second, Self.first + " " + Self.second])
    }

    @Test func aNewSpeedReleasesTheVoiceOnceSoItStartsAgainAtIt() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let speed = Setting(1.15)
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: FakePlayer(),
                                 chunkChars: { 160 }, speed: { speed.current }, log: { _ in })
        await speech.say("Good evening, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 0, "the first reply starts the voice at the speed it reads")
        await speech.say("Still here, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 0, "the same speed keeps the running voice")
        speed.set(1.3)
        await speech.say("Faster now, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 1)
        await speech.say("And again, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.releases == 1)
        #expect(await f5.asked.count == 4)
    }

    @Test func withoutASpeedTheQueueKeepsItsTimingAndNeverReleases() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: FakePlayer(),
                                 chunkChars: { 160 }, log: { _ in })
        await speech.say(Self.first + " " + Self.second, turn: UUID())
        await speech.idle()
        await speech.say("Once more.", turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.first, Self.second, "Once more."])
        #expect(await f5.releases == 0)
    }

    @Test func theChunkLimitIsReadForEachReply() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let limit = Setting(160)
        let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: FakePlayer(),
                                 chunkChars: { limit.current }, timing: SpeechQueue.f5Timing.at(speed: 1.4),
                                 log: { _ in })
        let reply = "One two three. Four five six."
        await speech.say(reply, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [reply])
        limit.set(20)
        await speech.say(reply, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [reply, "One two three.", "Four five six."])
    }
}
