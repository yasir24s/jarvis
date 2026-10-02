import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing
@testable import JarvisVoice

/// M11 part 5's measure, with `JARVIS_MEASURE=1`: the time from the end of "Hey Jarvis" to the
/// chime. The say clip is fed in real time, a frame every 80 ms as the microphone would give it,
/// through the real wake word and the real speaker check (a voiceprint enrolled from the same
/// synthetic voice); the chime's time is when the loop asks for it. Nothing is played.
@Suite("M11 wake-to-chime latency (JARVIS_MEASURE=1)", .serialized)
struct WakeLatencyTests {
    static let enabled = ProcessInfo.processInfo.environment["JARVIS_MEASURE"] == "1"

    final class Timed: ConversationHost {
        let chimed = Mutex<ContinuousClock.Instant?>(nil)
        /// Frames delivered when the chime was asked for.
        let deliveredAtChime = Mutex<Int?>(nil)
        let delivered: @Sendable () -> Int
        init(delivered: @escaping @Sendable () -> Int) { self.delivered = delivered }
        func show(_ state: LoopState) async {}
        func caption(_ text: String) async {}
        func say(_ text: String) async {}
        func chime(_ sound: ChimeSound) async {
            let count = delivered()
            chimed.withLock { if $0 == nil { $0 = .now } }
            deliveredAtChime.withLock { if $0 == nil { $0 = count } }
        }
        func handle(_ command: String) async {}
        func identifyMusic() async -> String? { nil }
        func setTone(_ descriptor: String) async {}
        func conversationEnded() async {}
        func bump(_ key: String) async {}
    }

    final class TimedSpeaker: SpeakerVerifying {
        let inner: Voiceprint
        let took = Mutex<Duration?>(nil)
        init(_ inner: Voiceprint) { self.inner = inner }
        func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool {
            let start = ContinuousClock.now
            let ok = await inner.speakerOK(clip, for: check)
            took.withLock { if $0 == nil { $0 = .now - start } }
            return ok
        }
        func matchesForBargeIn(_ clip: [Int16]) async -> Bool { await inner.matchesForBargeIn(clip) }
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    @Test(.enabled(if: WakeLatencyTests.enabled, "set JARVIS_MEASURE=1 to measure in real time"),
          arguments: ["wake_hey_daniel_200", "wake_hey_samantha_200", "wake_time_daniel_200"])
    func wakeToChime(_ clip: String) async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let print = Voiceprint(url: sb.root.appending(path: "voiceprint.npy"), encoder: try SpeakerCorpus.sharedEncoder(),
                               research: BumpRecorder(), log: { _ in })
        let takes = try ["daniel_enrol_1", "daniel_enrol_2", "daniel_enrol_3"].map { try SpeakerCorpus.samples($0) }
        _ = try await print.enroll(takes: takes)
        // Warm the encoder, as the app does after loading a voiceprint.
        _ = await print.speakerOK(takes[0], for: .wake)
        let pcm = try ListenInputs.floor(4 * 16_000) + WakeCorpus.clip(clip) + ListenInputs.floor(3 * 16_000)
        let frames = WakeCorpus.frames(pcm)
        // The end of "Hey Jarvis": the last frame of the clip's speech before "what's the time"
        // (or the end of speech), found as the last frame of the first loud run.
        let floorRMS = Double(MicFrame(samples: try ListenInputs.floor(16_000), index: 0).rms)
        let loud = frames.map { Double($0.rms) > floorRMS * 3 }
        let first = try #require(loud.firstIndex(of: true))
        var end = first
        while end + 1 < loud.count, loud[end + 1] || (end + 2 < loud.count && loud[end + 2]) { end += 1 }
        let arrived = Mutex<[ContinuousClock.Instant]>([])
        let host = Timed(delivered: { arrived.withLock { $0.count } })
        let speaker = TimedSpeaker(print)
        let watcher = WakeWatcher(settings: WakeSettings(), makeDetector: { try WakeModels.detector(WakeSeed()) })
        try await watcher.warm()
        let listener = SentenceListener(pause: 0.9, transcribe: { _ in "" })
        let loop = ConversationLoop(host: host, watcher: watcher, listener: listener, speaker: speaker,
                                    enrolment: nil, confirm: nil)
        let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
        let pacing = Task {
            var next = ContinuousClock.now
            for frame in frames {
                next = next + .milliseconds(80)
                try? await Task.sleep(until: next, clock: .continuous)
                arrived.withLock { $0.append(.now) }
                feed.yield(frame)
            }
            feed.finish()
        }
        await loop.run(FrameSource(stream), greet: false)
        await pacing.value
        let chimed = try #require(host.chimed.withLock { $0 }, "no chime")
        let times = arrived.withLock { $0 }
        let endArrived = try #require(times.indices.contains(end) ? times[end] : nil)
        // The fire: the last frame delivered when the chime was asked for.
        let fired = (host.deliveredAtChime.withLock { $0 } ?? 0) - 1
        let fireArrived = try #require(times.indices.contains(fired) ? times[fired] : nil)
        let check = speaker.took.withLock { $0 }.map { Self.ms($0) } ?? -1
        Swift.print("M11 latency \(clip): speech frames \(first)...\(end), the wake fired on frame \(fired) "
                    + "(\(fired - end) after the last frame of speech); chime "
                    + "\(String(format: "%.0f", Self.ms(chimed - endArrived))) ms after the last frame of speech "
                    + "arrived, \(String(format: "%.0f", Self.ms(chimed - fireArrived))) ms after the firing frame "
                    + "arrived (speaker check \(String(format: "%.0f", check)) ms)")
        #expect(Self.ms(chimed - fireArrived) < 3000)
    }
}
