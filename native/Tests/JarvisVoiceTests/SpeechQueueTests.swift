import Foundation
import Testing
@testable import JarvisVoice

@Suite("V1 SpeechQueue: every reply whole")
struct SpeechWholeReplyTests {
    static let long = "Good evening, sir. The weather today is mild, with light rain expected after four. "
        + "Your first meeting starts at ten, and the second one has been moved to the afternoon. "
        + "I have also drafted the reply you asked for, and it is waiting in your outbox for review. "
        + "Shall I read it to you now?"

    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    /// A two-sentence reply of the kind P5 split in two (166 characters), and one of four sentences:
    /// each is one request and one play.
    @Test func aReplyOfAnyLengthIsGeneratedWholeAndPlayedOnce() async {
        let split = "I've taken the liberty of silencing your notifications until the meeting ends, sir. "
            + "Shall I also alert the fire brigade, or would you rather handle that one yourself?"
        for reply in [split, Self.long] {
            let f5 = FakeEngine(.f5, respond: Self.quick)
            let player = FakePlayer()
            let log = LogLines()
            let speech = SpeechQueue(engine: f5, fallback: FakeEngine(.say, respond: Self.quick), player: player,
                                     helperFootprintMB: { 1050 }, log: { log.append($0) })
            await speech.say(reply, turn: UUID())
            await speech.idle()
            #expect(await f5.asked == [reply])
            #expect(await player.played == [reply.unicodeScalars.count])
            #expect(log.all.last?.hasPrefix("voice: \(reply.unicodeScalars.count) chars in 1 part(s); first audio after ") == true)
        }
    }

    /// A reply the voice cannot take in one generation is spoken by `say`; the voice is never asked.
    @Test func aReplyTooLongForTheVoiceIsSpokenBySayAndLogged() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let asked = LogLines()
        let speech = SpeechQueue(engine: f5, fallback: say, player: player,
                                 tooLong: { text in
                                     asked.append(text)
                                     return text.count > 100 ? "needs 4210 frames, F5 stops at 4096" : nil
                                 },
                                 helperFootprintMB: { 1050 }, log: { log.append($0) })
        await speech.say(Self.long, turn: UUID())
        await speech.idle()
        #expect(await f5.asked.isEmpty)
        #expect(await say.asked == [Self.long])
        #expect(await player.played == [Self.long.unicodeScalars.count])
        #expect(asked.all == [Self.long], "the check sees the cleaned reply")
        #expect(log.all.contains("voice: 286 chars do not fit the voice (needs 4210 frames, F5 stops at 4096); "
                                 + "say speaks the reply"))
        #expect(log.all.last?.hasSuffix("; helper n/a; say spoke 1 part(s)") == true, "\(log.all)")
        // A reply that fits still goes to the voice.
        await speech.say("Good evening, sir.", turn: UUID())
        await speech.idle()
        #expect(await f5.asked == ["Good evening, sir."])
    }

    @Test func theLogLineHasThePlansShape() {
        let line = SpeechQueue.summary(characters: 42, firstAudio: .milliseconds(11_240),
                                       generating: .milliseconds(20_960), helperMB: 1050, sayParts: 0, stopped: false)
        #expect(line == "voice: 42 chars in 1 part(s); first audio after 11.2 s; generated in 21.0 s; helper 1050 MB")
        let fallback = SpeechQueue.summary(characters: 5, firstAudio: nil, generating: .zero,
                                           helperMB: nil, sayParts: 1, stopped: true)
        #expect(fallback == "voice: 5 chars in 1 part(s); no audio; generated in 0.0 s; helper n/a; say spoke 1 part(s); stopped")
    }
}

