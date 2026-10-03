import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// V6's live check, with JARVIS_QWEN_LIVE=1: the real jarvis-voice-qwen helper through
/// QwenEngine and SpeechQueue, with a player that plays nothing. It keeps what EnginePlayer would
/// have played (the same LoudnessStream, at the same lift) and times it against a play head that
/// moves in real time, so it can tell when the stream fell behind (a gap) without a sound.
/// Skipped otherwise, so the default `swift test` never starts the helper or loads a model.
///
/// JARVIS_QWEN_HELPER     the helper (default: VoiceHelperQwen/.build/release/jarvis-voice-qwen)
/// JARVIS_VOICE_ASSETS    the assets, with qwen3/ and references/dry/ (default: the installed ones)
/// JARVIS_QWEN_LIVE_LINES a file of "<name>\t<text>" lines (default: one short line)
/// JARVIS_QWEN_LIVE_WAV_DIR  if set, each line as heard is written there as <name>.wav
/// JARVIS_QWEN_LIVE_MATCH a WAV; if set, each line is also written as <name>-matched.wav at that
///                        WAV's integrated loudness, for an A/B by ear against it
@Suite("V6 Qwen voice live (JARVIS_QWEN_LIVE=1)")
struct QwenLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_QWEN_LIVE"] == "1"

    static var defaultHelper: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "VoiceHelperQwen/.build/release/jarvis-voice-qwen", directoryHint: .notDirectory)
    }

    @Test(.enabled(if: QwenLiveTests.enabled, "set JARVIS_QWEN_LIVE=1 to run the real helper"))
    func theRealHelperStreamsEachLine() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let setup = QwenHelperSetup(
            executable: Self.environment["JARVIS_QWEN_HELPER"].map { URL(fileURLWithPath: $0) } ?? Self.defaultHelper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url, log: logs.url.appending(path: "jarvis-voice-qwen.log"))
        try #require(setup.isInstalled(), "helper \(setup.executable.path) or assets \(setup.assets.path) missing")
        var lines: [(String, String)] = [("short", "Good evening, sir.")]
        if let path = Self.environment["JARVIS_QWEN_LIVE_LINES"] {
            lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap {
                let fields = $0.split(separator: "\t", maxSplits: 1)
                return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
            }
        }
        let qwen = QwenEngine(launcher: setup)
        let player = TimingPlayer()
        let log = LogLines()
        let queue = SpeechQueue(engine: qwen, fallback: SayEngine(), player: player,
                                helperFootprintMB: { qwen.lastFootprintMB },
                                log: { line in
                                    log.append(line)
                                    print("V6 live: \(line)")
                                })
        await qwen.warm()
        // A warm-up reply, as the app's first reply after `warm` would be, not measured.
        await queue.say("Right away, sir.", turn: UUID())
        await queue.idle()
        for (name, text) in lines {
            await player.reset()
            let start = ContinuousClock.now
            await queue.say(text, turn: UUID())
            await queue.idle()
            let total = ContinuousClock.now - start
            let heard = await player.heard
            let report = await player.report(since: start)
            print("V6 live: \(name) (\(text.unicodeScalars.count) chars): \(report); queue done after \(total); "
                  + "helper \(qwen.lastFootprintMB.map { "\($0) MB" } ?? "n/a")")
            #expect(!heard.isEmpty, "\(name): no audio")
            if let dir = Self.environment["JARVIS_QWEN_LIVE_WAV_DIR"] {
                try VoiceLiveTests.writeWAV(heard, to: URL(fileURLWithPath: dir).appending(path: "\(name).wav"))
                if let match = Self.environment["JARVIS_QWEN_LIVE_MATCH"] {
                    let (matched, note) = try Self.matched(heard, to: URL(fileURLWithPath: match))
                    print("V6 live: \(name)-matched.wav: \(note)")
                    try VoiceLiveTests.writeWAV(matched, to: URL(fileURLWithPath: dir).appending(path: "\(name)-matched.wav"))
                }
            }
        }
        await qwen.release()
        if let text = try? String(contentsOf: setup.log!, encoding: .utf8) {
            print("V6 live: helper stderr:\n\(text)")
        }
        #expect(!log.all.contains { $0.contains("say speaks") }, "Qwen spoke every line")
        #expect(out.files.isEmpty, "every piece was read and deleted")
    }

    /// `samples` brought to the integrated loudness of the WAV at `url` (both read mono).
    static func matched(_ samples: [Float], to url: URL) throws -> ([Float], String) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let reference = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate
        let target = try #require(Loudness.integrated([reference], sampleRate: rate))
        let measured = try #require(Loudness.integrated([samples], sampleRate: EnginePlayer.sampleRate))
        let gain = Float(pow(10, (target - measured) / 20))
        let out = samples.map { $0 * gain }
        let peak = 20 * log10(Double(max(Loudness.samplePeak(out), 1e-9)))
        let note = String(format: "%.2f LUFS as heard, %.2f LUFS like %@ (gain %.2f dB), sample peak %.2f dBFS",
                          measured, target, url.lastPathComponent, target - measured, peak)
        return (out, note)
    }
}

