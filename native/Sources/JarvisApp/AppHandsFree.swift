import Foundation
import JarvisChat
import JarvisCore
import JarvisVoice
import Synchronization

/// M11: hands-free listening in the app, "Hey Jarvis" and the conversation after it (plan
/// M08-M13 §3.6). `start()` opens the microphone through the one AudioHub (voice processing
/// on) and runs the `ConversationLoop`; `stop()` ends it and closes the microphone.
///
/// - The loop's commands go to the chat as `.voice` turns (`ChatViewModel.sendVoice`), as
///   push-to-talk's do: the reply is always spoken, a spoken "yes" to a pending confirmation
///   still needs Touch ID (M9a part 6), and the HUD thinks and speaks through the chat's and the
///   voice's hooks. The loop waits for the reply's speech to finish before it listens again.
/// - The wake clip and every command are checked against the voiceprint (`speakerGate`); a
///   foreign wake is ignored without a sound.
/// - Its own lines ("Yes, sir?", the greeting, "Always a pleasure, sir.") go to the voice
///   directly. The greeting is said on the first start in a launch only.
/// - Barge-in (part 4): while he speaks, ten voiced frames that match the voiceprint stop him
///   through UI1's stop (`BargeInWatcher`); `JARVIS_BARGE_IN=0` turns it off.
/// - While it listens, idle system sleep is held off (`JARVIS_KEEP_AWAKE`, default 1, J:5459-5470),
///   so he hears the wake word with the screen locked.
/// - The startup watchdog (J:5482-5490): if the loop is not listening within 240 s, Python exits
///   with 86 and launchd starts it again. The app does so only when launchd runs it
///   (`com.jarvis.assistant`); otherwise it logs, stops listening and keeps the chat.
@MainActor
final class AppHandsFree {
    static let watchdog: Duration = .seconds(240)

    private let core: CoreState
    private let research: any ResearchCounting
    private let voiceprint: Voiceprint?
    private let voice: AppVoice
    private let chat: ChatViewModel
    private let hud: HUDModel
    private let conversationOver: @Sendable () -> Void
    private let mic: MicCapture
    private let transcriber: Transcriber
    private let chimes: Chimes
    private let hub: AudioHub
    private let assets: VendoredAssets
    private let log: @Sendable (String) -> Void
    private let exitForRelaunch: @Sendable () -> Never?
    private var run: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var guardTask: Task<Void, Never>?
    private let bargeIn: BargeInWatcher?
    private var watching: Task<Void, Never>?
    /// What the HUD shows of a confirmation waiting for a spoken "yes" (Mic Only Mode), or nil.
    private let prompt: @MainActor () -> String?
    /// Push-to-talk is listening: its words are its own turn, so the loop takes no command then.
    private let pushToTalkOn: @MainActor () -> Bool
    /// Live fix 1: the user is about to speak (the loop listens for a command): background
    /// on-device work gives way (`TurnActivity.preemptBackground`).
    private let userStarting: @MainActor () -> Void
    /// `JARVIS_KEEP_AWAKE` (J:5462): while listening, idle system sleep is held off.
    private var awake: (any NSObjectProtocol)?
    /// PR2: Ctrl-C while listening says "Going offline, sir." and then ends JARVIS (`goOffline`).
    private var interrupt: (any DispatchSourceSignal)?
    private let goOffline: @MainActor () -> Void
    private var greeted = false
    /// Hands-free listening is running.
    private(set) var isOn = false

