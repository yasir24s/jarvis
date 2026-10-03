import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// V5: Speak First Sentence Early. With the setting on, a reply of two or more sentences whose
/// first has at least 20 characters is generated as the first sentence and then the whole rest,
/// the rest while the first plays; everything around the reply happens once.
@Suite("V5 SpeechQueue: speak the first sentence early")
struct SpeakEarlyTests {
    static let first = "I've taken the liberty of silencing your notifications, sir."
    static let rest = "Shall I also alert the fire brigade? Or would you rather handle that one yourself?"
    static let reply = first + " " + rest

    /// A stand-in for the app's `SentenceSplitter` (JarvisVoice cannot import JarvisBrain): split
    /// after `.`, `!` or `?` and whitespace. The app's own splitter is checked in JarvisAppTests.
    static let sentences: @Sendable (String) -> [String] = { text in
        var out: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character.isWhitespace, let previous, ".!?".contains(previous), !current.isEmpty {
                out.append(current)
                current = ""
            } else if !(current.isEmpty && character.isWhitespace) {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    static func samples(_ text: String) -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    /// What happened, in order: the engine's generations and the player's calls.
    final class Events: Sendable {
        private let lines = Mutex<[String]>([])
        var all: [String] { lines.withLock { $0 } }
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        func count(_ line: String) -> Int { all.filter { $0 == line }.count }
        func index(_ line: String) -> Int? { all.firstIndex(of: line) }
    }

    /// Records every call in `events`; each play waits for `finish()`, a stop or a cancellation.
    actor RecordingPlayer: SpeechPlayer {
        let events: Events
        private var waits: [PlaybackWait] = []

        init(_ events: Events) { self.events = events }

        func play(_ chunk: PCMChunk) async throws {
            events.append("play \(chunk.samples.count)")
            let wait = PlaybackWait()
            waits.append(wait)
            await withTaskCancellationHandler {
                await withCheckedContinuation { wait.set($0) }
            } onCancel: {
                wait.resume()
            }
            waits.removeAll { $0 === wait }
            events.append("played \(chunk.samples.count)")
        }

        func finish() {
            guard !waits.isEmpty else { return }
            waits.removeFirst().resume()
        }

        func stop() {
            events.append("stop")
            for wait in waits { wait.resume() }
            waits.removeAll()
        }

        func replyStarting() { events.append("replyStarting") }
        func replyReady() { events.append("replyReady") }
        func replyEnded() { events.append("replyEnded") }

        var waiting: Int { waits.count }
    }

    /// An engine response that logs each generation's start and end; the text `held` waits for
    /// `gate` (or a cancellation, logged too).
    static func respond(_ events: Events, held: String? = nil, gate: PlaybackWait? = nil)
        -> @Sendable (String) async throws -> [Float] {
        { text in
            events.append("generating \(text.unicodeScalars.count)")
            if text == held, let gate {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { gate.set($0) }
                } onCancel: {
                    gate.resume()
                }
                if Task.isCancelled {
                    events.append("cancelled \(text.unicodeScalars.count)")
                    throw CancellationError()
                }
            }
            events.append("generated \(text.unicodeScalars.count)")
            return samples(text)
        }
    }

    static func queue(engine: FakeEngine, fallback: FakeEngine? = nil, player: any SpeechPlayer,
                      early: @escaping @Sendable () -> Bool = { true },
                      tooLong: @escaping @Sendable (String) -> String? = { _ in nil },
                      log: LogLines = LogLines()) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: fallback ?? FakeEngine(.say, respond: { samples($0) }), player: player,
                    tooLong: tooLong, speakEarly: early, sentences: sentences,
                    helperFootprintMB: { 1050 }, log: { log.append($0) })
    }

    /// The first sentence is heard while the rest is still generating; the rest was asked for
    /// as soon as the first had generated, and plays the moment the first has finished.
    @Test func theFirstSentencePlaysWhileTheRestGenerates() async {
        let events = Events()
        let gate = PlaybackWait()
        let f5 = FakeEngine(.f5, respond: Self.respond(events, held: Self.rest, gate: gate))
        let player = RecordingPlayer(events)
        let log = LogLines()
        let speech = Self.queue(engine: f5, player: player, log: log)
        let one = Self.first.unicodeScalars.count
        let two = Self.rest.unicodeScalars.count

        await speech.say(Self.reply, turn: UUID())
        #expect(await eventually { await player.waiting == 1 && events.index("generating \(two)") != nil })
        // The first part is playing and the rest is generating, not yet done.
        let before = events.all
        #expect((before.firstIndex(of: "generated \(one)") ?? .max) < (before.firstIndex(of: "generating \(two)") ?? -1),
                "\(before)")
        #expect((before.firstIndex(of: "generated \(one)") ?? .max) < (before.firstIndex(of: "play \(one)") ?? -1))
        #expect(!before.contains("generated \(two)") && !before.contains("played \(one)"), "\(before)")

        gate.resume()
        #expect(await eventually { events.index("generated \(two)") != nil })
        await player.finish()
        #expect(await eventually { await player.waiting == 1 && events.index("play \(two)") != nil })
        await player.finish()
        await speech.idle()

        #expect(await f5.asked == [Self.first, Self.rest])
        let order = ["replyStarting", "generated \(one)", "replyReady", "play \(one)", "generated \(two)",
                     "played \(one)", "play \(two)", "played \(two)", "replyEnded"]
        let positions = order.compactMap { events.index($0) }
        #expect(positions.count == order.count && positions == positions.sorted(), "\(events.all)")
        #expect(log.all.last?.hasPrefix("voice: \(Self.reply.unicodeScalars.count) chars in 2 part(s); first audio after ") == true,
                "\(log.all)")
    }

    /// replyStarting, replyReady and replyEnded happen once for the reply, never per part, so
    /// the echo-cancelling engine does not switch between the parts.
    @Test func theReplyCallsHappenOncePerReply() async {
        let events = Events()
        let f5 = FakeEngine(.f5, respond: Self.respond(events))
        let player = RecordingPlayer(events)
        let speech = Self.queue(engine: f5, player: player)
        await speech.say(Self.reply, turn: UUID())
        for _ in 0..<2 {
            #expect(await eventually { await player.waiting == 1 })
            await player.finish()
        }
        await speech.idle()
        #expect(await f5.asked.count == 2)
        #expect(events.count("replyStarting") == 1)
        #expect(events.count("replyReady") == 1)
        #expect(events.count("replyEnded") == 1)
        #expect(events.all.filter { $0.hasPrefix("play ") }.count == 2)
    }

    /// With the setting off the reply is one request and one play, as before V5. The setting is
    /// read for each reply.
    @Test func withTheSettingOffTheReplyIsOneRequest() async {
        let events = Events()
        let on = Mutex(false)
        let f5 = FakeEngine(.f5, respond: Self.respond(events))
        let player = FakePlayer()
        let log = LogLines()
        let speech = Self.queue(engine: f5, player: player, early: { on.withLock { $0 } }, log: log)
        await speech.say(Self.reply, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.reply])
        #expect(await player.played == [Self.reply.unicodeScalars.count])
        #expect(log.all.last?.hasPrefix("voice: \(Self.reply.unicodeScalars.count) chars in 1 part(s); ") == true)

        on.withLock { $0 = true }
        await speech.say(Self.reply, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.reply, Self.first, Self.rest])
    }

    /// One sentence, or a first sentence under 20 characters, is one request with the setting on.
    @Test func oneSentenceOrAShortFirstSentenceIsOneRequest() async {
        let short = "Very good, sir. The meeting has been moved to three, and I have told the others."
        for reply in [Self.first, short] {
            let f5 = FakeEngine(.f5, respond: { Self.samples($0) })
            let player = FakePlayer()
            let speech = Self.queue(engine: f5, player: player)
            await speech.say(reply, turn: UUID())
            await speech.idle()
            #expect(await f5.asked == [reply])
            #expect(await player.played == [reply.unicodeScalars.count])
        }
    }

    @Test func thePartsRule() {
        #expect(SpeechQueue.parts(Self.reply, early: true, sentences: Self.sentences) == [Self.first, Self.rest])
        #expect(SpeechQueue.parts(Self.reply, early: false, sentences: Self.sentences) == [Self.reply])
        #expect(SpeechQueue.parts(Self.first, early: true, sentences: Self.sentences) == [Self.first])
        // Exactly 20 characters is enough; 19 is not.
        let twenty = "Twelve and eight ok."   // 20
        #expect(twenty.unicodeScalars.count == 20)
        #expect(SpeechQueue.parts(twenty + " Then more. And more.", early: true, sentences: Self.sentences)
                == [twenty, "Then more. And more."])
        #expect(SpeechQueue.parts("Twelve and eight o. Then more.", early: true, sentences: Self.sentences)
                == ["Twelve and eight o. Then more."])
        // Never more than two parts.
        #expect(SpeechQueue.parts(Self.reply + " One more. And one more!", early: true, sentences: Self.sentences).count == 2)
    }

    /// Stop while the first part plays: the rest's generation is cancelled and never played, and
    /// the reply ends once.
    @Test func stopDuringTheFirstPartCancelsTheRest() async {
        let events = Events()
        let gate = PlaybackWait()
        let f5 = FakeEngine(.f5, respond: Self.respond(events, held: Self.rest, gate: gate))
        let player = RecordingPlayer(events)
        let log = LogLines()
        let speech = Self.queue(engine: f5, player: player, log: log)
        let two = Self.rest.unicodeScalars.count
        await speech.say(Self.reply, turn: UUID())
        #expect(await eventually { await player.waiting == 1 && events.index("generating \(two)") != nil })
        await speech.cancelAll()
        await speech.idle()
        #expect(events.index("cancelled \(two)") != nil, "\(events.all)")
        #expect(events.index("generated \(two)") == nil)
        #expect(events.all.filter { $0.hasPrefix("play ") }.count == 1)
        #expect(events.count("replyEnded") == 1)
        #expect(log.all.last?.hasSuffix("; stopped") == true, "\(log.all)")
    }

    /// The 4096-frame check is made for each part: a part too long for the voice is spoken by
    /// `say`, the other by the voice. A part the voice fails falls back in the same way.
    @Test func saySpeaksOnePartTheVoiceCannot() async {
        let f5 = FakeEngine(.f5, respond: { Self.samples($0) })
        let say = FakeEngine(.say, respond: { Self.samples($0) })
        let player = FakePlayer()
        let log = LogLines()
        let speech = Self.queue(engine: f5, fallback: say, player: player,
                                tooLong: { $0 == Self.rest ? "needs 4210 frames, F5 stops at 4096" : nil }, log: log)
        await speech.say(Self.reply, turn: UUID())
        await speech.idle()
        #expect(await f5.asked == [Self.first])
        #expect(await say.asked == [Self.rest])
        #expect(await player.played == [Self.first.unicodeScalars.count, Self.rest.unicodeScalars.count])
        #expect(log.all.contains("voice: \(Self.rest.unicodeScalars.count) chars do not fit the voice "
                                 + "(needs 4210 frames, F5 stops at 4096); say speaks that part"), "\(log.all)")
        #expect(log.all.last?.hasSuffix("; helper 1050 MB; say spoke 1 part(s)") == true, "\(log.all)")

        struct Broken: Error {}
        let failing = FakeEngine(.f5, respond: { text in
            if text == Self.first { throw Broken() }
            return Self.samples(text)
        })
        let say2 = FakeEngine(.say, respond: { Self.samples($0) })
        let player2 = FakePlayer()
        let speech2 = Self.queue(engine: failing, fallback: say2, player: player2)
        await speech2.say(Self.reply, turn: UUID())
        await speech2.idle()
        #expect(await failing.asked == [Self.first, Self.rest])
        #expect(await say2.asked == [Self.first])
        #expect(await player2.played == [Self.first.unicodeScalars.count, Self.rest.unicodeScalars.count])
    }

    /// The setting is off until it is switched on.
    @Test func theSettingIsOffByDefault() throws {
        let name = "speak-early-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!SpeechQueue.speakEarly(in: defaults))
        defaults.set(false, forKey: SpeechQueue.speakEarlyKey)
        #expect(!SpeechQueue.speakEarly(in: defaults))
        defaults.set(true, forKey: SpeechQueue.speakEarlyKey)
        #expect(SpeechQueue.speakEarly(in: defaults))
    }
}
