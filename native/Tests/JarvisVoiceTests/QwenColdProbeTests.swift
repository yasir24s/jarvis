import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// The V9 probe, with JARVIS_QWEN_COLD=1: the real jarvis-voice-qwen helper through QwenEngine,
/// SpeechQueue and the real EnginePlayer rendering offline in step with the wall clock (as the V8
/// probe). The helper loads and speaks one line, then sits idle `JARVIS_QWEN_COLD_IDLE_S` (default
/// 180); then a simulated brain takes `JARVIS_QWEN_COLD_BRAIN_S` (default 4) and the reply is
/// spoken. Twice: without the turn-start warm-up, then with it (`QwenEngine.warmUp` at the send).
/// Each run prints its first audio after the send, the pre-roll and the underruns, and writes what
/// was played to <dir>/<run>.wav. Nothing reaches a device.
@Suite("Qwen cold-start probe (JARVIS_QWEN_COLD=1)")
struct QwenColdProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_QWEN_COLD"] == "1"

    @Test(.enabled(if: QwenColdProbeTests.enabled, "set JARVIS_QWEN_COLD=1 to run the real helper"))
    func firstReplyAfterIdleWithAndWithoutTheWarmUp() async throws {
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
        let idleSeconds = Double(Self.environment["JARVIS_QWEN_COLD_IDLE_S"] ?? "180") ?? 180
        let brainSeconds = Double(Self.environment["JARVIS_QWEN_COLD_BRAIN_S"] ?? "4") ?? 4
        let dir = Self.environment["JARVIS_QWEN_COLD_WAV_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "jarvis-qwen-cold-probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let qwen = QwenEngine(launcher: setup)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: EnginePlayer.sampleRate, channels: 2))
        let engine = try EnginePlayer(offline: output)
        let player = TeePlayer(base: engine)
        let lines = Mutex<[String]>([])
        let queue = SpeechQueue(engine: qwen, fallback: SayEngine(), player: player,
                                helperFootprintMB: { qwen.lastFootprintMB },
                                log: { line in print("cold probe: \(line)"); lines.withLock { $0.append(line) } })
        await qwen.warm()

        for name in ["load", "cold-no-warmup", "cold-warmup"] {
            if name != "load" {
                print("cold probe: \(name): idling \(Int(idleSeconds)) s")
                try await Task.sleep(for: .seconds(idleSeconds))
                print("cold probe: \(name): helper idle \(await qwen.idleSeconds().map { String(format: "%.0f s", $0) } ?? "n/a")")
            }
            player.reset()
            lines.withLock { $0 = [] }
            let sent = ContinuousClock.now
            let firstSound = Mutex<ContinuousClock.Instant?>(nil)
            let played = Mutex<[Float]>([])
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
            let warming: Task<(Bool, Double), Never>? = name == "cold-warmup" ? Task {
                let start = ContinuousClock.now
                let finished = await qwen.warmUp()
                return (finished, (ContinuousClock.now - start) / .seconds(1))
            } : nil
            if name == "load" {
                await queue.say("Good evening, sir.", turn: UUID())
            } else {
                try await Task.sleep(for: .seconds(brainSeconds))   // the brain writes the reply
                await queue.say(QwenSpeakEarlyProbeTests.reply, turn: UUID())
            }
            await queue.idle()
            head.cancel()
            _ = try? await head.value
            if name == "load" { continue }
            if let warming {
                let (finished, took) = await warming.value
                print(String(format: "cold probe: %@: warm-up %@ after %.2f s", name, finished ? "finished" : "cut short", took))
            }
            var heard = played.withLock { $0 }
            if let last = heard.lastIndex(where: { abs($0) >= 1e-7 }) { heard.removeSubrange((last + 1)...) }
            let first = firstSound.withLock { $0 }.map { ($0 - sent) / .seconds(1) }
            let file = dir.appending(path: "\(name).wav")
            try VoiceLiveTests.writeWAV(heard, to: file)
            let report = await player.lastStream()
            print("cold probe: \(name): first audio "
                  + (first.map { String(format: "%.2f s", $0) } ?? "none")
                  + String(format: " after the send (brain %.1f s, so %.2f s after the reply)", brainSeconds, (first ?? 0) - brainSeconds)
                  + "; pre-roll " + (report.map { String(format: "%.2f s", $0.preroll) } ?? "n/a")
                  + "; in-reply rate " + (report?.inReplyRate.map { String(format: "x%.2f", $0) } ?? "n/a")
                  + "; underruns \(report?.dry ?? -1), \(report?.dryMilliseconds ?? -1) ms"
                  + "; delivered " + (report?.deliveryRate.map { String(format: "x%.2f", $0) } ?? "n/a")
                  + "; " + file.path(percentEncoded: false))
        }
        await qwen.release()
    }
}