    /// - conversationOver: the brain's personality distillation (Python's
    ///   `personality_distill_async()`), started in the background.
    /// - makeInput, recognizer, assets, hub: the device, Apple's transcriber, the vendored wake
    ///   models and the audio engine in the app; tests pass fakes.
    /// - exitForRelaunch: the watchdog's exit when launchd will start the app again; nil
    ///   otherwise.
    /// - goOffline: how JARVIS ends after "Going offline, sir." (the app's clean exit).
    init(core: CoreState, research: any ResearchCounting, voiceprint: Voiceprint?, voice: AppVoice,
         chat: ChatViewModel, hud: HUDModel, conversationOver: @escaping @Sendable () -> Void,
         makeInput: @escaping @Sendable () -> any MicInput = { HubMicInput() },
         recognizer: any SpeechRecognizing = AppleSpeechRecognizer(),
         assets: VendoredAssets = .appBundle(), hub: AudioHub = .shared,
         exitForRelaunch: @escaping @Sendable () -> Never? = AppHandsFree.launchdExit,
         prompt: @escaping @MainActor () -> String? = { nil },
         pushToTalkOn: @escaping @MainActor () -> Bool = { false },
         userStarting: @escaping @MainActor () -> Void = {},
         goOffline: @escaping @MainActor () -> Void = { exit(0) },
         log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }) {
        self.core = core
        self.research = research
        self.voiceprint = voiceprint
        self.voice = voice
        self.chat = chat
        self.hud = hud
        self.conversationOver = conversationOver
        self.assets = assets
        self.hub = hub
        self.exitForRelaunch = exitForRelaunch
        self.prompt = prompt
        self.pushToTalkOn = pushToTalkOn
        self.userStarting = userStarting
        self.goOffline = goOffline
        self.log = log
        mic = MicCapture(makeInput: makeInput, log: log)
        chimes = Chimes(hub: hub, log: log)
        // Barge-in (part 4): BARGE_IN_ENABLED and a voiceprint store; whether a voice is enrolled
        // is asked each time he speaks.
        if BargeInWatcher.enabled(), let voiceprint {
            bargeIn = BargeInWatcher(makeVAD: {
                try WebRTCVAD(library: try WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad), mode: 3)
            }, speaker: voiceprint, log: log)
        } else {
            bargeIn = nil
        }
        transcriber = Transcriber(
            recognizer: recognizer, research: research,
            corrections: { text in
                do {
                    return try await core.applyCorrections(text)
                } catch {
                    log("speech: corrections not applied (\(error))")
                    return text
                }
            },
            log: log)
    }

    /// Exits with 86 when launchd runs the app (it starts it again); nil otherwise.
    nonisolated static func launchdExit() -> Never? {
        guard ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.jarvis.assistant" else { return nil }
        exit(86)
    }

    /// Opens the microphone and starts the loop. Does nothing when it is already on.
    func start() async {
        guard !isOn else { return }
        let frames = await mic.frames()
        let levels = await mic.frames()
        do throws(MicError) {
            try await mic.start()
        } catch {
            log("hands-free: the microphone would not open (\(error))")
            // PR2: Python says so when there is no microphone to listen with.
            if let line = VoiceLoopLines.line(for: error) { await voice.say(line) }
            return
        }
        isOn = true
        voice.onAudio = { [weak self] playing in self?.audio(playing) }
        if ProcessInfo.processInfo.environment["JARVIS_KEEP_AWAKE", default: "1"] == "1" {
            awake = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled,
                                                          reason: "JARVIS is listening for “Hey Jarvis”")
        }
        let hud = self.hud
        meter = Task.detached(priority: .utility) {
            for await frame in levels {
                let level = frame.level
                await MainActor.run { if hud.state == .listening { hud.level(level) } }
            }
        }
        let loop = makeLoop()
        let greet = !greeted
        greeted = true
        let ready = Flag()
        run = Task(priority: .userInitiated) { [weak self] in
            await loop.run(FrameSource(frames), greet: greet, ready: { ready.set() })
            await self?.loopEnded()
        }
        let log = self.log
        let exitForRelaunch = self.exitForRelaunch
        guardTask = Task { [weak self] in
            try? await Task.sleep(for: Self.watchdog)
            guard !Task.isCancelled, !ready.isSet else { return }
            log("STARTUP WATCHDOG: not listening after 240s")
            _ = exitForRelaunch()
            log("hands-free: not run by launchd, so not exiting; listening stops")
            await self?.stop()
        }
        watchInterrupt()
        log("hands-free: listening for \"Hey Jarvis\"")
    }

    /// Ends the loop and closes the microphone.
    func stop() async {
        guard isOn else { return }
        isOn = false
        voice.onAudio = nil
        interrupt?.cancel()
        interrupt = nil
        signal(SIGINT, SIG_DFL)
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
        watching?.cancel()
        watching = nil
        guardTask?.cancel()
        run?.cancel()
        await mic.stop()
        _ = await run?.value
        meter?.cancel()
        run = nil
        meter = nil
        guardTask = nil
        hud.listeningEnded()
        log("hands-free: stopped")
    }

    private func loopEnded() async {
        guard isOn else { return }
        log("hands-free: the loop ended; the microphone closes")
        await stop()
    }

    private func makeLoop() -> ConversationLoop {
        let log = self.log
        let assets = self.assets
        let watcher = WakeWatcher(settings: .from(ProcessInfo.processInfo.environment, log: log), makeDetector: {
            try WakeWordDetector(runtime: try OrtRuntime.load(dylib: assets.onnxRuntime), assets: assets)
        }, log: log)
        let core = self.core
        let vocabulary: @Sendable () async -> [String] = {
            let inputs = await core.whisperVocabularyInputs()
            return Vocabulary.contextualStrings(base: Vocabulary.basePrompt(), name: inputs.name, meant: inputs.meant)
        }
        let transcriber = self.transcriber
        let listener = SentenceListener(pause: SentenceListener.pause(log: log), transcribe: { frames in
            switch await transcriber.transcribe(frames, vocabulary: await vocabulary(), preview: { _ in }) {
            case .text(let text, _): text
            case .nothing, .unavailable, .cancelled: ""
            }
        }, log: log)
        let hub = self.hub
        return ConversationLoop(host: Host(app: self), watcher: watcher, listener: listener,
                                speaker: voiceprint, enrolment: voiceprint,
                                confirm: WakeWatcher.confirming(with: transcriber, vocabulary: vocabulary),
                                rebind: { hub.rebind(reason: "250 frames of digital silence") }, log: log)
    }

    // MARK: barge-in

    /// His audio started or stopped (a part at a time): barge-in watches while it plays, as
    /// Python's watcher runs for each `speak()` (J:756-760), and only with a voice enrolled.
    private func audio(_ playing: Bool) {
        watching?.cancel()
        watching = nil
        guard playing, isOn, let bargeIn, let voiceprint else { return }
        let mic = self.mic
        watching = Task { [weak self] in
            guard await voiceprint.isEnrolled else { return }
            let frames = await mic.frames()
            if await bargeIn.watch(frames), !Task.isCancelled { await self?.interrupted() }
        }
    }

    /// The user talked over him: UI1's stop (his speech, and any reply still being written,
    /// which is closed and marked stopped), and `emotion_event("barge_in")`. The loop's turn then
    /// returns and it listens for what the user says next.
    private func interrupted() async {
        log("barge-in: stopping him")
        _ = chat.stop()
        do {
            try await core.emotionEvent("barge_in")
        } catch {
            log("barge-in: the emotion was not kept (\(error))")
        }
    }

    // MARK: what the loop asks of the app

    fileprivate func show(_ state: LoopState) {
        switch state {
        case .idle: hud.state(.idle)
        case .listening:
            userStarting()
            hud.listening()
            if let prompt = prompt() { hud.caption(prompt) }
        case .thinking: hud.state(.thinking)
        case .speaking: hud.state(.speaking)
        }
    }

    fileprivate func caption(_ text: String) { hud.caption(text) }

    fileprivate func say(_ text: String) async { await voice.say(text) }

    fileprivate func chime(_ sound: ChimeSound) async { await chimes.play(sound) }

    /// `handle_one`: Tink, then the turn; back when its reply has been spoken.
    fileprivate func handle(_ command: String) async {
        guard !pushToTalkOn() else {
            log("hands-free: push-to-talk is listening; the loop's command is dropped")
            return
        }
        await chimes.play(.tink)
        guard let turn = chat.sendVoice(voice.withoutEcho(command)) else { return }   // live fix 4
        await turn.value
        await voice.quiet()
    }

    fileprivate func setTone(_ descriptor: String) async {
        do {
            try await core.setTone(descriptor)
        } catch {
            log("listen: the tone was not kept (\(error))")
        }
    }

    fileprivate func conversationEnded() { conversationOver() }

    /// M11b: voice processing stays on from a reply until the loop is back in standby, so the
    /// switch off never clips the start of a follow-up.
    fileprivate func conversationWindow(open: Bool) {
        if open { hub.conversationOpened() } else { hub.conversationClosed() }
    }

    fileprivate func bump(_ key: String) { research.bump(key, by: 1) }

    /// The loop's view of the app.
    private struct Host: ConversationHost {
        let app: AppHandsFree

        func show(_ state: LoopState) async { await app.show(state) }
        func caption(_ text: String) async { await app.caption(text) }
        func say(_ text: String) async { await app.say(text) }
        func chime(_ sound: ChimeSound) async { await app.chime(sound) }
        func handle(_ command: String) async { await app.handle(command) }
        /// M6 has not given JARVIS the means to identify music: the request goes to the brain.
        func identifyMusic() async -> String? { nil }
        func setTone(_ descriptor: String) async { await app.setTone(descriptor) }
        func conversationEnded() async { await app.conversationEnded() }
        func conversationWindow(open: Bool) async { await app.conversationWindow(open: open) }
        func bump(_ key: String) async { await app.bump(key) }
    }
}

