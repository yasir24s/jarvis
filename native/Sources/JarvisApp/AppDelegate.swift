import AppKit
import CoreLocation
import Observation
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import JarvisVoice

/// What the menu shows. Written only by AppDelegate, on the main actor.
@MainActor
@Observable
final class AppModel {
    var stateRoot = "—"
    var lockHolder = "—"
}

/// App lifecycle (plan: M00 §3.9, §3.5; D-43). Startup order: regular policy → state root →
/// logging → banner → policy read-back → lock → (from M1) subsystems. Nothing reads or writes
/// state before the lock is held. Closing the chat window leaves JARVIS running; Quit (the app
/// menu, the menu-bar item or Cmd-Q) stops the brain before the app exits.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    /// The chat window's state. It sends nothing until the brain has started.
    let chat = ChatViewModel()
    /// The menu's "Speak replies" toggle, the user's input to the speak policy.
    let speakReplies = SpeakRepliesToggle()
    /// P6: "Learn About Me From My Files", the user's consent to the file scanner.
    let fileLearning = FileLearningConsent()
    /// U1: watches dist/staged/ for a new build and swaps over when JARVIS is not in use. It
    /// sees nothing unless this bundle runs as dist/JARVIS.app with its update helper.
    let updates = UpdateWatcher(folders: UpdateFolders.of(bundle: Bundle.main.bundleURL))
    private var lock: InstanceLock?
    /// Built once the lock is held and kept for the app's life (plan: M02-M04 §3.5, §3.12).
    private var brain: BrainAssembly?
    /// The research scheduler (plan: M01b §3.5), started once CoreState exists. It is stopped
    /// before the lock is released: its flush writes, and writes need the lease (D-36).
    private var research: ResearchScheduler?
    /// The personality upkeep (P1), started with the brain and stopped, like `research`,
    /// before the lock is released: its passes write, and writes need the lease.
    private var personality: PersonalitySchedule?
    private var idleCompile: IdleCompile?
    /// W1: the web memory's background summaries, stopped at quit before the lock is released.
    private var webSummaries: WebSummaryQueue?
    /// W1 part 5: the background reading, stopped at quit before the lock is released.
    private var reading: BackgroundReader?
    /// The background reading of the user's files (P3), started once the brain has started
    /// and stopped at quit before the lock is released: its index and facts writes need the lease.
    private var files: FileScanner?
    /// M8's voice (AppVoice), built with the brain. Its helper starts only when a reply is spoken.
    private var voice: AppVoice?
    private var sigterm: DispatchSourceSignal?
    /// Opens the chat window. Set by the window each time it appears, for the Dock icon.
    var openChat: (() -> Void)?
    /// U1: the chat window, whose frame a live update saves, and the frame a resumed launch
    /// puts back once the window is there.
    private weak var chatWindow: NSWindow?
    private var pendingFrame: NSRect?
    /// U1: this state root's run folder, where resume.json is written before a swap, and the
    /// log the update helper appends to.
    private var runFolder: URL?
    private var logFile: URL?
    /// U1: the hand-over this launch was opened with (`--resume <path>`), read once: the path,
    /// and its contents unless they were missing or did not parse.
    static let resumeAtLaunch: (url: URL, state: ResumeState?)? = ResumeLaunch.path(arguments: CommandLine.arguments)
        .map { ($0, ResumeState.read($0)) }
    /// get_wifi_status reads the network name through CoreWLAN, which returns none without
    /// Location Services. Kept alive for the app's life, as CLLocationManager must be.
    private let location = CLLocationManager()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A regular app with a Dock icon (D-43); main thread by isolation.
        // M13's HUD is a non-activating NSPanel and must never change this policy.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSIGTERMHandler()
        // Asked once: macOS shows the prompt only while the user has not decided.
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }

        let paths: StatePaths
        do {
            paths = try StatePaths.live()
        } catch {
            JarvisLog.configure(file: nil, mirrorToStdout: isatty(STDOUT_FILENO) == 1)
            JarvisLog.log("cannot resolve the state root (\(error)) — exiting.", category: .state)
            exit(78)   // EX_CONFIG
        }
        JarvisLog.configure(file: paths.logFile, mirrorToStdout: isatty(STDOUT_FILENO) == 1)
        JarvisLog.banner()

        // Log the policy only after reading it back — the log line is the evidence.
        let policy = NSApplication.shared.activationPolicy()
        if policy == .regular {
            JarvisLog.log("activation policy: regular")
        } else {
            JarvisLog.log("activation policy: \(Self.describe(policy)) (expected regular)")
        }

        model.stateRoot = Self.abbreviate(paths.root)
        if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.jarvis.assistant" {
            // launchd mode: wait for the other JARVIS instead of exiting (no KeepAlive thrash).
            model.lockHolder = "waiting"
            Task { @MainActor in
                let held = await InstanceLock.acquireWaiting(at: paths.lockFile, repoRoot: paths.root) { holder in
                    JarvisLog.log("Another JARVIS (\(Self.describe(holder))) holds .jarvis.lock — waiting.",
                                  category: .lock)
                }
                self.lockAcquired(held, paths: paths)
            }
            return
        }
        if Self.resumeAtLaunch != nil {
            // U1: a live update's new build; the old process may still be letting go of the lock.
            model.lockHolder = "waiting"
            Task { @MainActor in
                let held = await ResumeLaunch.retry(timeout: ResumeLaunch.lockWait, every: .milliseconds(250)) {
                    () -> InstanceLock? in
                    if case .acquired(let lock) = InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) {
                        return lock
                    }
                    return nil
                }
                guard let held else {
                    self.exitHeld("\(Self.describe(InstanceLock.readHolder(at: paths.lockFile))), still after 15 s")
                }
                self.lockAcquired(held, paths: paths)
            }
            return
        }
        switch InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) {
        case .acquired(let held):
            lockAcquired(held, paths: paths)
        case .held(let holder):
            exitHeld(Self.describe(holder))
        case .foreignProcess(let pids):
            exitHeld("python \(pids[0]), pre-patch")
        }
    }

    /// Closing the chat window leaves JARVIS running (D-43).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock icon with the chat window closed opens it again (D-43). The window hands over
    /// its opener the first time it appears; until then this is left to SwiftUI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openChat?()
        }
        return true
    }

    /// Quit stops the brain first: the MCP server closes its socket. The app exits once that
    /// is done. Speech stops at once, and the voice helper's stdin is closed last, with up to
    /// 2 s for it to exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updates.stop()
        let voice = self.voice
        self.voice = nil
        voice?.stop()
        guard let brain else {
            guard let voice else { return .terminateNow }
            Task { @MainActor in
                await voice.shutdown()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        self.brain = nil
        let files = self.files
        self.files = nil
        Task { @MainActor in
            await files?.stop()   // its last index save happens while the lease is still held
            await brain.stop()
            await voice?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        JarvisLog.log("Quit JARVIS — exiting.")
        research?.stop()   // flushes enqueued bumps while the lease is still held
        research = nil
        personality?.stop()   // no personality pass outlives the lease
        personality = nil
        idleCompile?.stop()   // nor an idle compile
        idleCompile = nil
        webSummaries?.stop()   // nor a page summary (W1)
        webSummaries = nil
        reading?.stop()   // nor a background reading pass (W1)
        reading = nil
        files?.cancel()   // already stopped on a normal quit; no file read outlives the lease
        files = nil
        lock = nil   // closes the fd: releases the flock before exit
    }

    private func lockAcquired(_ held: InstanceLock, paths: StatePaths) {
        lock = held
        model.lockHolder = Self.describe(InstanceLock.readHolder(at: paths.lockFile))
        runFolder = RunFolders(stateRoot: paths.root, defaultRoot: Self.defaultRoot(ProcessInfo.processInfo.environment)).run
        logFile = paths.logFile
        // U1: a live update's chat is back before anything else is shown in it.
        if let launch = Self.resumeAtLaunch { resume(launch) }
        startBrain(lock: held, paths: paths)
        // U1: from here a staged build is noticed, even when the brain did not start.
        updates.start(signals: { [weak self] in self?.updateSignals() ?? Self.busySignals },
                      swap: { [weak self] build in self?.swapOver(to: build) })
    }

    /// What the live-update rule reads (U1): the turn, the speech and the confirmation, and the
    /// latest use of the chat, a turn or the voice.
    private func updateSignals() -> UpdateRule.Signals {
        let turns = brain?.turnActivity
        let uses = [Self.processStarted, chat.lastUse, turns?.lastActivity, voice?.lastSpoke].compactMap { $0 }
        return UpdateRule.Signals(turnInFlight: (turns?.isRunning ?? false) || chat.responding,
                                  speechActive: voice?.isSpeaking ?? false,
                                  confirmationPending: chat.pending != nil,
                                  lastUse: uses.max() ?? Self.processStarted)
    }

    /// Signals that never allow a swap, for a delegate that is already gone.
    private static let busySignals = UpdateRule.Signals(turnInFlight: true, speechActive: false,
                                                        confirmationPending: false, lastUse: .infinity)

    /// The swap-over (U1). resume.json first, while everything is still running; then the
    /// background work stops as on SIGTERM and the lock is let go; then the update helper is
    /// started, detached, and this process exits. The helper waits for the exit, promotes the
    /// staged build and opens it with `--resume`.
    private func swapOver(to build: BuildID) {
        let helper = Bundle.main.bundleURL.appending(path: UpdateFolders.helperPath)
        guard let folders = updates.folders, let runFolder,
              FileManager.default.isExecutableFile(atPath: helper.path(percentEncoded: false)) else {
            JarvisLog.log("update: cannot swap (no run folder or update helper); staying on this build")
            return
        }
        let resumeFile = runFolder.appending(path: ResumeState.fileName)
        let state = ResumeState(from: BuildID.running(), to: build, written: SystemClock().now(),
                                chat: chat.resumeSnapshot(), window: chatWindowState())
        do {
            try state.write(to: resumeFile)
        } catch {
            JarvisLog.log("update: cannot write resume.json (\(error)); staying on this build")
            return
        }
        JarvisLog.log("update: handing over to \(build.label); exiting for the update helper")
        let lockFile = lock?.url.path(percentEncoded: false) ?? ""
        // As the SIGTERM path does: nothing that writes outlives the lease.
        research?.stop()   // flushes enqueued bumps while the lease is still held
        personality?.stop()
        idleCompile?.stop()
        files?.cancel()
        lock = nil   // closes the fd: releases the flock before the helper starts
        let process = Process()
        process.executableURL = helper
        process.arguments = ["swap", "--pid", "\(getpid())", "--dist", folders.dist.path(percentEncoded: false),
                             "--resume", resumeFile.path(percentEncoded: false), "--lock", lockFile,
                             "--log", logFile?.path(percentEncoded: false) ?? "/dev/null"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            // No helper: this same build is opened again with the hand-over, so nothing is lost.
            JarvisLog.log("update: cannot start the update helper (\(error)); reopening this build")
            let reopen = Process()
            reopen.executableURL = URL(filePath: "/usr/bin/open")
            reopen.arguments = ["-n", "-g", Bundle.main.bundleURL.path(percentEncoded: false), "--args",
                                ResumeLaunch.flag, resumeFile.path(percentEncoded: false)]
            try? reopen.run()
        }
        exit(0)
    }

    /// The chat window as resume.json records it: open or not, and its frame.
    private func chatWindowState() -> ResumeState.Window {
        guard let window = chatWindow else { return ResumeState.Window(open: false, frame: nil) }
        let f = window.frame
        return ResumeState.Window(open: window.isVisible,
                                  frame: [f.origin.x, f.origin.y, f.size.width, f.size.height])
    }

    /// The new build's side of a live update (U1): the chat, draft and scroll go back into the
    /// chat, the window frame waits for the window, resume.json is deleted, and the swap's
    /// length is logged. The launch is not counted as a start (`ResearchScheduler`).
    private func resume(_ launch: (url: URL, state: ResumeState?)) {
        defer { try? FileManager.default.removeItem(at: launch.url) }
        guard let state = launch.state else {
            JarvisLog.log("update: \(launch.url.lastPathComponent) is missing or unreadable; nothing to restore")
            return
        }
        chat.restore(state.chat)
        if let f = state.window.frame, f.count == 4 {
            pendingFrame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            if let chatWindow { chatWindowAppeared(chatWindow) }
        }
        JarvisLog.log(ResumeLaunch.resumedLine(state, now: SystemClock().now(), running: BuildID.running()))
    }

    /// update-health.json beside resume.json, 30 s after the brain started, if it is still the
    /// running one: the update helper keeps this build only once it appears (U1).
    private func reportHealthy(_ resumeFile: URL, assembly: BrainAssembly) {
        let health = resumeFile.deletingLastPathComponent().appending(path: ResumeState.healthFileName)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: ResumeLaunch.healthyAfter)
            guard let self, self.brain === assembly else { return }
            let report = ResumeLaunch.healthReport(pid: getpid(), build: BuildID.running(), at: SystemClock().now())
            do {
                try ResumeState.writePrivately(report, to: health)
                JarvisLog.log("update: running healthily for 30 s; \(ResumeState.healthFileName) written")
            } catch {
                JarvisLog.log("update: cannot write \(ResumeState.healthFileName) (\(error))")
            }
        }
    }

    /// The chat view reports its window (U1). A frame restored by a live update is applied
    /// once, on the next turn of the run loop, after SwiftUI's own placement, and only when it
    /// is still on a screen.
    func chatWindowAppeared(_ window: NSWindow) {
        chatWindow = window
        guard let frame = pendingFrame else { return }
        pendingFrame = nil
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        DispatchQueue.main.async { window.setFrame(frame, display: true) }
    }

    /// Builds the brain once, on the state this lock guards. The chat is connected only after
    /// `start()` has registered the built-in tools and started the MCP server, so no turn runs
    /// before that. `run/` and `claude-cwd/` are the plan's, under Application Support (§3.6,
    /// §3.7), with a suffix of their own for any root but the default one (`RunFolders`).
    private func startBrain(lock: InstanceLock, paths: StatePaths) {
        // One lease over the held lock for every writer of this root (D-36): the state store
        // and the app's one UsageStore, which everything that bumps is handed.
        let lease = InstanceLockLease(lock)
        let researchPaths = ResearchPaths(paths)
        let research = UsageStore(paths: researchPaths, lease: lease)
        let store: StateStore
        do {
            store = try StateStore(root: paths.root.path(percentEncoded: false), lease: lease)
        } catch {
            JarvisLog.log("cannot open the state store (\(error)) — chat is off.", category: .state)
            chat.startFailed(log: Self.abbreviate(paths.logFile))
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let folders = RunFolders(stateRoot: paths.root, defaultRoot: Self.defaultRoot(environment))
        JarvisLog.log("run folders: \(folders.run.lastPathComponent), \(folders.claudeWorkingDirectory.lastPathComponent)",
                      category: .brain)
        let config = ClaudeConfig(environment: environment)
        let core = CoreState(store: store, clock: SystemClock(), research: research, frontApp: WorkspaceFrontApp())
        let scheduler = AppResearch.scheduler(
            store: research, paths: researchPaths, here: paths.root, core: core,
            runtime: AppResearch.runtime(processStarted: Self.processStarted, claudeEnabled: config.enabled))
        scheduler.start(countingLaunch: Self.resumeAtLaunch == nil)   // U1: an update is not a start
        self.research = scheduler
        // The owner check a typed confirmation must pass (plan §3.4), counted as it runs.
        let authenticator = CountingTextAuthenticator(LAConfirmAuthenticator(), research: research)
        // Each finished typed reply goes to the user's speak policy (plan §3.12), and a yes
        // hands it to M8's voice: the F5 clone, or `say` while F5 is unavailable (D-54). Both
        // are local, so the policy's cloud rule does not hold back personal sources.
        let voice = AppVoice()
        self.voice = voice
        chat.onReplyFinished = { [weak self] message, turn in
            guard let self else { return }
            let context = SpeakReplies.context(for: message, turn: turn, toggle: self.speakReplies,
                                               chatWindowIsKey: self.chat.windowIsKey,
                                               userIdleSeconds: Self.userIdleSeconds(),
                                               ttsBackend: voice.backend)
            SpeakReplies.replyFinished(message, context: context, research: research,
                                       speaker: { text, turn in voice.speak(text, turn: turn.turnID) },
                                       log: { JarvisLog.log($0, category: .voice) })
        }
        // P2: the long-term memory in memory/, on the same lease-holding store. Local dates
        // follow the Mac's time zone as it changes.
        // P6: a first launch has no memory folder yet (looked at before anything writes). The
        // consent to learning from files is decided once: an install whose scanner has run
        // (memory/files-index.json) has given it; a new install starts with it off.
        let memoryFolderExists = FileManager.default.fileExists(
            atPath: paths.root.appending(path: "memory", directoryHint: .isDirectory).path(percentEncoded: false))
        fileLearning.resolve(filesIndexExists: FileManager.default.fileExists(atPath: store.path(.filesIndex)))
        let memory = MemoryStore(store: store, clock: SystemClock(), timeZone: .autoupdatingCurrent)
        // P6: before anything writes, an unreadable facts.json, personality.json or profile.json
        // is put back from its newest backup, and one that shrank is logged with both kept.
        memory.checkAtLaunch()
        // P3: the home folder is read in the background into the same facts; JARVIS's own state
        // root is never read. PDFKit and AppKit read pdf, docx and rtf here (D-13).
        let consent = fileLearning.shared
        let fileSetup = FileScanSetup(home: FileManager.default.homeDirectoryForCurrentUser, stateRoot: paths.root,
                                      store: store,
                                      extractors: TextExtractors([PlainTextExtractor(), DocumentTextExtractor()]),
                                      enabled: { consent.isOn })
        let assembly = BrainAssembly(
            core: core, research: research, config: config, environment: environment,
            runDirectory: folders.run, claudeWorkingDirectory: folders.claudeWorkingDirectory,
            memory: memory, files: fileSetup,
            // W1: JARVIS reads the web with WebKit on a private profile (never the Safari app),
            // and reads in the background only while he is not speaking.
            reader: WebReader(), waitForSilence: { [queue = voice.queue] in await queue.idle() },
            textAuthenticator: authenticator,
            // Python's is_online(): asked only when a turn reaches the brain.
            online: { await Net.isOnline() })
        brain = assembly
        // P1: the hourly consolidation check starts now (first pass in 120 s); the chat's
        // dismissals reach it through the coordinator once the brain has started. P2's fact
        // compile runs in the same dismissal task, so stopping the schedule stops it too.
        assembly.personality.start()
        personality = assembly.personality
        // P6: chats are compiled into memory after 30 idle minutes too, not only on a dismissal.
        assembly.idleCompile?.start()
        idleCompile = assembly.idleCompile
        webSummaries = assembly.webSummaries
        webSummaries?.kick()   // pages left unsummarised by the last run
        // P2: the facts' sentence vectors are computed in the background, not on the first turn.
        if let recall = assembly.recall {
            Task.detached(priority: .utility) {
                let n = recall.warm()
                JarvisLog.log("memory: \(n) fact vector(s) ready", category: .state)
                // W1 part 7c: the conversations and the journal are indexed before the first search.
                if let added = recall.index?.refresh() {
                    JarvisLog.log("memory: search index up to date (\(added) new entries)", category: .state)
                }
            }
        }
        Task { @MainActor in
            do {
                try await assembly.start()
            } catch {
                JarvisLog.log("cannot start the brain (\(error)) — chat is off.", category: .brain)
                self.chat.startFailed(log: Self.abbreviate(paths.logFile))
                return
            }
            self.chat.connect(assembly.coordinator, lastBackend: { await assembly.backend.last.name })
            self.chat.watchConfirmations(assembly.confirmations, authenticator: authenticator)
            // U1: a resumed build tells the update helper once it has run 30 s with its brain up.
            if let launch = Self.resumeAtLaunch { self.reportHealthy(launch.url, assembly: assembly) }
            // P6: on a first launch, JARVIS offers once to learn from the user's files.
            if self.fileLearning.takeFirstRunOffer(memoryFolderExists: memoryFolderExists) {
                self.chat.post(FileLearningConsent.firstRunOffer)
                JarvisLog.log("memory: offered to learn from the user's files (first launch)", category: .state)
            }
            // W1 part 5: the background reading starts once the brain has (a pass when one is due).
            if self.brain === assembly, let reading = assembly.backgroundReader {
                reading.start()
                self.reading = reading
            }
            // P3: the file scanner starts once the brain has (its first pass after 120 s).
            guard self.brain === assembly, let scanner = assembly.fileScanner else { return }
            scanner.start()
            self.files = scanner
        }
    }

    /// The menus' "Stop Speaking": the reply being spoken stops, and so does anything queued.
    func stopSpeaking() {
        voice?.stop()
    }

    #if DEBUG
    /// The DEBUG menu's "Test confirmation": stashes the harmless confirmation on the brain's
    /// gate, where the chat's card shows it. Its action only returns a fixed line.
    func stashTestConfirmation() {
        guard let brain else {
            JarvisLog.log("test confirmation: the brain has not started", category: .security)
            return
        }
        Task { await TestConfirmation.stash(on: brain.confirmations) }
    }
    #endif

    private func exitHeld(_ holder: String) -> Never {
        JarvisLog.log("Another JARVIS (\(holder)) holds .jarvis.lock — exiting.", category: .lock)
        exit(75)   // EX_TEMPFAIL
    }

    /// `kill -TERM` is the supported way to stop JARVIS from a script (no Apple Events, so no
    /// Automation prompt): log, release the lock, exit 0.
    private func installSIGTERMHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                JarvisLog.log("received SIGTERM — exiting.")
                self.updates.stop()
                self.research?.stop()   // flushes enqueued bumps while the lease is still held
                self.personality?.stop()   // no personality pass outlives the lease
                self.idleCompile?.stop()   // nor an idle compile
                self.webSummaries?.stop()   // nor a page summary (W1)
                self.reading?.stop()   // nor a background reading pass (W1)
                self.files?.cancel()   // no file read outlives the lease
                self.lock = nil
                exit(0)
            }
        }
        source.resume()
        sigterm = source
    }

    /// The root `StatePaths.live` picks without JARVIS_HOME (the repo around the app bundle), or
    /// nil when that is not a JARVIS repo.
    private static func defaultRoot(_ environment: [String: String]) -> URL? {
        var environment = environment
        environment["JARVIS_HOME"] = nil
        return try? StatePaths.live(environment: environment).root
    }

    /// When this process started, as unix time: the snapshot's `runtime.process_started`.
    private static let processStarted = Date().timeIntervalSince1970

    /// Seconds since the last keyboard, mouse or trackpad event in this login session.
    private static func userIdleSeconds() -> Double {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    /// "native 123" — the lock-file syntax, shared with the selftest report.
    nonisolated static func describe(_ holder: LockHolder?) -> String {
        switch holder {
        case .python(let pid): "python \(pid)"
        case .native(let pid): "native \(pid)"
        case .unknown(let text): "unknown: \(text)"
        case nil: "unknown"
        }
    }

    private static func describe(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "rawValue \(policy.rawValue)"
        }
    }

    /// "~/jarvis" — the menu and the selftest report never spell out the home directory.
    nonisolated static func abbreviate(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return (path as NSString).abbreviatingWithTildeInPath
    }
}
