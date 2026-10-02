#if DEBUG
import Foundation
import JarvisCore
import JarvisVoice
import Synchronization

/// `JARVIS --selftest-aec [<seconds>]` (plan M08-M13 §5 A13, M11 part 4): echo cancelling and
/// barge-in on this Mac's own speakers and microphone, run by the user at the screen. DEBUG builds
/// only. It plays a sentence of `say` (the V2 path: -11 LUFS, through the one AudioHub) twice while
/// recording: once with voice processing on, once with its input processing bypassed. It prints
/// one JSON line:
///
/// - `on_dbfs`, `bypassed_dbfs`: the microphone's level while he speaks; `attenuation_db` is the
///   difference (pass: at least 15 dB);
/// - `voiced_frames_on`: frames webrtcvad (mode 3) still calls speech with voice processing on;
/// - `barge_in_on`: whether the barge-in check would have stopped him (it must not), against the
///   enrolled voiceprint in the state root, when there is one.
///
/// It plays sound and opens the microphone: run it only when that is wanted. Nothing is kept.
enum AECSelfTest {
    static let flag = "--selftest-aec"
    static let sentence = "Good evening. This is a test of the echo cancelling: I am speaking through the speakers "
        + "while the microphone listens, and none of what I say should come back to me."

    static func run(arguments: [String]) -> Int32 {
        let result = Mutex<[String: any Sendable]>([:])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let report = await measure()
            result.withLock { $0 = report }
            done.signal()
        }
        done.wait()
        let report = result.withLock { $0 }
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return (report["ok"] as? Bool) == true ? 0 : 1
    }

    static func measure() async -> [String: any Sendable] {
        var report: [String: any Sendable] = [:]
        let hub = AudioHub(voiceProcessing: true, log: { FileHandle.standardError.write(Data("\($0)\n".utf8)) })
        let player = EnginePlayer(hub: hub)
        let assets = VendoredAssets.appBundle()
        var chunks: [PCMChunk] = []
        do {
            let say = SayEngine()
            for try await chunk in await say.synthesize(sentence, context: SynthesisContext(turnID: UUID())) {
                chunks.append(chunk)
            }
        } catch {
            report["error"] = "say: \(error)"
            report["ok"] = false
            return report
        }
        let mic = MicCapture(makeInput: { HubMicInput(hub: hub) })
        var levels: [String: Double] = [:]
        var voicedOn = 0
        var bargeInOn = false
        let vad = try? WebRTCVAD(library: WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad), mode: 3)
        let voiceprint = await enrolledVoiceprint(assets: assets)
        report["voiceprint"] = voiceprint == nil ? "none enrolled" : "enrolled"
        for bypassed in [false, true] {
            let frames = await mic.frames()
            do {
                try await mic.start()
            } catch {
                report["error"] = "microphone: \(error)"
                report["ok"] = false
                return report
            }
            hub.setVoiceProcessingBypassed(bypassed)
            try? await Task.sleep(for: .seconds(1))
            let collected = Task { await frames.reduce(into: [MicFrame]()) { $0.append($1) } }
            for chunk in chunks { try? await player.play(chunk) }
            await mic.stop()
            let heard = await collected.value
            let samples = heard.flatMap(\.samples)
            let ms = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, samples.count))
            levels[bypassed ? "bypassed" : "on"] = 10 * log10(max(ms, 1e-12) / (32768.0 * 32768.0))
            if !bypassed, let vad {
                voicedOn = heard.filter { frame in
                    stride(from: 0, through: frame.samples.count - 320, by: 320).contains {
                        (try? vad.isSpeech(frame.samples[$0..<$0 + 320])) ?? false
                    }
                }.count
                if let voiceprint {
                    let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
                    for f in heard { feed.yield(f) }
                    feed.finish()
                    let watcher = BargeInWatcher(makeVAD: {
                        try WebRTCVAD(library: try WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad), mode: 3)
                    }, speaker: voiceprint)
                    bargeInOn = await watcher.watch(stream)
                }
            }
        }
        let on = levels["on"] ?? 0, bypassed = levels["bypassed"] ?? 0
        report["on_dbfs"] = (on * 10).rounded() / 10
        report["bypassed_dbfs"] = (bypassed * 10).rounded() / 10
        report["attenuation_db"] = ((bypassed - on) * 10).rounded() / 10
        report["voiced_frames_on"] = voicedOn
        report["barge_in_on"] = bargeInOn
        report["ok"] = bypassed - on >= 15 && !bargeInOn
        return report
    }

    /// The state root's voiceprint, when one is enrolled; read only.
    static func enrolledVoiceprint(assets: VendoredAssets) async -> Voiceprint? {
        guard let paths = try? StatePaths.live() else { return nil }
        let voiceprint = Voiceprint(url: paths.voiceprint, encoder: SpeakerEncoder(assets: assets),
                                    research: NoResearch(), log: { _ in })
        await voiceprint.load()
        return await voiceprint.isEnrolled ? voiceprint : nil
    }

    private struct NoResearch: ResearchCounting {
        func bump(_ key: String, by n: Int) {}
    }
}
#endif
