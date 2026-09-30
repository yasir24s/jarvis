import AppKit
import Observation
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools

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
    private var lock: InstanceLock?
    /// Built once the lock is held and kept for the app's life (plan: M02-M04 §3.5, §3.12).
    private var brain: BrainAssembly?
    private var sigterm: DispatchSourceSignal?
    /// Opens the chat window. Set by the window each time it appears, for the Dock icon.
    var openChat: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A regular app with a Dock icon (D-43); main thread by isolation.
        // M13's HUD is a non-activating NSPanel and must never change this policy.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSIGTERMHandler()

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
    /// is done.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let brain else { return .terminateNow }
        self.brain = nil
        Task { @MainActor in
            await brain.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        JarvisLog.log("Quit JARVIS — exiting.")
        lock = nil   // closes the fd: releases the flock before exit
    }

    private func lockAcquired(_ held: InstanceLock, paths: StatePaths) {
        lock = held
        model.lockHolder = Self.describe(InstanceLock.readHolder(at: paths.lockFile))
        startBrain(lock: held, paths: paths)
    }

    /// Builds the brain once, on the state this lock guards. The chat is connected only after
    /// `start()` has registered the built-in tools and started the MCP server, so no turn runs
    /// before that. `run/` and `claude-cwd/` are the plan's, under Application Support (§3.6,
    /// §3.7).
    private func startBrain(lock: InstanceLock, paths: StatePaths) {
        let research = UsageStore(paths: ResearchPaths(paths))
        let store: StateStore
        do {
            store = try StateStore(root: paths.root.path(percentEncoded: false), lease: InstanceLockLease(lock))
        } catch {
            JarvisLog.log("cannot open the state store (\(error)) — chat is off.", category: .state)
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let support = BrainAssembly.supportDirectory
        // The owner check a typed confirmation must pass (plan §3.4), counted as it runs.
        let authenticator = CountingTextAuthenticator(LAConfirmAuthenticator(), research: research)
        // Each finished typed reply goes to the user's speak policy (plan §3.12). No speaker
        // exists before M8, so nothing is spoken yet.
        chat.onReplyFinished = { [weak self] message, turn in
            guard let self else { return }
            let context = SpeakReplies.context(for: message, turn: turn, toggle: self.speakReplies,
                                               chatWindowIsKey: self.chat.windowIsKey,
                                               userIdleSeconds: Self.userIdleSeconds())
            SpeakReplies.replyFinished(message, context: context, research: research, speaker: nil,
                                       log: { JarvisLog.log($0, category: .voice) })
        }
        let assembly = BrainAssembly(
            core: CoreState(store: store, clock: SystemClock(), research: research, frontApp: WorkspaceFrontApp()),
            research: research, config: ClaudeConfig(environment: environment), environment: environment,
            runDirectory: support.appending(path: "run", directoryHint: .isDirectory),
            claudeWorkingDirectory: support.appending(path: "claude-cwd", directoryHint: .isDirectory),
            textAuthenticator: authenticator,
            // Python's is_online(): asked only when a turn reaches the brain.
            online: { await Net.isOnline() })
        brain = assembly
        Task { @MainActor in
            do {
                try await assembly.start()
            } catch {
                JarvisLog.log("cannot start the brain (\(error)) — chat is off.", category: .brain)
                return
            }
            self.chat.connect(assembly.coordinator, lastBackend: { await assembly.backend.last.name })
            self.chat.watchConfirmations(assembly.confirmations, authenticator: authenticator)
        }
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
                self.lock = nil
                exit(0)
            }
        }
        source.resume()
        sigterm = source
    }

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
