import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// The V8 probe, with JARVIS_QWEN_EARLY=1: the real jarvis-voice-qwen helper through QwenEngine,
/// SpeechQueue and the real EnginePlayer rendering offline in step with the wall clock (as the V7
/// speed probe), with a simulated brain that takes `brainSeconds` to write a three-sentence reply.
/// The reply is spoken twice: the old way (the reply whole once the brain has finished) and as it
/// is written (Speak First Sentence Early: `SpeechQueue.begin`, a sentence at a time). Each run
/// prints the first audio after the send and writes what was played to <dir>/<run>.wav (24 kHz).
/// Nothing reaches a device.
///
/// JARVIS_QWEN_HELPER, JARVIS_VOICE_ASSETS as QwenLiveTests.
/// JARVIS_QWEN_EARLY_WAV_DIR  where the files go (default: jarvis-qwen-early-probe in the temporary folder)
/// JARVIS_QWEN_EARLY_BRAIN_S  how long the brain takes to write the reply (default 6)
@Suite("Qwen speak-early probe (JARVIS_QWEN_EARLY=1)")
struct QwenSpeakEarlyProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_QWEN_EARLY"] == "1"

    static let reply = "The meeting with the design team is at three o'clock on Friday, in the large room. "
        + "Dr. Patel asked for the quarterly figures, which came to 3.5 million, to be printed beforehand. "
        + "I shall remind you an hour before it starts, sir."

    /// The brain: the reply's words, spread evenly over `seconds`, each handed to `chunk`.
    static func write(seconds: Double, _ chunk: (String) async -> Void) async {
        let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let gap = Duration.seconds(seconds / Double(words.count))
        for (n, word) in words.enumerated() {
            try? await Task.sleep(for: gap)
            await chunk(n == words.count - 1 ? word : word + " ")
        }
    }

    /// Stretches of 10 ms windows whose peak is under -40 dBFS, 100 ms or longer, between the
    /// first sound and the last: the pauses a listener hears.
    static func quiet(_ samples: [Float], below level: Float = 0.01, windows minimum: Int = 10) -> [(ms: Int, at: Double)] {
        let window = Int(EnginePlayer.sampleRate / 100)
        let loud = stride(from: 0, to: samples.count, by: window).map { start in
            samples[start ..< min(start + window, samples.count)].contains { abs($0) >= level }
        }
        guard let first = loud.firstIndex(of: true) else { return [] }
        var out: [(Int, Double)] = []
        var run = 0
        for (n, isLoud) in loud.enumerated() where n > first {
            if isLoud {
                if run >= minimum { out.append((run * 10, Double(n - run) / 100)) }
                run = 0
            } else {
                run += 1
            }
        }
        return out
    }

    @Test(.enabled(if: QwenSpeakEarlyProbeTests.enabled, "set JARVIS_QWEN_EARLY=1 to run the real helper"))
    func firstAudioWithAndWithoutSpeakEarly() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let setup = QwenHelperSetup(
            executable: Self.environment["JARVIS_QWEN_HELPER"].map { URL(fileURLWithPath: $0) } ?? QwenLiveTests.defaultHelper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url, log: logs.url.appending(path: "jarvis-voice-qwen.log"))
        try #require(setup.isInstalled())
        let brainSeconds = Double(Self.environment["JARVIS_QWEN_EARLY_BRAIN_S"] ?? "6") ?? 6
        let dir = Self.environment["JARVIS_QWEN_EARLY_WAV_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "jarvis-qwen-early-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let qwen = QwenEngine(launcher: setup)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: EnginePlayer.sampleRate, channels: 2))
        let engine = try EnginePlayer(offline: output)
        let player = TeePlayer(base: engine)
        let queue = SpeechQueue(engine: qwen, fallback: SayEngine(), player: player,
                                helperFootprintMB: { qwen.lastFootprintMB },
                                log: { print("early probe: \($0)") })
        await qwen.warm()

        var results: [(String, Double?, Double)] = []
        // "warm": a first reply, played and not measured, so both runs find the model loaded and
        // the player's gain set.
        for name in ["warm", "whole", "speak-early"] {
            let early = name == "speak-early"
            player.reset()
            let sent = ContinuousClock.now
            let firstSound = Mutex<ContinuousClock.Instant?>(nil)
            let played = Mutex<[Float]>([])
            // The play head, as the V7 probe's: renders what is due by the wall clock.
            let head = Task {
                var rendered = 0
                var quiet = 0
                let start = ContinuousClock.now
                while !Task.isCancelled {
                    let due = Int((ContinuousClock.now - start) / .seconds(1) * EnginePlayer.sampleRate)
                    while rendered < due {
                        let frames = AVAudioFrameCount(min(Int(EnginePlayer.offlineFrames), due - rendered))
                        let next = try await engine.renderOffline(frames: frames)
                        if next.isEmpty { rendered = due; break }
                        played.withLock { $0 += next[0] }
                        rendered += next[0].count
                        if next[0].contains(where: { abs($0) >= 1e-7 }) {
                            firstSound.withLock { if $0 == nil { $0 = .now } }
                            quiet = 0
                        } else {
                            quiet += next[0].count
                        }
                    }
                    if player.ended, quiet > Int(EnginePlayer.sampleRate) {
                        await engine.stop()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let turn = UUID()
            if name == "warm" {
                await queue.say("Good evening, sir.", turn: turn)
            } else if early {
                var sentences = EarlySentencesForProbe()
                await queue.begin(turn: turn, sentAt: sent)
                await Self.write(seconds: brainSeconds) { chunk in
                    for s in sentences.push(chunk) { await queue.sentence(s, turn: turn) }
                }
                for s in sentences.finish() { await queue.sentence(s, turn: turn) }
                await queue.end(turn: turn)
            } else {
                var text = ""
                await Self.write(seconds: brainSeconds) { text += $0 }
                await queue.say(text, turn: turn)
            }
            await queue.idle()
            head.cancel()
            _ = try? await head.value
            var heard = played.withLock { $0 }
            if let last = heard.lastIndex(where: { abs($0) >= 1e-7 }) { heard.removeSubrange((last + 1)...) }
            let first = firstSound.withLock { $0 }.map { ($0 - sent) / .seconds(1) }
            if name == "warm" { continue }
            let file = dir.appending(path: "\(name).wav")
            try VoiceLiveTests.writeWAV(heard, to: file)
            print("early probe: \(name): first audio \(first.map { String(format: "%.2f s", $0) } ?? "none") after the send "
                  + String(format: "(brain %.1f s); %.2f s rendered to %@", brainSeconds,
                           Double(heard.count) / EnginePlayer.sampleRate, file.path(percentEncoded: false)))
            print("early probe: \(name): quiet stretches of 100 ms or more after the first sound (ms, at s): "
                  + Self.quiet(heard).map { String(format: "%d@%.2f", $0.ms, $0.at) }.joined(separator: " "))
            let soft = Self.quiet(heard, below: 0.0018, windows: 6)
            print("early probe: \(name): under -55 dBFS for 60 ms or more: "
                  + soft.map { String(format: "%d@%.2f", $0.ms, $0.at) }.joined(separator: " ")
                  + "; total \(soft.reduce(0) { $0 + $1.ms }) ms; delivered "
                  + String(format: "%.2f s", Double(player.pieces.reduce(0) { $0 + $1.samples.count }) / EnginePlayer.sampleRate))
            results.append((name, first, Double(heard.count) / EnginePlayer.sampleRate))
        }
        await qwen.release()
        let whole = try #require(results[0].1)
        let early = try #require(results[1].1)
        print(String(format: "early probe: first audio %.2f s whole, %.2f s speak-early (%.2f s sooner)", whole, early,
                     whole - early))
        #expect(early < whole)
    }
}

/// The app splits with `EarlySentences` (JarvisBrain), which JarvisVoiceTests cannot import; the
/// probe splits at a terminator followed by whitespace, outside the reply's known abbreviation,
/// which gives the same three sentences for its fixed reply.
struct EarlySentencesForProbe {
    private var buf = ""

    mutating func push(_ text: String) -> [String] {
        buf += text
        var out: [String] = []
        while let end = Self.end(in: buf) {
            out.append(String(buf[..<end]).trimmingCharacters(in: .whitespaces))
            buf = String(buf[end...])
        }
        return out
    }

    mutating func finish() -> [String] {
        let rest = buf.trimmingCharacters(in: .whitespaces)
        buf = ""
        return rest.isEmpty ? [] : [rest]
    }

    private static func end(in s: String) -> String.Index? {
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            if ".!?".contains(s[i]), next < s.endIndex, s[next] == " ", !s[..<next].hasSuffix("Dr.") { return next }
            i = next
        }
        return nil
    }
}
