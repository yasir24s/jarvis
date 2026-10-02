import AVFAudio
import Foundation
import JarvisCore
import Synchronization
import Testing
@testable import JarvisVoice

/// M11 part 3: the loop with the real wake word and the real endpointing on a say clip ("Hey
/// Jarvis, what's the time") in a quiet room, the transcriber scripted. No microphone: the frames
/// come from the corpus.
@Suite("M11 hands-free, end to end on the corpus", .serialized)
struct HandsFreeIntegrationTests {
    /// The whole input: a quiet room for the microphone check and the calibration, the clip, then
    /// 32 s of the room so the conversation times out.
    static func input() throws -> [MicFrame] {
        let room = try ListenInputs.floor(4 * 16_000)
        let clip = try ListenInputs.read("wake", "wake_time_daniel_200")
        let after = try ListenInputs.floor(32 * 16_000)
        return WakeCorpus.frames(room + clip + after)
    }

    static func source(_ frames: [MicFrame]) -> FrameSource {
        let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
        for f in frames { feed.yield(f) }
        feed.finish()
        return FrameSource(stream)
    }

    final class Transcripts: Sendable {
        private let texts: Mutex<[String]>
        init(_ texts: [String]) { self.texts = Mutex(texts) }
        func transcribe(_ frames: AsyncStream<MicFrame>) async -> String {
            for await _ in frames {}
            if Task.isCancelled { return "" }
            return texts.withLock { $0.isEmpty ? "" : $0.removeFirst() }
        }
    }

    @Test("\"Hey Jarvis, what's the time\": Tink, the command as a turn, then the conversation times out")
    func heyJarvis() async throws {
        let host = ConversationLoopTests.Host()
        let script = Transcripts(["What's the time?"])
        let watcher = WakeWatcher(settings: WakeSettings(), makeDetector: { try WakeModels.detector(WakeSeed()) })
        let listener = SentenceListener(pause: 0.9, transcribe: { await script.transcribe($0) })
        let loop = ConversationLoop(host: host, watcher: watcher, listener: listener,
                                    speaker: ConversationLoopTests.Speaker(), enrolment: nil, confirm: nil)
        await loop.run(Self.source(try Self.input()), greet: false)
        #expect(host.all == ["show idle", "chime Tink", "show listening", "tone", "handle what's the time?",
                             "show listening", "show idle", "caption ", "ended"])
    }

    @Test("a foreign voice saying it is ignored, and nothing else happens")
    func foreign() async throws {
        let host = ConversationLoopTests.Host()
        let watcher = WakeWatcher(settings: WakeSettings(), makeDetector: { try WakeModels.detector(WakeSeed()) })
        let listener = SentenceListener(pause: 0.9, transcribe: { _ in "what's the time" })
        let refusing = Refusing()
        let loop = ConversationLoop(host: host, watcher: watcher, listener: listener, speaker: refusing,
                                    enrolment: nil, confirm: nil)
        await loop.run(Self.source(try Self.input()), greet: false)
        #expect(host.all == ["show idle", "bump wake_rejected_foreign_voice"])
        #expect(refusing.checks == [.wake])
    }

    final class Refusing: SpeakerVerifying {
        private let seen = Mutex<[SpeakerCheck]>([])
        func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool {
            seen.withLock { $0.append(check) }
            return false
        }
        func matchesForBargeIn(_ clip: [Int16]) async -> Bool { false }
        var checks: [SpeakerCheck] { seen.withLock { $0 } }
    }
}

/// M11 part 3: the chimes, read from the system sounds and played on the hub's effect player.
@Suite("M11 chimes")
struct ChimeTests {
    @Test("Tink and Glass load as 48 kHz stereo, and play through the real graph at their own level", arguments: ChimeSound.allCases)
    func chime(_ sound: ChimeSound) async throws {
        let audio = try Chimes.load(sound.url)
        #expect(audio.sampleRate == 48_000 && audio.channels.count == 2)
        let peak = audio.channels.flatMap { $0 }.map { abs($0) }.max() ?? 0
        #expect(peak > 0.01, "\(sound.rawValue) is silent")
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let hub = try AudioHub(offline: output)
        let playing = Task { try await hub.play(audio, on: .effect, limit: .seconds(30)) }
        var rendered: [Float] = []
        var waits = 0
        while rendered.count < audio.frames {
            let next = try hub.renderOffline(frames: SystemHubEngine.offlineFrames)
            guard !next.isEmpty else {
                waits += 1
                try #require(waits < 2000)
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            rendered += next[0]
        }
        hub.stop(.effect)
        try await playing.value
        let renderedPeak = rendered.map { abs($0) }.max() ?? 0
        print("M11 chime \(sound.rawValue): \(audio.frames) frames, peak \(20 * log10(Double(peak))) dBFS, "
              + "rendered peak \(20 * log10(Double(renderedPeak))) dBFS")
        #expect(abs(renderedPeak - (audio.channels[0].map { abs($0) }.max() ?? 0)) < 1e-4)
    }
}
