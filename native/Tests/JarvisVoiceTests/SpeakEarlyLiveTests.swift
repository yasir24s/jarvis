import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// V5's measurement, with JARVIS_VOICE_LIVE=1: the real helper through F5Engine and SpeechQueue
/// with the default voice, and a player that plays nothing. It waits out each part's length
/// instead, so the rest generates while the first part "plays" as it would aloud. For replies of
/// 99, 178 and 300 characters it prints the time to first audio with Speak First Sentence Early
/// off and on, and the pause between the parts: the rest's generation end minus (the first
/// part's play start plus its length). JARVIS_VOICE_LIVE_WAV_DIR, if set, gets every part as a
/// WAV. Skipped otherwise, so the default `swift test` never starts the helper.
@Suite("V5 speak early live (JARVIS_VOICE_LIVE=1)", .serialized)
struct SpeakEarlyLiveTests {
    static let replies = [
        "The afternoon looks dry and mild, sir. The rain should hold off until well after nine this evening.",
        "I have moved your dentist appointment to Thursday morning, sir. The receptionist confirmed it by mail, "
            + "and I added a reminder for the evening before so it doesn't slip your mind.",
        "Your inbox has three messages that need a reply today, sir. The first is from your supervisor about the "
            + "draft chapter, the second is a delivery notice for the parcel you ordered on Monday, and the third is "
            + "a reminder that your library books are due back at the end of the week, so plan for those too.",
    ]

    /// The first sentence, split as the app's `SentenceSplitter` splits this text (after `. `).
    static let sentences: @Sendable (String) -> [String] = SpeakEarlyTests.sentences

    /// Plays nothing: notes when each part was handed over and waits out its length.
    actor SilentPlayer: SpeechPlayer {
        private(set) var plays: [(start: ContinuousClock.Instant, seconds: Double, samples: [Float])] = []

        func play(_ chunk: PCMChunk) async throws {
            let seconds = Double(chunk.samples.count) / chunk.sampleRate
            plays.append((ContinuousClock.now, seconds, chunk.samples))
            try? await Task.sleep(for: .seconds(seconds))
        }

        func stop() {}
    }

    /// F5Engine, noting when each generation ended.
    actor TimedEngine: SpeechEngine {
        nonisolated let id: EngineID = .f5
        let inner: F5Engine
        let ends = Ends()

        final class Ends: Sendable {
            private let times = Mutex<[ContinuousClock.Instant]>([])
            var all: [ContinuousClock.Instant] { times.withLock { $0 } }
            func append(_ time: ContinuousClock.Instant) { times.withLock { $0.append(time) } }
            func reset() { times.withLock { $0 = [] } }
        }

        init(_ inner: F5Engine) { self.inner = inner }

        func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
            let inner = self.inner
            let ends = self.ends
            return AsyncThrowingStream { continuation in
                let task = Task {
                    do {
                        let chunk = try await SpeechQueue.collect(inner.synthesize(sentence, context: context))
                        ends.append(ContinuousClock.now)
                        continuation.yield(chunk)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }

        func release() async { await inner.release() }
        func warm() async { await inner.warm() }
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test(.enabled(if: VoiceLiveTests.enabled, "set JARVIS_VOICE_LIVE=1 to run the real helper"))
    func timeToFirstAudioAndThePause() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let env = VoiceLiveTests.environment
        let assets = env["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? VoiceHelperSetup.installedAssets
        let setup = VoiceHelperSetup(
            executable: env["JARVIS_VOICE_HELPER"].map { URL(fileURLWithPath: $0) } ?? VoiceLiveTests.defaultHelper,
            assets: assets, outDirectory: out.url, log: logs.url.appending(path: "jarvis-voice.log"),
            speed: { VoiceHelperSetup.defaultSpeed },
            reference: { VoiceHelperSetup.preferredReference }, steps: { 8 })   // the user's default: dry-short, 8 steps
        try #require(setup.isInstalled(), "helper \(setup.executable.path) or assets \(setup.assets.path) missing")
        print("V5 live: reference \(setup.reference), \(setup.steps) steps, speed \(setup.speed)")
        let f5 = F5Engine(launcher: setup)
        let engine = TimedEngine(f5)
        let early = Mutex(false)
        let lines = LogLines()
        func run(_ reply: String, on: Bool) async -> (first: Double, parts: [(start: ContinuousClock.Instant, seconds: Double, samples: [Float])],
                                                     ends: [ContinuousClock.Instant], said: ContinuousClock.Instant) {
            early.withLock { $0 = on }
            let player = SilentPlayer()
            let queue = SpeechQueue(engine: engine, fallback: SayEngine(), player: player,
                                    reference: { setup.reference }, tooLong: { f5.tooLong($0) },
                                    speakEarly: { early.withLock { $0 } }, sentences: Self.sentences,
                                    helperFootprintMB: { f5.lastFootprintMB },
                                    log: { line in
                                        lines.append(line)
                                        print("V5 live: \(line)")
                                    })
            engine.ends.reset()
            let said = ContinuousClock.now
            await queue.say(reply, turn: UUID())
            await queue.idle()
            let plays = await player.plays
            let first = plays.first.map { Self.seconds($0.start - said) } ?? .nan
            return (first, plays, engine.ends.all, said)
        }

        // Warm the model with one throwaway render, so every row meets a loaded helper.
        _ = await run("Good evening, sir.", on: false)
        var rows: [String] = []
        for reply in Self.replies {
            let off = await run(reply, on: false)
            let on = await run(reply, on: true)
            #expect(off.parts.count == 1 && on.parts.count == 2, "\(off.parts.count) / \(on.parts.count)")
            guard on.parts.count == 2, on.ends.count == 2 else { continue }
            let pause = Self.seconds(on.ends[1] - on.parts[0].start) - on.parts[0].seconds
            let gap = Self.seconds(on.parts[1].start - on.parts[0].start) - on.parts[0].seconds
            let row = String(format: "%3d chars | off: first audio %5.2f s (%.2f s audio) | on: first audio %5.2f s "
                             + "(part 1 %.2f s audio, part 2 %.2f s audio) | pause %+.2f s (observed gap %.2f s)",
                             reply.unicodeScalars.count, off.first, off.parts[0].seconds, on.first,
                             on.parts[0].seconds, on.parts[1].seconds, pause, gap)
            rows.append(row)
            if let dir = env["JARVIS_VOICE_LIVE_WAV_DIR"] {
                let n = reply.unicodeScalars.count
                try VoiceLiveTests.writeWAV(off.parts[0].samples, to: URL(fileURLWithPath: dir).appending(path: "v5-\(n)-off.wav"))
                for (index, part) in on.parts.enumerated() {
                    try VoiceLiveTests.writeWAV(part.samples,
                                                to: URL(fileURLWithPath: dir).appending(path: "v5-\(n)-on-part\(index + 1).wav"))
                }
            }
        }
        await f5.release()
        for row in rows { print("V5 live: \(row)") }
        #expect(!lines.all.contains { $0.contains("say speaks") || $0.contains("F5 failed") }, "the clone spoke every part")
        #expect(setup.reference == VoiceHelperSetup.preferredReference, "dry-short is installed")
    }
}
