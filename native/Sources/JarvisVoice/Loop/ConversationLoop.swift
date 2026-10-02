import Foundation
import JarvisCore

/// What the HUD shows of the loop: Python's `hud.state(...)` (plan §3.6, §3.7).
public enum LoopState: Sendable, Equatable {
    case idle, listening, thinking, speaking
}

/// What the conversation loop asks of the app (plan §3.6): the HUD, his voice, the turn and the
/// hooks. The app's is `AppHandsFree`; tests record the calls.
public protocol ConversationHost: Sendable {
    /// `hud.state(...)`.
    func show(_ state: LoopState) async
    /// `hud.caption(...)`.
    func caption(_ text: String) async
    /// `speak(text)`: returns once he has said it, or was stopped.
    func say(_ text: String) async
    /// `chime(name)`: starts the sound and returns.
    func chime(_ sound: ChimeSound) async
    /// `handle_one(command)`: the command as a `.voice` turn, its reply spoken. Returns when the
    /// reply is over (or was interrupted).
    func handle(_ command: String) async
    /// `identify_ambient`: the answer to "what song is this", or nil when JARVIS cannot identify
    /// music (M6 has not given him the means); the request then goes to the brain as a command.
    func identifyMusic() async -> String?
    /// `set_tone(desc)`.
    func setTone(_ descriptor: String) async
    /// `personality_distill_async()`: a conversation is over.
    func conversationEnded() async
    /// `research_bump(key)`.
    func bump(_ key: String) async
}

/// The wake word, as the loop waits for it: `WakeWatcher` in the app, a script in tests.
public protocol WakeWaiting: Sendable {
    func warm() async throws
    func waitForWake(_ source: FrameSource, confirm: WakeWatcher.Confirm?) async throws -> WakeResult
}

extension WakeWatcher: WakeWaiting {
    public func waitForWake(_ source: FrameSource, confirm: Confirm?) async throws -> WakeResult {
        try await wait(frames: source.frames, confirm: confirm)
    }
}

/// A sentence, as the loop listens for it: `SentenceListener` in the app, a script in tests.
public protocol SentenceListening: Sendable {
    func calibrate(_ source: FrameSource, seconds: Double) async -> Bool
    func listen(_ source: FrameSource, timeout: Double) async throws(SentenceListener.Failure) -> SentenceListener.Heard
}

extension SentenceListener: SentenceListening {}

