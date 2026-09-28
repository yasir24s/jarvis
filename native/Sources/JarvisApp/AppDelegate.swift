import AppKit
import Observation
import JarvisCore

/// What the menu shows. Written only by AppDelegate, on the main actor.
@MainActor
@Observable
final class AppModel {
    var stateRoot = "—"
    var lockHolder = "—"
}

/// App lifecycle (plan: M00 §3.9, §3.5). Startup order: accessory policy → state root →
/// logging → banner → policy read-back → lock → (from M1) subsystems. Nothing reads or writes
/// state before the lock is held.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var lock: InstanceLock?
    private var sigterm: DispatchSourceSignal?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Agent app from the first instant (LSUIElement also says so); main thread by isolation.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-assert: Python's lesson (jarvis.py:5431-5433) is that a UI layer can flip the
        // policy back to Regular after launch. M4/M13 re-assert after showing any window.
        NSApplication.shared.setActivationPolicy(.accessory)
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
        if policy == .accessory {
            JarvisLog.log("activation policy: accessory")
        } else {
            JarvisLog.log("activation policy: \(Self.describe(policy)) (expected accessory)")
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

    func applicationWillTerminate(_ notification: Notification) {
        JarvisLog.log("Quit JARVIS — exiting.")
        lock = nil   // closes the fd: releases the flock before exit
    }

    private func lockAcquired(_ held: InstanceLock, paths: StatePaths) {
        lock = held
        model.lockHolder = Self.describe(InstanceLock.readHolder(at: paths.lockFile))
    }

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
