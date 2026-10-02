import Foundation
import Testing
@testable import JarvisVoice

/// V1 part 1: which acknowledgement a message gets, what of the reply is spoken after one, the
/// clips the install script renders, and the queue playing one before the reply.
@Suite("V1 acknowledgements")
struct AcknowledgementTests {
    /// SplitMix64, so a test can run the choice over many seeds and repeat any of them.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test func theTenLinesAreTheBriefsWithUniqueNames() {
        #expect(Acknowledgement.lines.map(\.text) == [
            "Right away, sir.", "One moment, sir.", "Certainly, sir.", "Of course, sir.", "On it, sir.",
            "Let me see, sir.", "Looking into it, sir.", "Give me a second, sir.", "Very good, sir.",
            "Working on it, sir.",
        ])
        #expect(Set(Acknowledgement.lines.map(\.name)).count == 10)
        let names = Set(Acknowledgement.lines.map(\.name))
        #expect(Set(Acknowledgement.forQuestions).isSubset(of: names))
        #expect(Set(Acknowledgement.forCommands).isSubset(of: names))
    }

    @Test func aQuestionEndsWithAQuestionMarkOrOpensWithAQuestionWord() {
        for question in ["What time is it", "is it raining", "  How's the weather today", "turn on the lights?",
                         "Can you check my calendar", "who is on the call"] {
            #expect(Acknowledgement.isQuestion(question), "\(question)")
        }
        for command in ["Open Safari", "turn on the lights", "Remind me at five", "set a timer for ten minutes",
                        "Whatsapp mum"] {
            #expect(!Acknowledgement.isQuestion(command), "\(command)")
        }
    }

    @Test func aQuestionAndACommandEachGetTheirOwnLines() {
        for seed in 0..<200 {
            var generator = Seeded(state: UInt64(seed))
            let asked = Acknowledgement.choose(for: "what's on today?", recent: [], using: &generator)
            #expect(["Let me see, sir.", "One moment, sir.", "Looking into it, sir."].contains(asked.text))
            let told = Acknowledgement.choose(for: "open Safari", recent: [], using: &generator)
            #expect(["Right away, sir.", "Certainly, sir.", "On it, sir."].contains(told.text))
        }
    }

    /// Over a long run of messages, no line is ever one of the three before it, and when all
    /// three preferred lines were the last three, another line is used.
    @Test func noneOfTheLastThreeIsEverRepeated() {
        let messages = ["what time is it", "open Safari", "why is it slow?", "play some music", "how far is it",
                        "is it late", "who called", "turn it off", "where am I", "what now"]
        for seed in 0..<50 {
            var generator = Seeded(state: UInt64(seed))
            var recent: [String] = []
            for i in 0..<120 {
                let line = Acknowledgement.choose(for: messages[i % messages.count], recent: recent, using: &generator)
                #expect(!recent.suffix(3).contains(line.name), "seed \(seed), message \(i): \(line.name) after \(recent)")
                recent.append(line.name)
            }
        }
        var generator = Seeded(state: 7)
        let line = Acknowledgement.choose(for: "what time is it",
                                          recent: ["let-me-see", "one-moment", "looking-into-it"], using: &generator)
        #expect(!Acknowledgement.forQuestions.contains(line.name))
        // Only the last three count: an older use may come back.
        let older = ["right-away", "let-me-see", "one-moment", "looking-into-it"]
        var back = Seeded(state: 1)
        for _ in 0..<50 {
            let chosen = Acknowledgement.choose(for: "what time is it", recent: older, using: &back)
            #expect(!older.suffix(3).contains(chosen.name))
        }
    }

    @Test func aShortAcknowledgementOpeningTheReplyIsNotSpokenTwice() {
        #expect(Acknowledgement.spokenText("Certainly, sir. The time is three o'clock.") == "The time is three o'clock.")
        #expect(Acknowledgement.spokenText("Of course, Sir. Here it is.") == "Here it is.")
        #expect(Acknowledgement.spokenText("Right away, sir.  Opening Safari now.") == "Opening Safari now.")
        // Four words is still short; five is not.
        #expect(Acknowledgement.spokenText("Very well then, sir. Done.") == "Done.")
        #expect(Acknowledgement.spokenText("Give me a second, sir. Done.") == "Give me a second, sir. Done.")
        // Only "sir." ends one.
        #expect(Acknowledgement.spokenText("Right away, sir! Done.") == "Right away, sir! Done.")
        #expect(Acknowledgement.spokenText("Good evening. Done.") == "Good evening. Done.")
        // A reply that is only the acknowledgement is spoken as it is.
        #expect(Acknowledgement.spokenText("Done, sir.") == "Done, sir.")
        #expect(Acknowledgement.spokenText("Done, sir. ") == "Done, sir. ")
        // A sentence end needs a space after it.
        #expect(Acknowledgement.spokenText("Version 2.5, sir.") == "Version 2.5, sir.")
    }

    // MARK: - The install script and the clips

    static var script: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "scripts/install-voice-assets.sh", directoryHint: .notDirectory)
    }

    /// The script renders exactly these lines under these names, at the app's speed and
    /// `renderSteps`.
    @Test func theInstallScriptRendersTheSameLinesWithTheAppsSettings() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let start = try #require(lines.firstIndex(of: "ACKNOWLEDGEMENTS=("))
        let end = try #require(lines[start...].firstIndex(of: ")"))
        let listed = lines[(start + 1)..<end].map { line -> Acknowledgement.Line in
            let entry = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let fields = entry.split(separator: "|", maxSplits: 1).map(String.init)
            return Acknowledgement.Line(fields[0], fields.count > 1 ? fields[1] : "")
        }
        #expect(listed == Acknowledgement.lines)
        #expect(lines.contains("ACK_STEPS=\(Acknowledgement.renderSteps)"))
        #expect(lines.contains("ACK_SPEED=\(VoiceHelperSetup.defaultSpeed)"))
        #expect(lines.contains("render_acknowledgements default \"$DEST/reference\""))
    }

    /// A 32-bit float WAV, as the helper's `--render` writes it.
    static func writeFloatWAV(_ samples: [Float], rate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 4
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(3)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 4)); append(UInt16(4)); append(UInt16(32))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url)
    }

    @Test func aRenderedClipIsReadExactlyAndOnlyAt24kHzMono() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let line = Acknowledgement.lines[4]
        let url = Acknowledgement.clipURL(line, assets: folder.url, reference: "default")
        #expect(url.path(percentEncoded: false).hasSuffix("/acknowledgements/default/on-it.wav"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let samples: [Float] = (0..<2400).map { Float(sin(Double($0) * 0.05)) * 1.2 }   // over 1: not clipped
        try Self.writeFloatWAV(samples, rate: 24_000, to: url)
        let clip = try Acknowledgement.loadClip(url)
        #expect(clip.sampleRate == 24_000)
        #expect(clip.samples == samples)
        let other = folder.url.appending(path: "48k.wav")
        try Self.writeFloatWAV(samples, rate: 48_000, to: other)
        #expect(throws: (any Error).self) { try Acknowledgement.loadClip(other) }
        #expect(throws: (any Error).self) { try Acknowledgement.loadClip(folder.url.appending(path: "missing.wav")) }
    }
}