/// `run_assistant`'s listening, from the microphone check to the loop of standby and
/// conversation (J:5513-5708, plan §3.6):
///
///     boot:         the microphone check (12 tries of 1 s, "Awaiting microphone access, sir."
///                   once), the 2 s calibration, the wake model warmed, the greeting
///     standby:      the wake word (WakeWatcher) → the wake clip's speaker check (a foreign voice
///                   is ignored without a sound) → Tink, listening → the command (the soft wake's
///                   own words, or a sentence within 2.5 s; nothing: "Yes, sir?" and up to
///                   CONV_TIMEOUT) → enrol | speaker check | tone | Shazam | the turn
///     conversation: follow-ups without the wake word, each checked, until CONV_TIMEOUT of
///                   silence, "That's all, Jarvis" ("Always a pleasure, sir."), or an enrolment
///
/// What is heard is never logged, only lengths. A dead stream asks the hub to rebuild the engine
/// and goes on; frames that end (the microphone closed) end the run.
public actor ConversationLoop {
    /// `CONV_TIMEOUT` (J:73): seconds a conversation stays open without speech.
    public static let conversationTimeout = 30.0
    /// The wait for a command after a hard wake (J:5655).
    public static let commandTimeout = 2.5
    /// The microphone check: 12 tries of `record(duration=1.0)`, 1.5 s apart (J:5530-5543).
    static let checkTries = 12
    static let checkGap = 1.5
    /// `recognizer.record(source, duration=4)`, three times (enroll_voice, J:5236-5238).
    static let enrolTakes = 3
    static let enrolSeconds = 4.0

    public static let yesSir = "Yes, sir?"
    public static let awaitingMicrophone = "Awaiting microphone access, sir."

    /// The greeting, by the hour (J:5551-5555).
    public static func greeting(hour: Int) -> String {
        let greet = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return "JARVIS online and running locally. \(greet), sir."
    }

    private let host: any ConversationHost
    private let watcher: any WakeWaiting
    private let listener: any SentenceListening
    private let speaker: (any SpeakerVerifying)?
    private let enrolment: (any VoiceEnrolling)?
    private let confirm: WakeWatcher.Confirm?
    private let rebind: @Sendable () -> Void
    private let hour: @Sendable () -> Int
    private let log: @Sendable (String) -> Void

    /// - speaker: the voiceprint's checks; nil checks nothing (accepts every voice).
    /// - enrolment: "learn my voice"; nil says it is not ready.
    /// - confirm: the soft tier's transcription; nil turns the soft tier off.
    /// - rebind: rebuilds the audio engine after a dead stream.
    public init(host: any ConversationHost, watcher: any WakeWaiting, listener: any SentenceListening,
                speaker: (any SpeakerVerifying)?, enrolment: (any VoiceEnrolling)?, confirm: WakeWatcher.Confirm?,
                rebind: @escaping @Sendable () -> Void = {},
                hour: @escaping @Sendable () -> Int = { Calendar.current.component(.hour, from: Date()) },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host
        self.watcher = watcher
        self.listener = listener
        self.speaker = speaker
        self.enrolment = enrolment
        self.confirm = confirm
        self.rebind = rebind
        self.hour = hour
        self.log = log
    }

    /// Boots, then listens until the frames end or the task is cancelled. `greet` says the
    /// greeting (the first start in a launch); `ready` is called once the loop is listening (the
    /// startup watchdog stands down).
    public func run(_ source: FrameSource, greet: Bool, ready: @escaping @Sendable () -> Void = {}) async {
        guard await boot(source, greet: greet) else { return }
        ready()
        while !Task.isCancelled {
            guard await standby(source) else { return }
        }
    }

    // MARK: boot

    /// The microphone check, the calibration, the wake model and the greeting. False when the
    /// frames ended first.
    func boot(_ source: FrameSource, greet: Bool) async -> Bool {
        var tries = 0
        while tries < Self.checkTries {
            guard let recorded = await record(source, seconds: 1.0) else { return false }
            if MicFrame(samples: recorded, index: 0).rms > 0 { break }
            if tries == 0 { await host.say(Self.awaitingMicrophone) }
            tries += 1
            guard await skip(source, seconds: Self.checkGap) else { return false }
        }
        log("listen: microphone ready after \(tries) attempt(s)")
        guard await listener.calibrate(source, seconds: SentenceListener.calibration) else { return false }
        do {
            try await watcher.warm()
        } catch {
            log("wake: the wake-word models would not load (\(error)); hands-free listening is off")
            return false
        }
        if greet { await host.say(Self.greeting(hour: hour())) }
        await host.show(.idle)
        log("listen: online and listening")
        return true
    }

    /// `recognizer.record(source, duration)`: Python reads one buffer past the duration and drops
    /// it (record(4) keeps 49 of the 50 it reads). nil when the frames ended.
    func record(_ source: FrameSource, seconds: Double) async -> [Int16]? {
        var elapsed = 0.0
        var samples: [Int16] = []
        while true {
            guard let frame = await source.next() else { return nil }
            elapsed += Double(MicFrame.sampleCount) / MicFrame.sampleRate
            if elapsed > seconds { return samples }
            samples += frame.samples
        }
    }

    /// `time.sleep(seconds)` with the stream open: the frames of that time go unheard.
    private func skip(_ source: FrameSource, seconds: Double) async -> Bool {
        for _ in 0..<Int((seconds / (Double(MicFrame.sampleCount) / MicFrame.sampleRate)).rounded()) {
            guard await source.next() != nil else { return false }
        }
        return true
    }

    // MARK: standby and conversation

    /// One pass of standby, and the conversation it opens. False when the frames ended.
    func standby(_ source: FrameSource) async -> Bool {
        let fired: WakeResult
        do {
            fired = try await watcher.waitForWake(source, confirm: confirm)
        } catch {
            log("wake: the detector failed (\(error))")
            return false
        }
        var text: String
        var audio: [Int16]?
        switch fired {
        case .ended:
            return false
        case .deadStream:
            log("listen: reopening the microphone stream")
            rebind()
            return true
        case .hard(let clip):
            guard await wakeIsTheUser(clip) else { return true }
            await host.chime(.tink)
            await host.show(.listening)
            do {
                let heard = try await listener.listen(source, timeout: Self.commandTimeout)
                (text, audio) = (heard.text, heard.clip)
            } catch .timedOut {
                (text, audio) = ("", nil)
            } catch {
                return false
            }
        case .soft(let heard, let clip):
            guard await wakeIsTheUser(clip) else { return true }
            await host.chime(.tink)
            await host.show(.listening)
            // The transcript around the wake word is in hand: "jarvis close safari" needs no
            // second listen. A bare wake word falls through to the prompt.
            let pre = WakePhrases.containsWakeWord(heard) ? WakePhrases.extractCommand(heard) : ""
            (text, audio) = (pre.isEmpty ? "" : heard, clip)
        }
        if text.isEmpty {
            await host.show(.listening)
            await host.say(Self.yesSir)
            do {
                let heard = try await listener.listen(source, timeout: Self.conversationTimeout)
                (text, audio) = (heard.text, heard.clip)
            } catch .timedOut {
                await host.show(.idle)
                return true
            } catch {
                return false
            }
            if text.isEmpty {
                await host.show(.idle)
                return true
            }
        }
        log("listen: heard \(text.count) chars")
        let command = WakePhrases.containsWakeWord(text) ? WakePhrases.extractCommand(text) : text
        if !command.isEmpty && WakePhrases.isEnroll(command) {
            return await enrol(source)
        }
        if !command.isEmpty, let audio, await !commandIsTheUser(audio) {
            log("listen: ignored, not the enrolled voice")
            return true
        }
        if !command.isEmpty, let audio {
            await host.setTone(ToneAnalyzer.analyze(audio, text: command))
        }
        if !command.isEmpty && WakePhrases.isShazam(command) {
            await host.show(.thinking)
            if let answer = await host.identifyMusic() {
                await host.show(.speaking)
                await host.caption(answer)
                await host.say(answer)
                await host.show(.idle)
                await host.caption("")
                return true
            }
        }
        if !command.isEmpty && !Dismissal.isDismiss(command) {
            await handleOne(command)
        } else {
            await host.show(.listening)
            await host.say(Self.yesSir)
        }
        let open = await conversation(source)
        await host.conversationEnded()
        return open
    }

    /// Follow-ups without the wake word until silence, a dismissal or an enrolment. False when the
    /// frames ended.
    func conversation(_ source: FrameSource) async -> Bool {
        while !Task.isCancelled {
            await host.show(.listening)
            let reply: String
            let audio: [Int16]
            do {
                let heard = try await listener.listen(source, timeout: Self.conversationTimeout)
                (reply, audio) = (heard.text, heard.clip)
            } catch .timedOut {
                await host.show(.idle)
                await host.caption("")
                return true
            } catch {
                return false
            }
            if reply.isEmpty { continue }
            if await !commandIsTheUser(audio) { continue }
            await host.setTone(ToneAnalyzer.analyze(audio, text: reply))
            log("listen: heard \(reply.count) chars")
            if WakePhrases.isEnroll(reply) {
                return await enrol(source)
            }
            if WakePhrases.isShazam(reply) {
                await host.show(.thinking)
                if let answer = await host.identifyMusic() {
                    await host.show(.speaking)
                    await host.caption(answer)
                    await host.say(answer)
                    continue
                }
            }
            if Dismissal.isDismiss(reply) {
                await host.show(.speaking)
                await host.say(Dismissal.reply)
                await host.show(.idle)
                await host.caption("")
                return true
            }
            await handleOne(WakePhrases.containsWakeWord(reply) ? WakePhrases.extractCommand(reply) : reply)
        }
        return false
    }

    /// `handle_one(command)`: stripped, and nothing at all when that leaves nothing (a bare
    /// "Jarvis" mid-conversation).
    private func handleOne(_ command: String) async {
        let command = Py.strip(command)
        guard !command.isEmpty else { return }
        await host.handle(command)
    }

    /// `speaker_ok(wake_clip, threshold=WAKE_SPK_THRESHOLD)`: a foreign voice is ignored with no
    /// chime, no HUD and no answer, and counted.
    private func wakeIsTheUser(_ clip: [Int16]) async -> Bool {
        guard let speaker, await !speaker.speakerOK(clip, for: .wake) else { return true }
        log("wake: ignored, not the enrolled voice")
        await host.bump(ResearchKey.wakeRejectedForeignVoice)
        return false
    }

    private func commandIsTheUser(_ clip: [Int16]) async -> Bool {
        guard let speaker else { return true }
        return await speaker.speakerOK(clip, for: .command)
    }

    // MARK: enrolment

    /// `enroll_voice(recognizer, source)` (J:5223-5254): three 4 s takes from this microphone,
    /// then the voiceprint. False when the frames ended.
    func enrol(_ source: FrameSource) async -> Bool {
        guard let enrolment else {
            await host.say(Voiceprint.Lines.notReady)
            return true
        }
        await host.say(Voiceprint.Lines.starting)
        await host.chime(.tink)
        var takes: [[Int16]] = []
        for _ in 0..<Self.enrolTakes {
            guard let take = await record(source, seconds: Self.enrolSeconds) else { return false }
            takes.append(take)
        }
        do {
            switch try await enrolment.enroll(takes: takes) {
            case .saved:
                await host.chime(.glass)
                await host.say(Voiceprint.Lines.set)
                log("listen: voiceprint enrolled by voice")
            case .nothingCaptured:
                await host.say(Voiceprint.Lines.nothingCaptured)
            }
        } catch {
            log("listen: enrolment failed (\(error))")
            await host.say(Voiceprint.Lines.notReady)
        }
        return true
    }
}
