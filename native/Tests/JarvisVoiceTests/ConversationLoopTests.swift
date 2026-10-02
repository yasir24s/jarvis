import Foundation
import JarvisCore
import Synchronization
import Testing
@testable import JarvisVoice

/// M11 part 3: the conversation loop's state machine (plan §3.6, T12.2), with the wake word and
/// the listener scripted, a host that records what the loop does, and a speaker check that
/// refuses clips marked as another voice. No microphone, no models.
@Suite("M11 conversation loop")
struct ConversationLoopTests {
    /// A clip of "the user" and one of "another voice" (marked by its first sample).
    static let user = [Int16](repeating: 900, count: 32_000)
    static let other = [Int16](repeating: 7777, count: 32_000)

    final class Host: ConversationHost {
        private let events = Mutex<[String]>([])
        let music: String?
        init(music: String? = nil) { self.music = music }

        func note(_ e: String) { events.withLock { $0.append(e) } }
        var all: [String] { events.withLock { $0 } }

        func show(_ state: LoopState) async { note("show \(state)") }
        func caption(_ text: String) async { note("caption \(text)") }
        func say(_ text: String) async { note("say \(text)") }
        func chime(_ sound: ChimeSound) async { note("chime \(sound.rawValue)") }
        func handle(_ command: String) async { note("handle \(command)") }
        func identifyMusic() async -> String? {
            note("identify")
            return music
        }
        func setTone(_ descriptor: String) async { note("tone") }
        func conversationEnded() async { note("ended") }
        func bump(_ key: String) async { note("bump \(key)") }
    }

    final class Wake: WakeWaiting {
        private let results: Mutex<[WakeResult]>
        init(_ results: [WakeResult]) { self.results = Mutex(results) }
        func warm() async throws {}
        func waitForWake(_ source: FrameSource, confirm: WakeWatcher.Confirm?) async throws -> WakeResult {
            results.withLock { $0.isEmpty ? .ended : $0.removeFirst() }
        }
    }

    /// Each listen takes the next scripted outcome: a heard sentence, or nil for a timeout.
    final class Listener: SentenceListening {
        private let script: Mutex<[SentenceListener.Heard?]>
        private let timeouts = Mutex<[Double]>([])
        init(_ script: [SentenceListener.Heard?]) { self.script = Mutex(script) }
        func calibrate(_ source: FrameSource, seconds: Double) async -> Bool { true }
        func listen(_ source: FrameSource, timeout: Double) async throws(SentenceListener.Failure) -> SentenceListener.Heard {
            timeouts.withLock { $0.append(timeout) }
            let next: SentenceListener.Heard?? = script.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let next else { throw .ended }
            guard let heard = next else { throw .timedOut }
            return heard
        }
        var asked: [Double] { timeouts.withLock { $0 } }
    }

    final class Speaker: SpeakerVerifying {
        func speakerOK(_ clip: [Int16], for check: SpeakerCheck) async -> Bool { clip.first != 7777 }
        func matchesForBargeIn(_ clip: [Int16]) async -> Bool { clip.first != 7777 }
    }

    final class Enrolment: VoiceEnrolling {
        private let takes = Mutex<[Int]>([])
        var isEnrolled: Bool { get async { false } }
        func quality(of take: [Int16]) async throws -> TakeQuality { .good(voicedSamples: take.count) }
        func enroll(takes: [[Int16]]) async throws -> Voiceprint.EnrollOutcome {
            self.takes.withLock { $0 = takes.map(\.count) }
            return .saved(takes: takes.count)
        }
        var lengths: [Int] { takes.withLock { $0 } }
    }

    final class Count: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    static func heard(_ text: String, _ clip: [Int16] = user) -> SentenceListener.Heard? {
        SentenceListener.Heard(text: text, clip: clip)
    }

    /// `n` frames of a quiet room (not silent), or of digital silence.
    static func source(_ n: Int = 400, silentFirst: Int = 0) -> FrameSource {
        let (stream, feed) = AsyncStream.makeStream(of: MicFrame.self)
        for i in 0..<n {
            let value: Int16 = i < silentFirst ? 0 : (i % 2 == 0 ? 30 : -30)
            feed.yield(MicFrame(samples: [Int16](repeating: value, count: MicFrame.sampleCount), index: UInt64(i)))
        }
        feed.finish()
        return FrameSource(stream)
    }

    static func run(wake: [WakeResult], listen: [SentenceListener.Heard?], host: Host = Host(),
                    enrolment: Enrolment? = nil, greet: Bool = false, source: FrameSource = source(),
                    rebinds: Count = Count()) async -> (Host, Listener) {
        let listener = Listener(listen)
        let loop = ConversationLoop(host: host, watcher: Wake(wake), listener: listener, speaker: Speaker(),
                                    enrolment: enrolment, confirm: nil, rebind: { rebinds.add() },
                                    hour: { 9 })
        await loop.run(source, greet: greet)
        return (host, listener)
    }

