import Foundation
import JarvisChat
import JarvisVoice
import Observation

/// `setupCompleted` (M10 part 4): absent until the setup window's Done. While it is absent the
/// window opens at launch, unless the app was started with `--background`, as the chat window.
@MainActor
@Observable
final class SetupCompletion {
    nonisolated static let defaultsKey = "setupCompleted"

    private(set) var isCompleted: Bool
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isCompleted = defaults.object(forKey: Self.defaultsKey) != nil
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.defaultsKey)
        isCompleted = true
    }

    /// Whether the setup window opens at launch: the setting is absent and there is no
    /// `--background` (`arguments` is the whole command line, the executable first).
    nonisolated static func opensAtLaunch(arguments: [String], defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) == nil && !arguments.dropFirst().contains(ChatLaunch.backgroundFlag)
    }
}

/// The voiceprint as the setup window and the menus show it: whether one is enrolled and where
/// it came from. A voiceprint this app did not record (no `voiceprintRecordedAt`) is the Python
/// build's. Refreshed from the Voiceprint actor after a load, an enrolment or a forget.
@MainActor
@Observable
final class VoiceprintStatus {
    enum Origin: Equatable {
        case pythonBuild
        case recorded(Date)
    }

    static let recordedKey = "voiceprintRecordedAt"

    private(set) var enrolled = false
    /// False until the app's voiceprint store exists (it is built with the brain, once the lock is held).
    private(set) var ready = false
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var origin: Origin? {
        guard enrolled else { return nil }
        return (defaults.object(forKey: Self.recordedKey) as? Date).map { .recorded($0) } ?? .pythonBuild
    }

    /// After the store loaded (or did not find) voiceprint.npy.
    func loaded(enrolled: Bool) {
        self.enrolled = enrolled
        ready = true
    }

    /// After this app saved a new voiceprint.
    func recorded(at date: Date) {
        defaults.set(date, forKey: Self.recordedKey)
        enrolled = true
        ready = true
    }

    /// After Forget My Voice.
    func forgotten() {
        defaults.removeObject(forKey: Self.recordedKey)
        enrolled = false
    }
}

