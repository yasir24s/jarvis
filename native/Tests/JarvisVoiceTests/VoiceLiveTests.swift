import Foundation
import Testing
@testable import JarvisVoice

/// The one live test: with JARVIS_VOICE_LIVE=1 it runs the real jarvis-voice helper on one line,
/// through the real VoiceHelperProcess and F5Engine. Skipped otherwise, so the default
/// `swift test` never starts the helper or loads a model.
///
/// JARVIS_VOICE_HELPER  the helper (default: VoiceHelper/.build/release/jarvis-voice)
/// JARVIS_VOICE_ASSETS  the assets (default: ~/Library/Application Support/JARVIS/voice)
/// JARVIS_VOICE_LIVE_WAV  if set, the audio is also written there as a WAV, to listen to or transcribe
@Suite("M8 voice live (JARVIS_VOICE_LIVE=1)")
struct VoiceLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_VOICE_LIVE"] == "1"
    static let line = "It's 3:45 PM."

    static var defaultHelper: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "VoiceHelper/.build/release/jarvis-voice", directoryHint: .notDirectory)
    }

    @Test(.enabled(if: VoiceLiveTests.enabled, "set JARVIS_VOICE_LIVE=1 to run the real helper"))
    func theRealHelperSpeaksOneLine() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let setup = VoiceHelperSetup(
            executable: Self.environment["JARVIS_VOICE_HELPER"].map { URL(fileURLWithPath: $0) } ?? Self.defaultHelper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url,
            log: logs.url.appending(path: "jarvis-voice.log"))
        try #require(setup.isInstalled(), "helper \(setup.executable.path) or assets \(setup.assets.path) missing")
        let f5 = F5Engine(launcher: setup)
        let clock = SuspendingClock()
        let start = clock.now
        let chunk = try await SpeechQueue.collect(f5.synthesize(Self.line, context: SynthesisContext(turnID: UUID())))
        let elapsed = clock.now - start
        await f5.release()
        let audio = Double(chunk.samples.count) / chunk.sampleRate
        print("voice live: \"\(Self.line)\" -> \(String(format: "%.2f", audio)) s of audio in \(elapsed); "
              + "helper \(f5.lastFootprintMB.map { "\($0) MB" } ?? "n/a")")
        if let log = try? String(contentsOf: setup.log!, encoding: .utf8) {
            print("voice live: helper stderr:\n\(log)")
        }
        #expect(chunk.sampleRate == 24_000)
        #expect(audio > 0.5, "spelled out, the line needs more than half a second")
        #expect(chunk.samples.contains { abs($0) > 0.05 }, "not silence")
        #expect(out.files.isEmpty, "the helper's PCM file was read and deleted")
        #expect(elapsed < F5Engine.defaultTimeout)
        if let wav = Self.environment["JARVIS_VOICE_LIVE_WAV"] {
            try Self.writeWAV(chunk.samples, to: URL(fileURLWithPath: wav))
        }
    }

    /// V1's end-to-end check, with JARVIS_VOICE_LIVE=1: the real helper through F5Engine and
    /// SpeechQueue, as AppVoice wires them, with a player that keeps what it is given instead of
    /// playing it aloud. The first keystroke warms the voice; four seconds later the message is
    /// sent and acknowledged with a rendered clip (from JARVIS_VOICE_ACKS, an assets folder with
    /// acknowledgements/default/, by default JARVIS_VOICE_ASSETS); the 153-character reply is
    /// ready 2.5 s after that. A second reply follows, for the footprint between replies.
    /// JARVIS_VOICE_LIVE_WAV_DIR, if set, gets the acknowledgement and the reply as heard.
    @Test(.enabled(if: VoiceLiveTests.enabled, "set JARVIS_VOICE_LIVE=1 to run the real helper"))
    func v1TypingThenSendThenReply() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let assets = Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VoiceHelperSetup.installedAssets
        let acks = Self.environment["JARVIS_VOICE_ACKS"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? assets
        let setup = VoiceHelperSetup(
            executable: Self.environment["JARVIS_VOICE_HELPER"].map { URL(fileURLWithPath: $0) } ?? Self.defaultHelper,
            assets: assets, outDirectory: out.url, log: logs.url.appending(path: "jarvis-voice.log"),
            speed: { VoiceHelperSetup.defaultSpeed })
        try #require(setup.isInstalled(), "helper \(setup.executable.path) or assets \(setup.assets.path) missing")
        let f5 = F5Engine(launcher: setup)
        let player = KeepingPlayer()
        let lines = LogLines()
        let queue = SpeechQueue(engine: f5, fallback: SayEngine(), player: player,
                                speed: { setup.speed }, reference: { setup.reference }, tooLong: { f5.tooLong($0) },
                                helperFootprintMB: { f5.lastFootprintMB },
                                log: { line in
                                    lines.append(line)
                                    print("V1 live: \(line)")
                                })
        let clock = ContinuousClock()
        let typing = clock.now
        await queue.warm()
        try await Task.sleep(for: .seconds(4))   // the user types
        let message = "What's the weather like this afternoon?"
        let line = Acknowledgement.choose(for: message, recent: [])
        let clip = try Acknowledgement.loadClip(Acknowledgement.clipURL(line, assets: acks, reference: "default"))
        let sent = clock.now
        await queue.acknowledge(clip, line: line.text, sentAt: sent)
        try await Task.sleep(for: .seconds(2.5))   // the turn
        let reply = "The afternoon looks dry and mild, sir, around seventeen degrees, with a light breeze from the "
            + "west and the rain holding off until well after six tonight."
        let ready = clock.now
        await queue.say(reply, turn: UUID())
        await queue.idle()
        let firstReply = f5.lastFootprintMB
        await queue.say("Shall I remind you to take an umbrella anyway, sir?", turn: UUID())
        await queue.idle()
        let secondReply = f5.lastFootprintMB
        let played = await player.played
        await f5.release()
        print("V1 live: typing began \(sent - typing) before the send")
        for (label, chunk, at) in played {
            print("V1 live: \(label) handed to the player \(at - sent) after the send, \(at - ready) after the reply "
                  + "was ready; \(String(format: "%.2f", Double(chunk.count) / 24_000)) s")
        }
        print("V1 live: helper footprint after reply 1 \(firstReply.map { "\($0) MB" } ?? "n/a"), "
              + "after reply 2 \(secondReply.map { "\($0) MB" } ?? "n/a")")
        if let log = try? String(contentsOf: setup.log!, encoding: .utf8) {
            print("V1 live: helper stderr:\n\(log)")
        }
        #expect(played.count == 3, "the acknowledgement and two replies")
        #expect(lines.all.contains { $0.hasPrefix("voice: acknowledgement \"\(line.text)\" started ") })
        #expect(lines.all.contains { $0.hasPrefix("voice: 153 chars in 1 part(s); first audio after ") })
        #expect(!lines.all.contains { $0.contains("say speaks") }, "the clone spoke both replies")
        if let dir = Self.environment["JARVIS_VOICE_LIVE_WAV_DIR"] {
            for (index, (label, chunk, _)) in played.enumerated() {
                try Self.writeWAV(chunk, to: URL(fileURLWithPath: dir).appending(path: "v1-live-\(index + 1)-\(label).wav"))
            }
        }
    }

    /// 16-bit PCM WAV at 24 kHz.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for s in samples { append(Int16((max(-1, min(1, s)) * 32767).rounded())) }
        try data.write(to: url)
    }
}

/// A player that keeps each part as EnginePlayer would play it (expander, gain, limiter), with
/// the moment it was handed over, and takes the part's length to "play" it, so a reply after an
/// acknowledgement waits as it would.
actor KeepingPlayer: SpeechPlayer {
    private(set) var played: [(String, [Float], ContinuousClock.Instant)] = []

    func play(_ chunk: PCMChunk) async throws {
        let at = ContinuousClock.now
        let heard = Loudness.normalized(chunk.samples, sampleRate: chunk.sampleRate, lift: EnginePlayer.outputLiftDB)
        played.append((played.isEmpty ? "acknowledgement" : "reply-\(played.count)", heard, at))
        try? await Task.sleep(for: .seconds(Double(chunk.samples.count) / chunk.sampleRate))
    }

    func stop() {}
}