@Suite("M8 SpeechQueue (fake engines and player)")
struct SpeechQueueTests {
    let turn = UUID()

    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    private func queue(_ engine: FakeEngine, _ fallback: FakeEngine, _ player: FakePlayer, _ log: LogLines) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: fallback, player: player, helperFootprintMB: { 1050 },
                    log: { log.append($0) })
    }

    @Test func aShortReplyIsCleanedGeneratedWholeAndPlayed() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("**Good** evening, _sir_.", turn: turn)
        await speech.idle()
        #expect(await f5.asked == ["Good evening, sir."])
        #expect(await say.asked.isEmpty)
        #expect(await player.played == [18])
        let line = log.all.last ?? ""
        #expect(line.hasPrefix("voice: 18 chars in 1 part(s); first audio after "), "\(line)")
        #expect(line.hasSuffix("; helper 1050 MB"), "\(line)")
    }

    @Test func aReplyThatCleansToNothingSpeaksNothing() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("** __ ##", turn: turn)
        await speech.idle()
        #expect(await f5.asked.isEmpty)
        #expect(await player.played.isEmpty)
    }

    @Test func aNewReplyCancelsWhatIsPlaying() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("One one. Two two. Three 3.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        await speech.say("New reply.", turn: UUID())
        #expect(await eventually { await player.played.count == 2 })
        await player.finish()
        await speech.idle()
        #expect(await player.played == [26, 10])
        #expect(await f5.asked == ["One one. Two two. Three 3.", "New reply."])
        #expect(log.all.contains { $0.hasPrefix("voice: 26 chars in 1 part(s)") && $0.hasSuffix("; stopped") })
    }

    @Test func cancelAllStopsEverything() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("One one. Two two.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        await speech.cancelAll()
        #expect(await player.played == [17])
        #expect(await player.stops >= 1)
        #expect(log.all.last?.hasSuffix("; stopped") == true)
    }

    @Test func cancellingDuringGenerationDoesNotFallBackToSay() async {
        let f5 = FakeEngine(.f5) { _ in
            try await Task.sleep(for: .seconds(30))
            return [0.1]
        }
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("Slow reply.", turn: turn)
        #expect(await eventually { await f5.asked.count == 1 })
        let start = SuspendingClock.now
        await speech.cancelAll()
        #expect(SuspendingClock.now - start < .seconds(5))
        #expect(await say.asked.isEmpty)
        #expect(await player.played.isEmpty)
    }

    @Test func aReplyF5FailsIsSpokenBySay() async {
        let f5 = FakeEngine(.f5) { _ in throw SpeechEngineError(.error, "the voice helper stopped mid-request") }
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("One one. Two two.", turn: turn)
        await speech.idle()
        #expect(await f5.asked == ["One one. Two two."])
        #expect(await say.asked == ["One one. Two two."])
        #expect(await player.played == [17])
        #expect(log.all.contains("voice: F5 failed (error: the voice helper stopped mid-request); say speaks instead"))
        #expect(log.all.last?.hasSuffix("; helper n/a; say spoke 1 part(s)") == true)
    }
}

/// The queue over the real engines, with a fake helper, a fake `say` and a fake player.
@Suite("M8 SpeechQueue over F5Engine and SayEngine")
struct SpeechQueueEnginesTests {
    @Test func everyVoiceHearsTheSpokenForm() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([0.2, 0.2, 0.2]) }
        let f5 = F5Engine(launcher: launcher, timeout: .seconds(5))
        let sayArguments = LogLines()
        let say = SayEngine(directory: folder.url, runner: { arguments in
            sayArguments.append(arguments.last ?? "")
            try SayEngineTests.writeSayAIFF(URL(fileURLWithPath: arguments[5]), frames: 2205)
        })
        let player = FakePlayer()
        let log = LogLines()
        let speech = SpeechQueue(engine: f5, fallback: say, player: player,
                                 helperFootprintMB: { f5.lastFootprintMB }, log: { log.append($0) })
        await speech.say("It's **3:45** PM.", turn: UUID())
        await speech.idle()
        #expect(launcher.requests.map { $0["text"] } == ["It's three forty-five p m."])
        #expect(await player.played == [3])
        #expect(log.all.last?.hasSuffix("; helper 1050 MB") == true)

        launcher.setInstalled(false)
        await speech.say("It's **3:45** PM.", turn: UUID())
        await speech.idle()
        #expect(sayArguments.all == ["It's three forty-five p m."])
        #expect(log.all.contains { $0.hasPrefix("voice: F5 failed (disabled: ") })
        #expect(folder.files.isEmpty)
    }
}