/// The queue with an acknowledgement before the reply.
@Suite("V1 SpeechQueue acknowledgements (fake engines and player)")
struct SpeechQueueAcknowledgementTests {
    static func quick(_ text: String) async throws -> [Float] {
        [Float](repeating: 0.1, count: max(1, text.unicodeScalars.count))
    }

    static let clip = PCMChunk(samples: [Float](repeating: 0.2, count: 500), sampleRate: 24_000)

    private func queue(_ engine: FakeEngine, _ player: FakePlayer, _ log: LogLines) -> SpeechQueue {
        SpeechQueue(engine: engine, fallback: FakeEngine(.say, respond: Self.quick), player: player,
                    helperFootprintMB: { 1050 }, log: { log.append($0) })
    }

    @Test func theAcknowledgementPlaysAtOnceAndItsDelayIsLogged() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer()
        let log = LogLines()
        let speech = queue(f5, player, log)
        await speech.acknowledge(Self.clip, line: "On it, sir.", sentAt: .now)
        await speech.idle()
        #expect(await player.played == [500])
        #expect(await f5.asked.isEmpty, "a rendered clip needs no model")
        let line = log.all.last ?? ""
        let prefix = "voice: acknowledgement \"On it, sir.\" started ", suffix = " s after send"
        #expect(line.hasPrefix(prefix) && line.hasSuffix(suffix), "\(line)")
        let delay = Double(line.dropFirst(prefix.count).dropLast(suffix.count))
        #expect(delay != nil && delay! >= 0, "\(line)")
        print("V1 acknowledgement in the fake queue: \(line)")
    }

    /// The reply generates while the acknowledgement plays, is heard after it, and does not
    /// open with an acknowledgement of its own.
    @Test func theReplyGeneratesDuringTheAcknowledgementAndPlaysAfterIt() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, player, log)
        await speech.acknowledge(Self.clip, line: "Certainly, sir.", sentAt: .now)
        #expect(await eventually { await player.waiting == 1 })
        await speech.say("Certainly, sir. The time is three o'clock.", turn: UUID())
        #expect(await eventually { await f5.asked.count == 1 })
        #expect(await f5.asked == ["The time is three o'clock."])
        #expect(await player.played == [500], "the reply waits for the acknowledgement")
        await player.finish()
        #expect(await eventually { await player.played.count == 2 })
        #expect(await player.played == [500, 26])
        await player.finish()
        await speech.idle()
        // The next reply had no acknowledgement: it is spoken whole.
        let unacknowledged = FakePlayer()
        let plain = queue(f5, unacknowledged, log)
        await plain.say("Certainly, sir. The time is three o'clock.", turn: UUID())
        await plain.idle()
        #expect(await f5.asked.last == "Certainly, sir. The time is three o'clock.")
    }

    @Test func anAcknowledgementStopsTheReplyStillPlaying() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, player, log)
        await speech.say("A long answer to the last message.", turn: UUID())
        #expect(await eventually { await player.waiting == 1 })
        await speech.acknowledge(Self.clip, line: "On it, sir.", sentAt: .now)
        #expect(await eventually { await player.played.count == 2 })
        #expect(await player.played == [34, 500])
        await player.finish()
        await speech.idle()
        #expect(log.all.contains { $0.hasPrefix("voice: 34 chars in 1 part(s)") && $0.hasSuffix("; stopped") })
    }

    @Test func cancelAllStopsTheAcknowledgementAndTheReply() async {
        let f5 = FakeEngine(.f5, respond: Self.quick)
        let player = FakePlayer(hold: true)
        let log = LogLines()
        let speech = queue(f5, player, log)
        await speech.acknowledge(Self.clip, line: "On it, sir.", sentAt: .now)
        #expect(await eventually { await player.waiting == 1 })
        await speech.say("Done.", turn: UUID())
        #expect(await eventually { await f5.asked.count == 1 })
        await speech.cancelAll()
        await speech.idle()
        #expect(await player.played == [500], "the reply never played")
        #expect(await player.stops >= 1)
    }
}