    @Test("boot: the greeting by the hour, then idle; a silent microphone is waited for, once aloud")
    func boot() async {
        #expect(ConversationLoop.greeting(hour: 9) == "JARVIS online and running locally. Good morning, sir.")
        #expect(ConversationLoop.greeting(hour: 12) == "JARVIS online and running locally. Good afternoon, sir.")
        #expect(ConversationLoop.greeting(hour: 17) == "JARVIS online and running locally. Good evening, sir.")
        let (host, _) = await Self.run(wake: [], listen: [], greet: true, source: Self.source(600, silentFirst: 60))
        #expect(host.all == ["say Awaiting microphone access, sir.",
                             "say JARVIS online and running locally. Good morning, sir.", "show idle"])
    }

    @Test("a foreign voice's wake is ignored: no chime, no HUD, no answer, and it is counted")
    func foreignWake() async {
        let (host, listener) = await Self.run(wake: [.hard(clip: Self.other)], listen: [])
        #expect(host.all == ["show idle", "bump wake_rejected_foreign_voice"])
        #expect(listener.asked.isEmpty)
    }

    @Test("a bare wake word: Tink, nothing within 2.5 s, \"Yes, sir?\", the command, then follow-ups until silence")
    func bareWake() async {
        let (host, listener) = await Self.run(wake: [.hard(clip: Self.user)],
                                              listen: [nil, Self.heard("what's the time"), nil])
        #expect(host.all == ["show idle", "chime Tink", "show listening", "show listening", "say Yes, sir?", "tone",
                             "handle what's the time", "show listening", "show idle", "caption ", "ended"])
        #expect(listener.asked == [2.5, 30, 30])
    }

    @Test("a soft wake with its command needs no second listen")
    func softWakeWithCommand() async {
        let (host, listener) = await Self.run(wake: [.soft(text: "jarvis close safari", clip: Self.user)], listen: [nil])
        #expect(host.all == ["show idle", "chime Tink", "show listening", "tone", "handle close safari",
                             "show listening", "show idle", "caption ", "ended"])
        #expect(listener.asked == [30])
    }

    @Test("a soft wake that is only the wake word gets \"Yes, sir?\"")
    func softBareWake() async {
        let (host, _) = await Self.run(wake: [.soft(text: "jarvis", clip: Self.user)], listen: [nil])
        #expect(host.all == ["show idle", "chime Tink", "show listening", "show listening", "say Yes, sir?", "show idle"])
    }

    @Test("silence after \"Yes, sir?\" goes back to standby, with no conversation")
    func timeoutToIdle() async {
        let (host, _) = await Self.run(wake: [.hard(clip: Self.user)], listen: [nil, nil])
        #expect(host.all == ["show idle", "chime Tink", "show listening", "show listening", "say Yes, sir?", "show idle"])
    }

    @Test("\"That's all, Jarvis\" ends the conversation with \"Always a pleasure, sir.\"")
    func dismissal() async {
        let (host, _) = await Self.run(wake: [.hard(clip: Self.user)],
                                       listen: [Self.heard("what's the time"), Self.heard("that's all jarvis")])
        #expect(host.all == ["show idle", "chime Tink", "show listening", "tone", "handle what's the time",
                             "show listening", "tone", "show speaking", "say Always a pleasure, sir.", "show idle",
                             "caption ", "ended"])
    }

    @Test("\"Jarvis, learn my voice\" enrols from three 4 s takes of this microphone")
    func enrol() async {
        let enrolment = Enrolment()
        let (host, _) = await Self.run(wake: [.hard(clip: Self.user)], listen: [Self.heard("jarvis learn my voice")],
                                       enrolment: enrolment)
        #expect(host.all == ["show idle", "chime Tink", "show listening", "say \(Voiceprint.Lines.starting)", "chime Tink",
                             "chime Glass", "say \(Voiceprint.Lines.set)"])
        // record(4) keeps 49 buffers of the 50 it reads.
        #expect(enrolment.lengths == [49, 49, 49].map { $0 * MicFrame.sampleCount })
    }

    @Test("another voice mid-conversation is ignored; a bare \"Jarvis\" does nothing; the next follow-up runs")
    func conversationChecks() async {
        let (host, _) = await Self.run(wake: [.hard(clip: Self.user)],
                                       listen: [Self.heard("open safari"), Self.heard("turn it off", Self.other),
                                                Self.heard("jarvis"), Self.heard("and the news"), nil])
        // Listening for each follow-up: the other voice (ignored), "jarvis" (its tone read, then
        // nothing to do), "and the news" (handled), then silence.
        #expect(host.all == ["show idle", "chime Tink", "show listening", "tone", "handle open safari",
                             "show listening", "show listening", "tone", "show listening", "tone",
                             "handle and the news", "show listening", "show idle", "caption ", "ended"])
    }

    @Test("a command in another voice after the wake is dropped")
    func foreignCommand() async {
        let (host, _) = await Self.run(wake: [.hard(clip: Self.user)], listen: [Self.heard("open safari", Self.other)])
        #expect(host.all == ["show idle", "chime Tink", "show listening"])
    }

    @Test("a dead stream asks for the engine to be rebuilt and listening goes on")
    func deadStream() async {
        let rebinds = Count()
        let (host, _) = await Self.run(wake: [.deadStream, .hard(clip: Self.other)], listen: [], rebinds: rebinds)
        #expect(rebinds.value == 1)
        #expect(host.all == ["show idle", "bump wake_rejected_foreign_voice"])
    }

    @Test("\"What song is this\": identified when JARVIS can, else it goes to the brain")
    func shazam() async {
        let (known, _) = await Self.run(wake: [.hard(clip: Self.user)], listen: [Self.heard("what song is this")],
                                        host: Host(music: "That's Clair de Lune, sir."))
        #expect(known.all == ["show idle", "chime Tink", "show listening", "tone", "show thinking", "identify",
                              "show speaking", "caption That's Clair de Lune, sir.", "say That's Clair de Lune, sir.",
                              "show idle", "caption "])
        let (unknown, _) = await Self.run(wake: [.hard(clip: Self.user)], listen: [Self.heard("what song is this"), nil])
        #expect(unknown.all == ["show idle", "chime Tink", "show listening", "tone", "show thinking", "identify",
                                "handle what song is this", "show listening", "show idle", "caption ", "ended"])
    }
}
