import Foundation
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisVoice

/// The app's voice (M8, D-54): the F5 clone through the jarvis-voice helper in
/// `Contents/Helpers/`, macOS `say` as the fallback, and the one player, all behind SpeechQueue.
/// V6: Qwen3-TTS through jarvis-voice-qwen is the voice (`voiceEngine`, `qwen` unless set to
/// `f5`), streamed, with F5 behind it (VoiceSelector) and `say` last. Its stderr goes to
/// `jarvis-voice-qwen/helper.log` in the temporary folder.
/// Nothing starts until the user types with Speak replies on (V1 part 5: the helper is launched
/// and loads the model then) or a reply is spoken, and the helper exits after 10 idle minutes.
/// Its stderr goes to `jarvis-voice/helper.log` in the temporary folder. V1 part 1: a typed
/// message is acknowledged at once with a line the clone rendered at install. V1 part 5: while
/// anything is spoken, `activity` holds the file scan back.
@MainActor
final class AppVoice {
    let f5: F5Engine
    /// V6: Qwen, and the selector between it and F5 that the queue speaks with.
    let qwen: QwenEngine
    let selector: VoiceSelector
    let queue: SpeechQueue
    /// The helper's setup: the voice assets, where the acknowledgements were rendered, and the
    /// reference the voice speaks with.
    private let setup: VoiceHelperSetup
    /// The acknowledgements last played, oldest first (`Acknowledgement.recentLimit` of them).
    private var recentAcknowledgements: [String] = []
    /// Clips read so far, by file.
    private var clips: [URL: PCMChunk] = [:]
    private var reportedMissingClip = false
    /// The brain's turn activity, set once the brain is built: speech holds the file scan back.
    var activity: TurnActivity?
    private var lastWarm: ContinuousClock.Instant?

    /// UI1 part 3, the HUD's hooks: a reply's audio started (the reply as it is heard, and the
    /// audio's length in seconds), its audio ended, and its speech is over, with audio or not.
    var onReplyAudioStarted: ((String, Double) -> Void)?
    var onReplyAudioEnded: (() -> Void)?
    /// M11 part 4, barge-in's hook: any of his audio started (true) or ended (false), a part at
    /// a time: a reply's sentence, an acknowledgement, or one of the loop's own lines.
    var onAudio: ((Bool) -> Void)?
    var onReplyOver: (() -> Void)?
    /// Stop Speaking sticks (`SpeechMute`): while this says speaking is off, nothing is handed to
    /// the queue (replies, acknowledgements, the loop's lines); `onSilenced` gets the text instead.
    var muted: () -> Bool = { false }
    /// A line not spoken because speaking is off (the HUD shows it).
    var onSilenced: ((String) -> Void)?
    /// How many times `stop` has run. Each request to the queue carries it, so one asked for
    /// before a stop is dropped however late it reaches the queue (`SpeechQueue.cancelAll(through:)`).
    private var stops = 0
    /// Replies handed to `speak` whose speech is not over.
    private(set) var repliesPending = 0
    /// What the reply being spoken is heard as: the queue's own `TextClean`, less a short
    /// opening acknowledgement when one has played since the last reply (as `SpeechQueue.say`).
    private var heardReply: String?
    /// V5: the parts of `heardReply` still to be heard, as the queue splits it
    /// (`SpeechQueue.parts`); each part's audio is captioned with its own text.
    private var heardParts: [String] = []
    private var acknowledgedSinceReply = false
    /// The last acknowledgement clip handed to the queue, to tell its audio from a reply's.
    private var acknowledgementClip: PCMChunk?
    private var replyAudioPlaying = false

