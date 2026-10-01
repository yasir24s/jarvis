import Foundation
import Testing
@testable import JarvisVoice

@Suite("M8 SpeechQueue chunking")
struct SpeechChunkingTests {
    static let long = "Good evening, sir. The weather today is mild, with light rain expected after four. "
        + "Your first meeting starts at ten, and the second one has been moved to the afternoon. "
        + "I have also drafted the reply you asked for, and it is waiting in your outbox for review. "
        + "Shall I read it to you now?"

    @Test func aShortReplyIsOnePart() {
        #expect(SpeechQueue.chunks("Hello, sir.", limit: 160) == ["Hello, sir."])
        let exact = String(repeating: "a", count: 160)
        #expect(SpeechQueue.chunks(exact, limit: 160) == [exact])
        #expect(SpeechQueue.chunks("", limit: 160).isEmpty)
        // Two sentences: 1.2 s of "Good evening, sir." would not cover 3.6 s of generating the rest.
        #expect(SpeechQueue.chunks("Good evening, sir. It's 3:45 PM.", limit: 160) == ["Good evening, sir. It's 3:45 PM."])
        let live = "Good evening, sir. I've taken the liberty of silencing your notifications until the meeting ends."
        #expect(SpeechQueue.chunks(live, limit: 160) == [live])
    }

    /// F5's timing: 83 characters play for 5.5 s, longer than the 4.9 s that 36 take to generate.
    @Test func aReplyIsSplitWhereThePartsAudioCoversTheNextPartsGeneration() {
        let first = "I've taken the liberty of silencing your notifications until the meeting ends, sir."
        let second = "Shall I also alert the fire brigade?"
        #expect(SpeechQueue.chunks(first + " " + second, limit: 160) == [first, second])
        #expect(SpeechQueue.f5Timing.gap(after: 83, before: 36) == 0)
        #expect(SpeechQueue.f5Timing.gap(after: 18, before: 79) > 6)
    }

    /// At speed 1.15 a character gets 1/1.15 of the frames: its audio and its share of the
    /// generation shrink, the reference's 2.83 s does not.
    @Test func theTimingFollowsTheSpeed() {
        let fast = SpeechQueue.f5Timing.at(speed: 1.15)
        #expect(abs(fast.audio(115) - SpeechQueue.f5Timing.audio(100)) < 1e-9)
        #expect(abs(fast.generation(115) - SpeechQueue.f5Timing.generation(100)) < 1e-9)
        #expect(fast.generation(0) == SpeechQueue.f5Timing.generation(0))
    }

    /// The first boundary that passes is used, so the voice starts as early as it can.
    @Test func theEarliestBoundaryWithNoGapIsUsed() {
        let instant = SpeechQueue.Timing(generationSeconds: 0, generationSecondsPerChar: 0, audioSecondsPerChar: 0.07)
        #expect(SpeechQueue.chunks("One. Two. Three.", limit: 160, timing: instant) == ["One.", "Two.", "Three."])
        let never = SpeechQueue.Timing(generationSeconds: 60, generationSecondsPerChar: 0, audioSecondsPerChar: 0.07)
        #expect(SpeechQueue.chunks("One. Two. Three.", limit: 160, timing: never) == ["One. Two. Three."])
        // Generating takes 1 s + 0.01 s a character. "Alpha beta." (11 characters, 0.77 s of audio)
        // cannot cover "Gamma delta epsilon." (1.2 s); the two together (32, 2.24 s) cover "Zeta."
        // (1.05 s).
        let some = SpeechQueue.Timing(generationSeconds: 1, generationSecondsPerChar: 0.01, audioSecondsPerChar: 0.07)
        #expect(SpeechQueue.chunks("Alpha beta. Gamma delta epsilon. Zeta.", limit: 160, timing: some)
            == ["Alpha beta. Gamma delta epsilon.", "Zeta."])
    }

    @Test func aLongReplyIsSplitAtSentenceEndsIntoPartsWithinTheLimit() {
        let parts = SpeechQueue.chunks(Self.long, limit: 160)
        #expect(parts.count > 1)
        #expect(parts.allSatisfy { $0.unicodeScalars.count <= 160 })
        #expect(parts.joined(separator: " ") == Self.long)
        // Every part ends at a sentence end.
        #expect(parts.allSatisfy { $0.last.map { ".?!".contains($0) } ?? false })
        // The last two sentences split: 89 characters play for 5.9 s, covering the 4.4 s that
        // the last 27 take to generate. No other boundary within the limit leaves no gap.
        #expect(parts == [
            "Good evening, sir. The weather today is mild, with light rain expected after four.",
            "Your first meeting starts at ten, and the second one has been moved to the afternoon.",
            "I have also drafted the reply you asked for, and it is waiting in your outbox for review.",
            "Shall I read it to you now?",
        ])
    }

    @Test func sentencesArePackedUpToTheLimit() {
        let parts = SpeechQueue.chunks("One. Two. Three. Four.", limit: 10)
        #expect(parts == ["One. Two.", "Three.", "Four."])
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
        #expect(SpeechQueue.chunks("Yes. 👍🏽", limit: 7) == ["Yes. 👍🏽"])
        #expect(SpeechQueue.chunks("Yes. 👍🏽", limit: 6) == ["Yes.", "👍🏽"])
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
        let split = SpeechQueue.summary(characters: 119, parts: 3, firstAudio: .milliseconds(7_700),
                                        generating: .milliseconds(12_040), helperMB: 1005, sayParts: 0, stopped: false,
                                        predictedGaps: [0, 2.26], actualGaps: [0.31])
        #expect(split == "voice: 119 chars in 3 part(s); first audio after 7.7 s; gaps predicted 0.0/2.3 s, "
                + "actual 0.3 s; generated in 12.0 s; helper 1005 MB")
    }
}

@Suite("M8 SpeechQueue (fake engines and player)")
struct SpeechQueueTests {
    let turn = UUID()

    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    private func queue(_ engine: FakeEngine, _ fallback: FakeEngine, _ player: FakePlayer, _ log: LogLines,
                       limit: Int = 160, timing: SpeechQueue.Timing = SpeechQueue.f5Timing) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: fallback, player: player, chunkChars: { limit }, timing: timing,
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

    /// With a voice fast enough that the first sentence covers the rest, the first sentence plays
    /// while the rest generates, and the log line gives the gap predicted and played.
    @Test func theFirstSentencePlaysWhileTheRestGenerates() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let say = FakeEngine(.say, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let fast = SpeechQueue.Timing(generationSeconds: 0, generationSecondsPerChar: 0.01, audioSecondsPerChar: 0.07)
        let speech = queue(f5, say, player, log, timing: fast)
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
        let line = log.all.last ?? ""
        #expect(line.hasPrefix("voice: 61 chars in 2 part(s); first audio after "), "\(line)")
        #expect(line.contains("; gaps predicted 0.0 s, actual "), "\(line)")
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
