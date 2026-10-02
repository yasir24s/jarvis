import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing
@testable import JarvisVoice

/// M11 part 4: barge-in (J:675-718, plan §3.6, T12.3). The rule on its own, then the watcher with
/// the real WebRTC VAD over say clips, and the real voiceprint check enrolled from one synthetic
/// voice. No microphone and nothing played.
@Suite("M11 barge-in", .serialized)
struct BargeInTests {
    static let frame = [Int16](repeating: 100, count: MicFrame.sampleCount)

    @Test("ten voiced frames in a row are checked; an unvoiced frame starts the count again")
    func rule() {
        var run = BargeInRun()
        for _ in 0..<9 { #expect(run.feed(Self.frame, voiced: true) == nil) }
        #expect(run.feed(Self.frame, voiced: false) == nil)
        for _ in 0..<9 { #expect(run.feed(Self.frame, voiced: true) == nil) }
        let clip = run.feed(Self.frame, voiced: true)
        #expect(clip?.count == 10 * MicFrame.sampleCount)
        // A check that does not match resets the run.
        run.reset()
        #expect(run.feed(Self.frame, voiced: true) == nil)
        #expect(BargeInRun.framesNeeded == 10)
    }

    @Test("JARVIS_BARGE_IN=0 turns it off")
    func environment() {
        #expect(BargeInWatcher.enabled(environment: [:]))
        #expect(!BargeInWatcher.enabled(environment: ["JARVIS_BARGE_IN": "0"]))
        #expect(BargeInWatcher.enabled(environment: ["JARVIS_BARGE_IN": "1"]))
    }

    static func frames(_ pcm: [Int16]) -> AsyncStream<MicFrame> {
        let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
        for f in WakeCorpus.frames(pcm) { feed.yield(f) }
        feed.finish()
        return stream
    }

    final class Checks: SpeakerVerifying {
        private let clips = Mutex<[Int]>([])
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
        func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool { true }
        func matchesForBargeIn(_ clip: [Int16]) async -> Bool {
            clips.withLock { $0.append(clip.count) }
            return answer
        }
        var asked: [Int] { clips.withLock { $0 } }
    }

    static func watcher(_ speaker: any SpeakerVerifying) -> BargeInWatcher {
        BargeInWatcher(makeVAD: { try WebRTCVAD(library: try Vendor.webrtcvad(), mode: 3) }, speaker: speaker)
    }

    @Test("speech is voiced: after 800 ms the voice check decides, and a match interrupts")
    func speechTriggers() async throws {
        let pcm = try ListenInputs.mix(try ListenInputs.read("speaker", "daniel_long"))
        let yes = Checks(answer: true)
        #expect(await Self.watcher(yes).watch(Self.frames(pcm)))
        #expect(yes.asked == [10 * MicFrame.sampleCount])
        // Fails closed: a voice that does not match never interrupts, however long it speaks.
        let no = Checks(answer: false)
        #expect(await Self.watcher(no).watch(Self.frames(pcm)) == false)
        #expect(no.asked.count >= 2)
    }

    @Test("a quiet room is never voiced, so the voice is never checked")
    func roomIsQuiet() async throws {
        let checks = Checks(answer: true)
        #expect(await Self.watcher(checks).watch(Self.frames(try ListenInputs.floor(5 * 16_000))) == false)
        #expect(checks.asked.isEmpty)
    }

    @Test("with a voiceprint enrolled from one voice, that voice interrupts and another does not")
    func voiceprint() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let encoder = try SpeakerCorpus.sharedEncoder()
        let print = Voiceprint(url: sb.root.appending(path: "voiceprint.npy"), encoder: encoder, research: BumpRecorder(),
                               log: { _ in })
        let takes = try ["daniel_enrol_1", "daniel_enrol_2", "daniel_enrol_3"].map { try SpeakerCorpus.samples($0) }
        #expect(try await print.enroll(takes: takes) == .saved(takes: 3))
        let enrolled = try ListenInputs.mix(try ListenInputs.read("speaker", "daniel_long"))
        let other = try ListenInputs.mix(try ListenInputs.read("speaker", "samantha_cmd")
                                         + ListenInputs.read("speaker", "karen_cmd"))
        #expect(await Self.watcher(print).watch(Self.frames(enrolled)))
        #expect(await Self.watcher(print).watch(Self.frames(other)) == false)
    }

    @Test("what the microphone heard while he spoke is not read afterwards; a frame with no capture time always is")
    func staleFramesAreDropped() async {
        let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
        for t: UInt64 in [10, 20, 30, 40] {
            feed.yield(MicFrame(samples: Self.frame, index: t, hostTime: t))
        }
        feed.yield(MicFrame(samples: Self.frame, index: 99, hostTime: 0))
        feed.finish()
        let source = FrameSource(stream)
        #expect(await source.next()?.hostTime == 10)
        await source.dropStale(before: 35)
        #expect(await source.next()?.hostTime == 40)
        #expect(await source.next()?.index == 99)
        #expect(await source.next() == nil)
    }
}
