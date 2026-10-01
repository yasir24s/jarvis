import Foundation
import Testing
@testable import JarvisVoice

@Suite("M8 SpeechQueue chunking")
struct SpeechChunkingTests {
    static let long = "Good evening, sir. The weather today is mild, with light rain expected after four. "
        + "Your first meeting starts at ten, and the second one has been moved to the afternoon. "
        + "I have also drafted the reply you asked for, and it is waiting in your outbox for review. "
        + "Shall I read it to you now?"

    @Test func aShortOneSentenceReplyIsOnePart() {
        #expect(SpeechQueue.chunks("Hello, sir.", limit: 160) == ["Hello, sir."])
        let exact = String(repeating: "a", count: 160)
        #expect(SpeechQueue.chunks(exact, limit: 160) == [exact])
        #expect(SpeechQueue.chunks("", limit: 160).isEmpty)
    }

    @Test func theFirstOfTwoOrMoreSentencesIsAPartOnItsOwn() {
        #expect(SpeechQueue.chunks("Good evening, sir. It's 3:45 PM.", limit: 160)
            == ["Good evening, sir.", "It's 3:45 PM."])
        #expect(SpeechQueue.chunks("Yes, sir. Done. Anything else?", limit: 160)
            == ["Yes, sir.", "Done. Anything else?"])
    }

    @Test func aLongReplyIsSplitAtSentenceEndsIntoPartsWithinTheLimit() {
        let parts = SpeechQueue.chunks(Self.long, limit: 160)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.unicodeScalars.count <= 160 })
        #expect(parts.joined(separator: " ") == Self.long)
        // Every part ends at a sentence end.
        #expect(parts.allSatisfy { $0.last.map { ".?!".contains($0) } ?? false })
        #expect(parts == [
            "Good evening, sir.",
            "The weather today is mild, with light rain expected after four. Your first meeting starts at ten, and the second one has been moved to the afternoon.",
            "I have also drafted the reply you asked for, and it is waiting in your outbox for review. Shall I read it to you now?",
        ])
    }

    @Test func sentencesArePackedUpToTheLimit() {
        let parts = SpeechQueue.chunks("One. Two. Three. Four.", limit: 11)
        #expect(parts == ["One.", "Two. Three.", "Four."])
    }

    @Test func aSentenceLongerThanTheLimitIsCutAtItsLastSpace() {
        let parts = SpeechQueue.chunks("alpha beta gamma delta epsilon.", limit: 12)
        #expect(parts == ["alpha beta", "gamma delta", "epsilon."])
    }

    @Test func aWordLongerThanTheLimitIsCutAtTheLimit() {
        #expect(SpeechQueue.chunks("abcdefghij klm", limit: 4) == ["abcd", "efgh", "ij", "klm"])
    }

    @Test func punctuationWithoutASpaceIsNotASentenceEnd() {
        #expect(SpeechQueue.chunks("Version 2.5.1 is out! Update now.", limit: 24)
            == ["Version 2.5.1 is out!", "Update now."])
    }

    @Test func lengthsAreUnicodeScalars() {
        // "👍🏽" is two scalars: 4 + 1 + 2 = 7 fits a limit of 7.
        #expect(SpeechQueue.chunks("Ok. Yes. 👍🏽", limit: 7) == ["Ok.", "Yes. 👍🏽"])
        #expect(SpeechQueue.chunks("Ok. Yes. 👍🏽", limit: 6) == ["Ok.", "Yes.", "👍🏽"])
        // One sentence of 3 + 1 + 2 = 6 fits a limit of 6, not 5.
        #expect(SpeechQueue.chunks("Yes 👍🏽", limit: 6) == ["Yes 👍🏽"])
        #expect(SpeechQueue.chunks("Yes 👍🏽", limit: 5) == ["Yes", "👍🏽"])
    }

    @Test func theLimitComesFromTheDefaultsWith160AsTheDefault() throws {
        let name = "jarvis-voice-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SpeechQueue.chunkChars(in: defaults) == 160)
        defaults.set(80, forKey: SpeechQueue.chunkCharsKey)
        #expect(SpeechQueue.chunkChars(in: defaults) == 80)
        defaults.set(0, forKey: SpeechQueue.chunkCharsKey)
        #expect(SpeechQueue.chunkChars(in: defaults) == 160)
        defaults.set(-5, forKey: SpeechQueue.chunkCharsKey)
        #expect(SpeechQueue.chunkChars(in: defaults) == 160)
        #expect(SpeechQueue.chunkChars(in: nil) == 160)
        #expect(SpeechQueue.defaultsSuite == "com.jarvis.assistant")
        #expect(SpeechQueue.chunkCharsKey == "voiceChunkChars")
    }

    @Test func theLogLineHasThePlansShape() {
        let line = SpeechQueue.summary(characters: 42, parts: 2, firstAudio: .milliseconds(11_240),
                                       generating: .milliseconds(20_960), helperMB: 1050, sayParts: 0, stopped: false)
        #expect(line == "voice: 42 chars in 2 part(s); first audio after 11.2 s; generated in 21.0 s; helper 1050 MB")
        let fallback = SpeechQueue.summary(characters: 5, parts: 1, firstAudio: nil, generating: .zero,
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

    private func queue(_ engine: FakeEngine, _ fallback: FakeEngine, _ player: FakePlayer, _ log: LogLines,
                       limit: Int = 160) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: fallback, player: player, chunkChars: { limit },
                    helperFootprintMB: { 1050 }, log: { log.append($0) })
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

    @Test func theNextPartGeneratesWhileThisOnePlaysAndOnlyOneAhead() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log, limit: 10)
        await speech.say("One one. Two two. Three 3.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        // Part 1 plays; part 2 has been asked for, part 3 not yet.
        #expect(await eventually { await f5.asked.count == 2 })
        #expect(await f5.asked == ["One one.", "Two two."])
        await player.finish()
        // Part 2 plays (its wait is registered with its count) and part 3 is asked for.
        #expect(await eventually { await player.played.count == 2 })
        #expect(await eventually { await f5.asked.count == 3 })
        await player.finish()
        #expect(await eventually { await player.played.count == 3 })
        await player.finish()
        await speech.idle()
        #expect(await f5.asked == ["One one.", "Two two.", "Three 3."])
        #expect(log.all.last?.hasPrefix("voice: 26 chars in 3 part(s); first audio after ") == true)
    }

    @Test func theFirstSentencePlaysWhileTheRestGenerates() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log)
        await speech.say("Good evening, sir. The weather is mild, with rain after four.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        #expect(await player.played == [18])
        // The first sentence plays; the rest has been asked for.
        #expect(await eventually { await f5.asked.count == 2 })
        #expect(await f5.asked == ["Good evening, sir.", "The weather is mild, with rain after four."])
        await player.finish()
        #expect(await eventually { await player.played.count == 2 })
        await player.finish()
        await speech.idle()
        #expect(await player.played == [18, 42])
        #expect(log.all.last?.hasPrefix("voice: 61 chars in 2 part(s); first audio after ") == true, "\(log.all)")
    }

    @Test func aNewReplyCancelsWhatIsPlayingAndQueued() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log, limit: 10)
        await speech.say("One one. Two two. Three 3.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        await speech.say("New reply.", turn: UUID())
        #expect(await eventually { await player.played.count == 2 })
        await player.finish()
        await speech.idle()
        #expect(await player.played == [8, 10], "the old reply's later parts never played")
        #expect(await f5.asked.last == "New reply.")
        #expect(!(await f5.asked).contains("Three 3."))
        #expect(log.all.contains { $0.hasPrefix("voice: 26 chars in 3 part(s)") && $0.hasSuffix("; stopped") })
    }

    @Test func cancelAllStopsEverything() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, say, player, log, limit: 10)
        await speech.say("One one. Two two.", turn: turn)
        #expect(await eventually { await player.waiting == 1 })
        await speech.cancelAll()
        #expect(await player.played == [8])
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

    @Test func aPartF5FailsIsSpokenBySay() async {
        let f5 = FakeEngine(.f5) { text in
            if text.hasPrefix("Two") { throw SpeechEngineError(.error, "the voice helper stopped mid-request") }
            return try await Self.quick(text)
        }
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, say, player, log, limit: 10)
        await speech.say("One one. Two two.", turn: turn)
        await speech.idle()
        #expect(await say.asked == ["Two two."])
        #expect(await player.played == [8, 8])
        #expect(log.all.contains("voice: F5 failed (error: the voice helper stopped mid-request); say speaks instead"))
        #expect(log.all.last?.hasSuffix("; helper 1050 MB; say spoke 1 part(s)") == true)
    }
}

/// The queue over the real engines, with a fake helper, a fake `say` and a fake player.
@Suite("M8 SpeechQueue over F5Engine and SayEngine")
struct SpeechQueueEnginesTests {
    @Test func f5HearsDigitsInWordsAndSayHearsTheCleanText() async throws {
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
        let speech = SpeechQueue(engine: f5, fallback: say, player: player, chunkChars: { 160 },
                                 helperFootprintMB: { f5.lastFootprintMB }, log: { log.append($0) })
        await speech.say("It's **3:45** PM.", turn: UUID())
        await speech.idle()
        #expect(launcher.requests.map { $0["text"] } == ["It's three forty-five PM."])
        #expect(await player.played == [3])
        #expect(log.all.last?.hasSuffix("; helper 1050 MB") == true)

        launcher.setInstalled(false)
        await speech.say("It's **3:45** PM.", turn: UUID())
        await speech.idle()
        #expect(sayArguments.all == ["It's 3:45 PM."])
        #expect(log.all.contains { $0.hasPrefix("voice: F5 failed (disabled: ") })
        #expect(folder.files.isEmpty)
    }
}