    init() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "jarvis-voice", directoryHint: .isDirectory)
        // voiceSpeed is read for each reply and at each helper launch, never kept (U1 part 5).
        let setup = VoiceHelperSetup.inApp(log: folder.appending(path: "helper.log"))
        self.setup = setup
        let f5 = F5Engine(launcher: setup)
        self.f5 = f5
        let qwenFolder = FileManager.default.temporaryDirectory.appending(path: "jarvis-voice-qwen", directoryHint: .isDirectory)
        let qwen = QwenEngine(launcher: QwenHelperSetup.inApp(log: qwenFolder.appending(path: "helper.log")))
        self.qwen = qwen
        let choice = Self.SharedDefaults(defaults: SpeechQueue.sharedDefaults)
        let log: @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }
        let selector = VoiceSelector(qwen: qwen, f5: f5, choice: { VoiceEngineChoice.choice(in: choice.defaults) },
                                     log: log)
        self.selector = selector
        let playback = PlaybackEvents()
        queue = SpeechQueue(engine: selector, fallback: SayEngine(), player: ReportingPlayer(EnginePlayer(), events: playback),
                            speed: VoiceHelperSetup.speedFromDefaults, reference: { setup.reference },
                            tooLong: { f5.tooLong($0) },
                            speakEarly: SpeechQueue.speakEarlyFromDefaults,
                            sentences: Self.sentences,
                            helperFootprintMB: { selector.lastFootprintMB },
                            log: log)
        playback.started = { [weak self] chunk in self?.audioStarted(chunk) }
        playback.streamStarted = { [weak self] seconds in self?.streamStarted(seconds: seconds) }
        playback.ended = { [weak self] in self?.audioEnded() }
    }

    /// `SpeakContext.ttsBackend`: "qwen" while Qwen is the voice in use (V6), else "f5", or "say"
    /// while F5 is unavailable too (not installed, or resting after two failures in a row). All
    /// are local voices.
    var backend: String {
        if selector.current == .qwen { return EngineID.qwen.rawValue }
        return f5.isAvailable ? EngineID.f5.rawValue : EngineID.say.rawValue
    }

    /// Whether Speak First Sentence Early acts on the voice in use. V6 made it F5's alone; V8: with
    /// Qwen it speaks a reply while the brain is still writing it (`EarlySpeech`).
    var speakEarlyApplies: Bool { true }

    /// V8: a typed reply spoken as it streams, while Qwen speaks and the setting is on.
    lazy var early = EarlySpeech(queue: queue, hooks: EarlySpeech.Hooks(
        applies: { [weak self] in
            guard let self else { return false }
            return !self.muted() && self.selector.current == .qwen && SpeechQueue.speakEarlyFromDefaults()
        },
        stops: { [weak self] in self?.stops ?? 0 },
        began: { [weak self] first in self?.earlyBegan(first) },
        over: { [weak self] in self?.replyOver() },
        handed: { [weak self] sentence in
            guard let self else { return }
            self.lastLine = [self.lastLine, sentence].compactMap { $0 }.joined(separator: " ")
        },
        log: { JarvisLog.log($0, category: .voice) }))

    /// V8: a reply's speech began with its first sentence while the brain still writes the rest.
    private func earlyBegan(_ first: String) {
        heardReply = TextClean.clean(first) ?? first
        heardParts = []
        acknowledgedSinceReply = false
        lastLine = nil   // `handed` adds each sentence
        inFlight += 1
        repliesPending += 1
        activity?.speechBegan()
    }

    private func replyOver() {
        activity?.speechEnded()
        inFlight -= 1
        repliesPending -= 1
        lastSpoke = SystemClock().now()
        onReplyOver?()
    }

    /// V8: the streamed text of a typed reply, as the chat row shows it.
    func replyDelta(_ text: String, turn: UUID) {
        early.delta(text, turn: turn)
    }

    func replyRetracted(turn: UUID) {
        early.retracted(turn: turn)
    }

    /// V8: the speak policy declined `turn`'s finished reply.
    func notSpoken(turn: UUID) {
        early.notSpoken(turn: turn)
    }

    /// UserDefaults is thread-safe (Apple documents it so) but is not marked Sendable.
    private struct SharedDefaults: @unchecked Sendable {
        let defaults: UserDefaults?
    }

    /// Replies handed to the queue whose audio has not finished. While any is, a live update
    /// waits (U1, `UpdateRule`).
    private(set) var inFlight = 0
    /// When the last of them finished, by the wall clock; nil before the first.
    private(set) var lastSpoke: Double?
    /// Live fix 4: the text of the last line he started to say (an acknowledgement, a reply or a
    /// loop line), for the echo filter.
    private(set) var lastLine: String?
    var isSpeaking: Bool { inFlight > 0 }

    /// V1 part 1: plays an acknowledgement of a typed message the moment it is sent (Speak
    /// replies on), rendered with the reference the voice speaks with, or else with the
    /// default one. Without a rendered clip nothing plays, and that is logged once. V6: while Qwen
    /// speaks, the clips are Qwen's (`acknowledgements/qwen-dry/`, rendered at its rate).
    func acknowledge(_ message: String, sentAt: ContinuousClock.Instant) {
        guard !muted() else { return }
        let line = Acknowledgement.choose(for: message, recent: recentAcknowledgements)
        let set = Acknowledgement.set(for: selector.current, f5Reference: setup.reference)
        let rendered = Acknowledgement.clipURL(line, assets: setup.assets, reference: set)
        let fallback = Acknowledgement.clipURL(line, assets: setup.assets, reference: VoiceHelperSetup.defaultReference)
        let url = FileManager.default.fileExists(atPath: rendered.path(percentEncoded: false)) ? rendered : fallback
        guard let clip = clip(url) else { return }
        recentAcknowledgements = Array((recentAcknowledgements + [line.name]).suffix(Acknowledgement.recentLimit))
        let stops = self.stops
        // V8: held for a moment while the reply is spoken as it is written (`EarlySpeech`).
        early.acknowledge(sentAt: sentAt) { [weak self] in
            guard let self else { return }
            self.acknowledgementClip = clip
            self.acknowledgedSinceReply = true
            self.lastLine = line.text
            let queue = self.queue
            let activity = self.activity
            self.inFlight += 1
            activity?.speechBegan()
            Task {
                await queue.acknowledge(clip, line: line.text, sentAt: sentAt, stops: stops)
                await queue.idle()
                activity?.speechEnded()
                self.inFlight -= 1
                self.lastSpoke = SystemClock().now()
            }
        }
    }

    /// V1 part 5: the user is typing with Speak replies on: the helper starts and loads the
    /// model now, so the reply waits for neither. At most every 5 s; the engine skips a helper
    /// that has already loaded it.
    func warm() {
        let now = ContinuousClock.now
        if let lastWarm, now - lastWarm < .seconds(5) { return }
        lastWarm = now
        let queue = self.queue
        Task { await queue.warm() }
    }

    private func clip(_ url: URL) -> PCMChunk? {
        if let clip = clips[url] { return clip }
        do {
            let clip = try Acknowledgement.loadClip(url)
            clips[url] = clip
            return clip
        } catch {
            if !reportedMissingClip {
                reportedMissingClip = true
                JarvisLog.log("voice: no acknowledgement clip (\(url.lastPathComponent): \(error)); "
                              + "install-voice-assets.sh renders them", category: .voice)
            }
            return nil
        }
    }

    /// Speaks a finished reply; a new reply cancels whatever is queued or playing. While speaking
    /// is off it is not spoken: `onSilenced` shows it instead.
    func speak(_ text: String, turn: UUID) {
        guard !muted() else {
            early.notSpoken(turn: turn)
            silenced(text)
            return
        }
        if early.finished(text, turn: turn) { return }   // V8: spoken as it was written
        let queue = self.queue
        let activity = self.activity
        let stops = self.stops
        heardReply = Self.heard(text, afterAcknowledgement: acknowledgedSinceReply)
        heardParts = heardReply.map {
            // V6: Qwen streams a reply whole, never in parts.
            SpeechQueue.parts($0, early: selector.current != .qwen && SpeechQueue.speakEarlyFromDefaults(),
                              sentences: Self.sentences)
        } ?? []
        acknowledgedSinceReply = false
        lastLine = heardReply
        inFlight += 1
        repliesPending += 1
        activity?.speechBegan()
        Task {
            await queue.say(text, turn: turn, stops: stops)
            await queue.idle()   // this reply, or one that replaced it, is over
            activity?.speechEnded()
            self.inFlight -= 1
            self.repliesPending -= 1
            self.lastSpoke = SystemClock().now()
            self.onReplyOver?()
        }
    }

    /// M11: one of the conversation loop's own lines ("Yes, sir?", the greeting, "Always a
    /// pleasure, sir."), spoken now; returns once it has been said, or stopped. The loop sets the
    /// HUD itself, so the line is not captioned, as Python's `speak()` leaves the caption alone.
    func say(_ text: String) async {
        guard !muted() else {
            silenced(text)
            return
        }
        let queue = self.queue
        let activity = self.activity
        let stops = self.stops
        heardReply = nil
        heardParts = []
        lastLine = text
        inFlight += 1
        activity?.speechBegan()
        await queue.say(text, turn: UUID(), stops: stops)
        await queue.idle()
        activity?.speechEnded()
        inFlight -= 1
        lastSpoke = SystemClock().now()
    }

    /// M11: returns once nothing is being spoken or waiting to be (a voice turn's reply is
    /// handed over as its turn ends, and spoken after).
    func quiet() async {
        while inFlight > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Stops what is speaking or being generated now (the Qwen helper is sent `cancel`), and
    /// anything asked for before this call that has not reached the queue yet. Stop Speaking
    /// also turns speaking off (`SpeechMute`); the chat's Stop, a message sent while he speaks
    /// and barge-in call only this.
    func stop() {
        let stopping = stopNow()
        Task { await stopping() }
    }

    /// Live fix 4: `stop()`, returning once his audio has stopped. Push-to-talk waits for this
    /// before the microphone opens.
    func stopAndWait() async {
        let speaking = isSpeaking
        await stopNow()()
        if speaking { JarvisLog.log("voice: his speech stopped before the microphone opened", category: .voice) }
    }

    private func stopNow() -> @Sendable () async -> Void {
        let queue = self.queue, qwen = self.qwen
        acknowledgedSinceReply = false   // as the queue's cancelAll forgets it
        early.stop()   // V8: a reply spoken as it is written takes nothing more
        stops += 1
        let stops = self.stops
        return {
            await qwen.cancelWarmUp()   // V9: a turn-start warm-up stops too
            await queue.cancelAll(through: stops)
        }
    }

    /// Live fix 4: a voice transcript without a trailing ", sir" that echoed his last line
    /// (`EchoFilter`), logged when it is taken off.
    func withoutEcho(_ transcript: String) -> String {
        let now = SystemClock().now()
        let at = isSpeaking ? now : lastSpoke
        guard let clean = EchoFilter.strip(transcript, lastLine: lastLine, spokeAt: at, now: now) else { return transcript }
        JarvisLog.log("voice: took an echo of his last line off the end of what was heard", category: .voice)
        return clean
    }

    private func silenced(_ text: String) {
        JarvisLog.log("voice: speaking is off (Stop Speaking); \(text.unicodeScalars.count) chars shown, not spoken",
                      category: .voice)
        onSilenced?(text)
    }

    /// A reply as the queue speaks it (`SpeechQueue.say`): cleaned, and without a short opening
    /// acknowledgement when one has just played. nil when there is nothing to speak.
    static func heard(_ text: String, afterAcknowledgement: Bool) -> String? {
        TextClean.clean(text).map { afterAcknowledgement ? Acknowledgement.spokenText($0) : $0 }
    }

    /// A reply's sentences, as the HUD's captions split them (V5: the queue's early first part).
    static let sentences: @Sendable (String) -> [String] = { SentenceSplitter.pop($0, force: true).sentences }

    /// The player started `chunk`: an acknowledgement, or the reply (or V5: one part of it).
    private func audioStarted(_ chunk: PCMChunk) {
        onAudio?(true)
        if let acknowledgementClip, acknowledgementClip.samples == chunk.samples { return }
        guard chunk.sampleRate > 0 else { return }
        replyAudioStarted(seconds: Double(chunk.samples.count) / chunk.sampleRate)
    }

    /// V6: a streamed reply started; `seconds` is the length it is expected to have, which is all
    /// that is known of it when it starts.
    private func streamStarted(seconds: Double) {
        onAudio?(true)
        replyAudioStarted(seconds: seconds)
    }

    /// The reply's audio (or one part of it) started, `seconds` long.
    private func replyAudioStarted(seconds: Double) {
        guard let heardReply else { return }
        replyAudioPlaying = true
        let part = heardParts.count > 1 ? heardParts.removeFirst() : (heardParts.first ?? heardReply)
        onReplyAudioStarted?(part, seconds)
    }

    private func audioEnded() {
        onAudio?(false)
        guard replyAudioPlaying else { return }
        replyAudioPlaying = false
        onReplyAudioEnded?()
    }

    /// Quit: speech stops, then the helper's stdin is closed and it has up to 2 s to exit.
    func shutdown() async {
        await queue.cancelAll()
        await selector.release()
    }
}

