import Foundation
import JarvisBrain
import JarvisCore
import JarvisVoice

/// The app's voice (M8, D-54): the F5 clone through the jarvis-voice helper in
/// `Contents/Helpers/`, macOS `say` as the fallback, and the one player, all behind SpeechQueue.
/// Nothing starts until the user types with Speak replies on (V1 part 5: the helper is launched
/// and loads the model then) or a reply is spoken, and the helper exits after 10 idle minutes.
/// Its stderr goes to `jarvis-voice/helper.log` in the temporary folder. V1 part 1: a typed
/// message is acknowledged at once with a line the clone rendered at install. V1 part 5: while
/// anything is spoken, `activity` holds the file scan back.
@MainActor
final class AppVoice {
    let f5: F5Engine
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
    var onReplyOver: (() -> Void)?
    /// Replies handed to `speak` whose speech is not over.
    private(set) var repliesPending = 0
    /// What the reply being spoken is heard as: the queue's own `TextClean`, less a short
    /// opening acknowledgement when one has played since the last reply (as `SpeechQueue.say`).
    private var heardReply: String?
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
        let playback = PlaybackEvents()
        queue = SpeechQueue(engine: f5, fallback: SayEngine(), player: ReportingPlayer(EnginePlayer(), events: playback),
                            speed: VoiceHelperSetup.speedFromDefaults, reference: { setup.reference },
                            tooLong: { f5.tooLong($0) },
                            helperFootprintMB: { f5.lastFootprintMB },
                            log: { JarvisLog.log($0, category: .voice) })
        playback.started = { [weak self] chunk in self?.audioStarted(chunk) }
        playback.ended = { [weak self] in self?.audioEnded() }
    }

    /// `SpeakContext.ttsBackend`: "f5", or "say" while F5 is unavailable (not installed, or
    /// resting after two failures in a row). Both are local voices.
    var backend: String {
        f5.isAvailable ? EngineID.f5.rawValue : EngineID.say.rawValue
    }

    /// Replies handed to the queue whose audio has not finished. While any is, a live update
    /// waits (U1, `UpdateRule`).
    private(set) var inFlight = 0
    /// When the last of them finished, by the wall clock; nil before the first.
    private(set) var lastSpoke: Double?
    var isSpeaking: Bool { inFlight > 0 }

    /// V1 part 1: plays an acknowledgement of a typed message the moment it is sent (Speak
    /// replies on), rendered with the reference the voice speaks with, or else with the
    /// default one. Without a rendered clip nothing plays, and that is logged once.
    func acknowledge(_ message: String, sentAt: ContinuousClock.Instant) {
        let line = Acknowledgement.choose(for: message, recent: recentAcknowledgements)
        let rendered = Acknowledgement.clipURL(line, assets: setup.assets, reference: setup.reference)
        let fallback = Acknowledgement.clipURL(line, assets: setup.assets, reference: VoiceHelperSetup.defaultReference)
        let url = FileManager.default.fileExists(atPath: rendered.path(percentEncoded: false)) ? rendered : fallback
        guard let clip = clip(url) else { return }
        recentAcknowledgements = Array((recentAcknowledgements + [line.name]).suffix(Acknowledgement.recentLimit))
        acknowledgementClip = clip
        acknowledgedSinceReply = true
        let queue = self.queue
        let activity = self.activity
        inFlight += 1
        activity?.speechBegan()
        Task {
            await queue.acknowledge(clip, line: line.text, sentAt: sentAt)
            await queue.idle()
            activity?.speechEnded()
            self.inFlight -= 1
            self.lastSpoke = SystemClock().now()
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

    /// Speaks a finished reply; a new reply cancels whatever is queued or playing.
    func speak(_ text: String, turn: UUID) {
        let queue = self.queue
        let activity = self.activity
        heardReply = Self.heard(text, afterAcknowledgement: acknowledgedSinceReply)
        acknowledgedSinceReply = false
        inFlight += 1
        repliesPending += 1
        activity?.speechBegan()
        Task {
            await queue.say(text, turn: turn)
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
        let queue = self.queue
        let activity = self.activity
        heardReply = nil
        inFlight += 1
        activity?.speechBegan()
        await queue.say(text, turn: UUID())
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

    /// The menus' Stop Speaking.
    func stop() {
        let queue = self.queue
        acknowledgedSinceReply = false   // as the queue's cancelAll forgets it
        Task { await queue.cancelAll() }
    }

    /// A reply as the queue speaks it (`SpeechQueue.say`): cleaned, and without a short opening
    /// acknowledgement when one has just played. nil when there is nothing to speak.
    static func heard(_ text: String, afterAcknowledgement: Bool) -> String? {
        TextClean.clean(text).map { afterAcknowledgement ? Acknowledgement.spokenText($0) : $0 }
    }

    /// The player started `chunk`: an acknowledgement, or the reply.
    private func audioStarted(_ chunk: PCMChunk) {
        if let acknowledgementClip, acknowledgementClip.samples == chunk.samples { return }
        guard let heardReply, chunk.sampleRate > 0 else { return }
        replyAudioPlaying = true
        onReplyAudioStarted?(heardReply, Double(chunk.samples.count) / chunk.sampleRate)
    }

    private func audioEnded() {
        guard replyAudioPlaying else { return }
        replyAudioPlaying = false
        onReplyAudioEnded?()
    }

    /// Quit: speech stops, then the helper's stdin is closed and it has up to 2 s to exit.
    func shutdown() async {
        await queue.cancelAll()
        await f5.release()
    }
}

/// UI1 part 3: where `ReportingPlayer` reports, on the main actor.
@MainActor
final class PlaybackEvents {
    var started: ((PCMChunk) -> Void)?
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

    func stop() async {
        await inner.stop()
    }
}