/// The first-launch setup (M10 part 4): a welcome in his voice; the microphone and speech
/// recognition; the voice enrolment, three short phrases with a live meter, a check that each
/// has enough voice, and a retry when not; learning from the user's files; speaking replies;
/// done. "Set Up JARVIS…" in both menus runs it again, to re-record the voice or change a choice.
@MainActor
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable, Comparable {
        case welcome, permissions, voice, files, speech, done

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        /// The step's heading, in the theme's tracked capitals.
        var heading: String {
            switch self {
            case .welcome: "WELCOME"
            case .permissions: "LISTENING"
            case .voice: "YOUR VOICE"
            case .files: "YOUR FILES"
            case .speech: "SPEAKING"
            case .done: "ALL SET"
            }
        }
    }

    /// The voice step, from the voiceprint already there (if any) to a saved one.
    enum Voice: Equatable {
        /// The app's voiceprint store is not built yet.
        case waiting
        /// A voiceprint is enrolled: keep it, or record again.
        case existing
        /// About to record take `take` (0, 1 or 2).
        case ready(take: Int)
        case recording(take: Int)
        case checking(take: Int)
        /// Take `take` had too little voice: record it again.
        case retry(take: Int, voicedSeconds: Double)
        case saving
        /// A new voiceprint is saved.
        case enrolled
        /// The one already there is kept.
        case kept
        /// Not now: no voiceprint was recorded.
        case skipped
        case failed(String)

        /// Whether Continue may leave the step.
        var isSettled: Bool {
            switch self {
            case .enrolled, .kept, .skipped, .failed: true
            default: false
            }
        }
    }

    enum Access: Equatable {
        case unknown, asking, granted, microphoneDenied, speechRecognitionDenied
    }

    /// The three phrases, one per take, about 2 to 3 s each in a 3.92 s take.
    static let phrases = [
        "JARVIS, what's on my calendar for today?",
        "Remind me to call the office at three o'clock.",
        "Open Safari and look up the train times to London.",
    ]

    /// His words, step by step. The welcome is also spoken.
    enum Lines {
        static let welcome = "Good day, sir. I am JARVIS. Before we begin, a few small matters: permission to hear you, "
            + "a sample of your voice so that I answer you and no one else, and how you would like me to speak. "
            + "It will take about a minute."
        static let permissions = "I shall need your microphone to hear you, and speech recognition to understand you. "
            + "What you say is transcribed on this Mac."
        static let microphoneDenied = "Microphone access is off for JARVIS, sir. To allow it, open System Settings, "
            + "choose Privacy & Security, then Microphone, and switch JARVIS on."
        static let speechDenied = "Speech recognition is off for JARVIS, sir. To allow it, open System Settings, "
            + "choose Privacy & Security, then Speech Recognition, and switch JARVIS on."
        static let existingPython = "You already have a voiceprint, sir, from the Python build of me. It works as it is, "
            + "though a recording made here may suit me better."
        static func existingRecorded(_ date: Date) -> String {
            "You recorded a voiceprint on \(date.formatted(date: .long, time: .omitted)), sir."
        }
        static let intro = "Three short phrases, sir, about four seconds each. Speak as you normally would, "
            + "from where you usually sit."
        static let retry = "I didn't hear enough of your voice in that one, sir. Once more, if you would."
        static let enrolled = "Your voiceprint is saved, sir. When I listen for you hands-free, I shall answer only your voice."
        static let kept = "Very good, sir. I'll keep the one you have."
        static let skipped = "As you wish, sir. You can record your voice later from Set Up JARVIS… in the JARVIS menu."
        static let waiting = "One moment, sir. I'm still starting up."
        static let micOff = "I can't hear you without the microphone, sir. Allow it on the previous step, then come back."
        /// P6's first-run offer (FileLearningConsent.firstRunOffer), with the switch beside it.
        static let files = "Should you care to let me, sir, I can learn about you from your documents, reading them "
            + "quietly in the background and keeping what I learn on this Mac. The longer ones go to Claude, with "
            + "anything that looks secret taken out first. Until you switch this on, I shan't read a thing."
        static let speech = "Shall I speak my replies aloud, sir, or keep to the page? You can change this at any time "
            + "with Speak replies in the menu-bar menu."
        static let done = "All set, sir. You'll find all of this again under Set Up JARVIS… in the JARVIS menu."
        static func failed(_ why: String) -> String {
            "I couldn't record your voice, sir (\(why)). You can try again from Set Up JARVIS… in the JARVIS menu."
        }
    }

    private(set) var step: Step = .welcome
    private(set) var voice: Voice = .waiting
    private(set) var access: Access = .unknown
    /// The live meter while a take records, 0...1.
    private(set) var level: Double = 0
    /// Good takes so far in this recording.
    private(set) var goodTakes = 0

    let completion: SetupCompletion
    let status: VoiceprintStatus
    let fileLearning: FileLearningConsent
    let speakReplies: SpeakRepliesToggle

    @ObservationIgnored private let permissions: any PermissionAsking
    @ObservationIgnored private let recorder: any TakeRecording
    @ObservationIgnored private let speak: @MainActor (String) -> Void
    @ObservationIgnored private let log: @Sendable (String) -> Void
    /// Where FileLearningConsent keeps `fileLearningOffered` (its app defaults in the app).
    @ObservationIgnored private let offerDefaults: UserDefaults
    @ObservationIgnored private var voiceprint: (any VoiceEnrolling)?
    @ObservationIgnored private var takes: [[Int16]] = []
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Closes the window (set by the view).
    @ObservationIgnored var close: () -> Void = {}

    init(completion: SetupCompletion, status: VoiceprintStatus, fileLearning: FileLearningConsent,
         speakReplies: SpeakRepliesToggle, permissions: any PermissionAsking, recorder: any TakeRecording,
         speak: @escaping @MainActor (String) -> Void, offerDefaults: UserDefaults = FileLearningConsent.appDefaults,
         log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.completion = completion
        self.offerDefaults = offerDefaults
        self.status = status
        self.fileLearning = fileLearning
        self.speakReplies = speakReplies
        self.permissions = permissions
        self.recorder = recorder
        self.speak = speak
        self.log = log
    }

    /// The app's voiceprint, once its store is built and `status` says whether it loaded one.
    func attach(_ voiceprint: any VoiceEnrolling) {
        self.voiceprint = voiceprint
        if voice == .waiting { voice = status.enrolled ? .existing : .ready(take: 0) }
    }

    /// The window opened (at launch or from the menu): back to the welcome, which he says.
    func start() {
        cancelRecording()
        step = .welcome
        access = Self.access(permissions)
        resetVoice()
        speak(Lines.welcome)
        log("setup: started (voiceprint \(status.enrolled ? "enrolled" : "not enrolled"))")
    }

    /// The welcome again, in his voice.
    func sayWelcome() {
        speak(Lines.welcome)
    }

    // MARK: moving between steps

    var canGoBack: Bool { step != .welcome && step != .done && !isBusy }

    var canContinue: Bool {
        switch step {
        case .voice: voice.isSettled
        case .done: false
        default: true
        }
    }

    /// While a take records, is checked or the voiceprint is saved.
    var isBusy: Bool {
        switch voice {
        case .recording, .checking, .saving: true
        default: false
        }
    }

    func next() {
        guard canContinue, let following = Step(rawValue: step.rawValue + 1) else { return }
        if step == .files {
            // The chat's own first-run offer (P6) is not made again once this step has asked.
            offerDefaults.set(true, forKey: FileLearningConsent.offeredKey)
        }
        step = following
    }

    func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Done: setup is completed, so it no longer opens at launch.
    func finish() {
        completion.markCompleted()
        log("setup: completed")
        close()
    }

    // MARK: permissions

    func askPermissions() {
        guard access != .asking else { return }
        access = .asking
        let permissions = self.permissions
        work = Task { [weak self] in
            let answer = await ListeningPermissions.ask(permissions)
            guard let self else { return }
            switch answer {
            case .granted: self.access = .granted
            case .microphoneDenied: self.access = .microphoneDenied
            case .speechRecognitionDenied: self.access = .speechRecognitionDenied
            }
            self.log("setup: listening permissions \(self.access)")
        }
    }

    /// What macOS says now, without asking.
    static func access(_ permissions: any PermissionAsking) -> Access {
        switch (permissions.microphone(), permissions.speechRecognition()) {
        case (.denied, _): .microphoneDenied
        case (_, .denied): .speechRecognitionDenied
        case (.granted, .granted): .granted
        default: .unknown
        }
    }

    var microphoneAllowed: Bool { permissions.microphone() == .granted }

    // MARK: the voice

    func keepVoiceprint() {
        guard voice == .existing else { return }
        voice = .kept
        log("setup: kept the voiceprint already enrolled")
    }

    func recordAgain() {
        guard voice == .existing else { return }
        takes = []
        goodTakes = 0
        voice = .ready(take: 0)
    }

    func skipVoice() {
        guard case .ready = voice else { return }
        cancelRecording()
        voice = .skipped
    }

    /// Records the take `ready` or `retry` names.
    func recordTake() {
        let take: Int
        switch voice {
        case .ready(let t), .retry(let t, _): take = t
        default: return
        }
        guard let voiceprint else { return }
        voice = .recording(take: take)
        level = 0
        let recorder = self.recorder
        // The meter's closure outlives no take, so it may hold the model.
        let model = self
        let meter: @Sendable (Double) -> Void = { value in
            Task { @MainActor in model.level = value }
        }
        work = Task { [weak self] in
            do {
                let samples = try await recorder.record(level: meter)
                self?.taken(samples, take: take, voiceprint: voiceprint)
            } catch is CancellationError {
                return
            } catch {
                self?.voice = .failed(String(describing: error))
                self?.log("setup: take \(take + 1) failed (\(error))")
            }
        }
    }

    private func taken(_ samples: [Int16], take: Int, voiceprint: any VoiceEnrolling) {
        voice = .checking(take: take)
        level = 0
        work = Task { [weak self] in
            do {
                let quality = try await voiceprint.quality(of: samples)
                guard let self, !Task.isCancelled else { return }
                self.log("setup: take \(take + 1) has \(quality.voicedSamples) voiced samples (\(quality.isGood ? "good" : "too few"))")
                guard quality.isGood else {
                    self.voice = .retry(take: take, voicedSeconds: Double(quality.voicedSamples) / 16000)
                    return
                }
                self.takes.append(samples)
                self.goodTakes = self.takes.count
                if take + 1 < Self.phrases.count {
                    self.voice = .ready(take: take + 1)
                } else {
                    self.save(voiceprint)
                }
            } catch {
                self?.voice = .failed(String(describing: error))
            }
        }
    }

    private func save(_ voiceprint: any VoiceEnrolling) {
        voice = .saving
        let takes = self.takes
        work = Task { [weak self] in
            do {
                let outcome = try await voiceprint.enroll(takes: takes)
                guard let self else { return }
                switch outcome {
                case .saved(let kept):
                    self.status.recorded(at: Date())
                    self.voice = .enrolled
                    self.log("setup: voiceprint saved from \(kept) takes")
                case .nothingCaptured:
                    self.voice = .failed("no take had enough voice")
                }
            } catch {
                self?.voice = .failed(String(describing: error))
                self?.log("setup: the voiceprint was not saved (\(error))")
            }
        }
    }

    /// Stops a take or a check in progress (the window closed); the takes so far are dropped.
    func cancelRecording() {
        work?.cancel()
        work = nil
        if isBusy { resetVoice() }
    }

    private func resetVoice() {
        takes = []
        goodTakes = 0
        level = 0
        if voiceprint == nil {
            voice = .waiting
        } else {
            voice = status.enrolled ? .existing : .ready(take: 0)
        }
    }

    /// The text the voice step shows for its state.
    var voiceLine: String {
        switch voice {
        case .waiting: Lines.waiting
        case .existing:
            switch status.origin {
            case .recorded(let date): Lines.existingRecorded(date)
            case .pythonBuild, nil: Lines.existingPython
            }
        case .ready(let take): take == 0 ? Lines.intro : "Good. Now the next one, sir."
        case .recording(let take), .checking(let take): Self.phrases[take]
        case .retry: Lines.retry
        case .saving: "One moment, sir."
        case .enrolled: Lines.enrolled
        case .kept: Lines.kept
        case .skipped: Lines.skipped
        case .failed(let why): Lines.failed(why)
        }
    }
}