/// UI1 part 3: where `ReportingPlayer` reports, on the main actor.
@MainActor
final class PlaybackEvents {
    var started: ((PCMChunk) -> Void)?
    /// V6: a streamed reply started, expected to be this many seconds long.
    var streamStarted: ((Double) -> Void)?
    var ended: (() -> Void)?
}

/// UI1 part 3: the player the speech queue plays through. It tells `events` when each piece of
/// audio starts and when it is over (finished, stopped or failed), so the HUD can caption it.
/// It plays exactly what it is given.
final class ReportingPlayer: SpeechPlayer {
    private let inner: any SpeechPlayer
    private let events: PlaybackEvents

    init(_ inner: any SpeechPlayer, events: PlaybackEvents) {
        self.inner = inner
        self.events = events
    }

    func play(_ chunk: PCMChunk) async throws {
        let events = self.events
        await MainActor.run { events.started?(chunk) }
        do {
            try await inner.play(chunk)
        } catch {
            await MainActor.run { events.ended?() }
            throw error
        }
        await MainActor.run { events.ended?() }
    }

    /// V6: a streamed reply is reported once, as it starts, with the length it is expected to have.
    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        let events = self.events
        await MainActor.run { events.streamStarted?(expectedSeconds) }
        do {
            try await inner.playStream(pieces, expectedSeconds: expectedSeconds)
        } catch {
            await MainActor.run { events.ended?() }
            throw error
        }
        await MainActor.run { events.ended?() }
    }

    func stop() async {
        await inner.stop()
    }

    func replyStarting() async {
        await inner.replyStarting()
    }

    func replyReady() async {
        await inner.replyReady()
    }

    func replyEnded() async {
        await inner.replyEnded()
    }

    func lastStream() async -> StreamReport? {
        await inner.lastStream()
    }

    func expectColdVoice(_ cold: Bool) async {
        await inner.expectColdVoice(cold)
    }
}