/// Set once, read from anywhere.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}

/// PR2: the voice loop's three lines Python had and the port did not, with Python's triggers.
enum VoiceLoopLines {
    /// `request_microphone_access`: said once while the microphone prompt is still waiting for
    /// the user's answer (Python checks every 0.25 s and says it on the first check).
    static let allowMicrophone = "Please allow microphone access, sir."
    /// `main`: no input device to listen with (`pick_microphone_index()` found none); the loop
    /// does not start.
    static let noMicrophone = "I cannot find a microphone, sir."
    /// `main`'s `except KeyboardInterrupt`: Ctrl-C (SIGINT) while the loop runs; said, then the
    /// process ends.
    static let offline = "Going offline, sir."
    static let promptWait: Duration = .milliseconds(250)

    /// `ListeningPermissions.ask`, saying `allowMicrophone` while an undecided microphone prompt
    /// waits longer than `wait`. A microphone already granted or denied says nothing, as Python.
    static func askPermissions(_ system: any PermissionAsking, wait: Duration = promptWait,
                               say: @escaping @Sendable (String) async -> Void) async -> ListeningPermission {
        if system.microphone() == .notDetermined {
            let nudge = Task {
                try await Task.sleep(for: wait)
                await say(allowMicrophone)
            }
            let granted = await system.requestMicrophone()
            nudge.cancel()
            guard granted else { return .microphoneDenied }
        }
        return await ListeningPermissions.ask(system)
    }

    /// The line for a microphone that would not open: only "no input device" is Python's
    /// "cannot find a microphone"; a converter or engine failure is logged as before.
    static func line(for error: MicError) -> String? {
        if case .noInputDevice = error { return noMicrophone }
        return nil
    }
}

extension AppHandsFree {
    /// Python's `except KeyboardInterrupt` in the loop: while listening, SIGINT is caught here
    /// (ignored by default, so the dispatch source sees it) instead of killing the process.
    fileprivate func watchInterrupt() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.interrupted(signal: SIGINT) }
        }
        source.resume()
        interrupt = source
    }

    private func interrupted(signal: Int32) {
        log("hands-free: interrupted (signal \(signal)); going offline")
        Task { await wentOffline() }
    }

    /// "Going offline, sir.", then the app's exit, as Python speaks and breaks out of `main`.
    func wentOffline() async {
        interrupt?.cancel()
        interrupt = nil
        await voice.say(VoiceLoopLines.offline)
        goOffline()
    }
}