/// Plays nothing. Keeps what EnginePlayer would play (the same LoudnessStream, prior and PreRoll)
/// and when each piece came, against a play head that starts with the first piece and moves in
/// real time.
actor TimingPlayer: SpeechPlayer {
    private(set) var heard: [Float] = []
    /// The pieces as they came, before any processing.
    private var raw: [Float] = []
    /// As EnginePlayer: the gain the last stream ended on.
    private var streamGain: Float?
    private var arrivals: [(at: ContinuousClock.Instant, samples: Int)] = []

    func reset() {
        heard = []
        raw = []
        arrivals = []
    }

    func play(_ chunk: PCMChunk) async throws {
        arrivals.append((ContinuousClock.now, chunk.samples.count))
        heard += Loudness.normalized(chunk.samples, sampleRate: chunk.sampleRate, lift: EnginePlayer.outputLiftDB)
    }

    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        let level = LoudnessStream(sampleRate: EnginePlayer.sampleRate, lift: EnginePlayer.outputLiftDB, prior: streamGain)
        defer { if let gain = level.gain { streamGain = gain } }
        var preroll = PreRoll(sampleRate: EnginePlayer.sampleRate)
        for try await piece in pieces {
            raw += piece.samples
            let ready = preroll.take(level.push(piece.samples))
            arrivals.append((ContinuousClock.now, ready.count))
            heard += ready
        }
        let rest = preroll.flush() + level.finish()
        arrivals.append((ContinuousClock.now, rest.count))
        heard += rest
    }

    func stop() {}

    /// The first audio, the audio's length, the time the last piece came, and the gaps: the
    /// silence a real-time play head would have met waiting for pieces.
    func report(since start: ContinuousClock.Instant) -> String {
        guard let first = arrivals.first(where: { $0.samples > 0 }) else { return "no audio" }
        var head = first.at   // when the audio queued so far runs out
        var gaps = Duration.zero
        var count = 0
        var at: [String] = []
        for arrival in arrivals where arrival.samples > 0 {
            if arrival.at > head {
                gaps += arrival.at - head
                count += 1
                at.append(String(format: "%.2f s for %.2f s", seconds(head - first.at), seconds(arrival.at - head)))
                head = arrival.at
            }
            head = head.advanced(by: .seconds(Double(arrival.samples) / EnginePlayer.sampleRate))
        }
        let audio = Double(heard.count) / EnginePlayer.sampleRate
        let lufs = Loudness.integrated([heard, heard], sampleRate: EnginePlayer.sampleRate) ?? -100
        let peak = 20 * log10(Double(max(Loudness.samplePeak(heard), 1e-9)))
        let whole = Loudness.normalized(raw, sampleRate: EnginePlayer.sampleRate, lift: EnginePlayer.outputLiftDB)
        let wholeLUFS = raw.isEmpty ? -100 : (Loudness.integrated([whole, whole], sampleRate: EnginePlayer.sampleRate) ?? -100)
        return String(format: "first audio %.2f s, %.2f s of audio, last piece at %.2f s, %d gap(s) totalling %.2f s, "
                      + "ends at %.2f s; %.1f LUFS on two channels (the whole-part chain: %.1f), peak %.2f dBFS; pieces %d; "
                      + "gaps at [%@]",
                      seconds(first.at - start), audio, seconds(arrivals.last!.at - start), count, seconds(gaps),
                      seconds(head - start), lufs, wholeLUFS, peak, arrivals.count, at.joined(separator: ", "))
    }

    private func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
