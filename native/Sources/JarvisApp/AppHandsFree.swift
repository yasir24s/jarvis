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
    private var greeted = false
    /// Hands-free listening is running.
    private(set) var isOn = false

    /// - conversationOver: the brain's personality distillation (Python's
    ///   `personality_distill_async()`), started in the background.
    /// - makeInput, recognizer, assets, hub: the device, Apple's transcriber, the vendored wake
    ///   models and the audio engine in the app; tests pass fakes.
    /// - exitForRelaunch: the watchdog's exit when launchd will start the app again; nil
    ///   otherwise.
    init(core: CoreState, research: any ResearchCounting, voiceprint: Voiceprint?, voice: AppVoice,
         chat: ChatViewModel, hud: HUDModel, conversationOver: @escaping @Sendable () -> Void,
         makeInput: @escaping @Sendable () -> any MicInput = { HubMicInput() },
         recognizer: any SpeechRecognizing = AppleSpeechRecognizer(),
         assets: VendoredAssets = .appBundle(), hub: AudioHub = .shared,
         exitForRelaunch: @escaping @Sendable () -> Never? = AppHandsFree.launchdExit,
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
        do {
            try await mic.start()
        } catch {
            log("hands-free: the microphone would not open (\(error))")
            return
        }
        isOn = true
        voice.onAudio = { [weak self] playing in self?.audio(playing) }
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
        log("hands-free: listening for \"Hey Jarvis\"")
    }

    /// Ends the loop and closes the microphone.
    func stop() async {
        guard isOn else { return }
        isOn = false
        voice.onAudio = nil
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
        case .listening: hud.listening()
        case .thinking: hud.state(.thinking)
        case .speaking: hud.state(.speaking)
        }
    }

    fileprivate func caption(_ text: String) { hud.caption(text) }

    fileprivate func say(_ text: String) async { await voice.say(text) }

    fileprivate func chime(_ sound: ChimeSound) async { await chimes.play(sound) }

    /// `handle_one`: Tink, then the turn; back when its reply has been spoken.
    fileprivate func handle(_ command: String) async {
        await chimes.play(.tink)
        guard let turn = chat.sendVoice(command) else { return }
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
        func bump(_ key: String) async { await app.bump(key) }
    }
}

/// Set once, read from anywhere.
private final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
