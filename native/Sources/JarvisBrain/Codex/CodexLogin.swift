import Foundation
import JarvisCore

/// B2 part 6: whether JARVIS's own Codex home is signed in to ChatGPT.
public enum CodexLoginStatus: Sendable, Equatable {
    case signedIn
    case signedOut
    /// The check could not run (no `codex`, or it could not start).
    case unavailable(String)
}

/// How a "Sign in to ChatGPT…" ended.
public enum CodexSignInResult: Sendable, Equatable {
    case signedIn
    case failed(String)
    case cancelled
}

/// What the menus' "Sign in to ChatGPT…" item drives. Tests pass a fake.
public protocol ChatGPTSignInRunning: Sendable {
    func status() async -> CodexLoginStatus
    /// Runs the sign-in to its end; cancelling the calling task stops it.
    func signIn() async -> CodexSignInResult
}

/// B2 part 6: `codex login` and `codex login status` under JARVIS's own Codex home. The user
/// signs in in the browser, with the OAuth flow `codex login` opens; codex keeps the result in
/// that home. JARVIS never sees a credential: it reads only the exit status and whether the
/// status output says "Logged in using ChatGPT", and it never logs either command's output (the
/// sign-in's holds its authorization link, and the status of an API-key login holds part of the
/// key).
public struct CodexLogin: ChatGPTSignInRunning {
    /// `codex login status` under the home.
    public static let statusArguments = ["login", "status"] + CodexInvocation.pinnedSignIn
    /// `codex login`: the browser OAuth flow, not `--with-api-key`, `--with-access-token` or
    /// `--device-auth`.
    public static let signInArguments = ["login"] + CodexInvocation.pinnedSignIn
    /// How long a sign-in may wait for the browser before it is stopped.
    public static let signInTimeout: Duration = .seconds(600)
    public static let statusTimeout: Duration = .seconds(20)
    /// What `codex login status` prints for a ChatGPT sign-in.
    public static let signedInLine = "Logged in using ChatGPT"

    public let executable: URL?
    public let codexHome: URL
    public let parentEnvironment: [String: String]
    public let signInTimeout: Duration

    /// - Parameters:
    ///   - executable: the `codex` CLI (`BrainAssembly.locateCodex`); nil when there is none.
    ///   - codexHome: JARVIS's own Codex home (`CodexHome.directory`); both commands run in it, so
    ///     codex never looks for project configuration in a folder of the user's.
    public init(executable: URL?, codexHome: URL = CodexHome.directory,
                parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                signInTimeout: Duration = CodexLogin.signInTimeout) {
        self.executable = executable
        self.codexHome = codexHome
        self.parentEnvironment = parentEnvironment
        self.signInTimeout = signInTimeout
    }

    /// Signed in only for exit status 0 with "Logged in using ChatGPT" in the output; an API key,
    /// an access token or any other login counts as signed out.
    public static func parseStatus(exit: Int32, output: String) -> CodexLoginStatus {
        exit == 0 && Py.contains(output, signedInLine) ? .signedIn : .signedOut
    }

    public func status() async -> CodexLoginStatus {
        switch await run(Self.statusArguments, timeout: Self.statusTimeout) {
        case .finished(let exit, let output): Self.parseStatus(exit: exit, output: output)
        case .refused(let why): .unavailable(why)
        case .timedOut: .unavailable("codex login status timed out")
        case .cancelled: .unavailable("cancelled")
        }
    }

    public func signIn() async -> CodexSignInResult {
        switch await run(Self.signInArguments, timeout: signInTimeout) {
        case .finished(let exit, _):
            if exit != 0 { return .failed("codex login exited \(exit)") }
            return await status() == .signedIn ? .signedIn : .failed("codex login finished, but not signed in")
        case .refused(let why): return .failed(why)
        case .timedOut: return .failed("the browser sign-in did not finish within \(Int(signInTimeout / .seconds(1))) s")
        case .cancelled: return .cancelled
        }
    }

    enum Outcome: Sendable {
        case finished(exit: Int32, output: String)
        case refused(String)
        case timedOut
        case cancelled
    }

    /// Runs `codex <arguments>` in the Codex home with `forCodex`'s env, reading its output to the
    /// end, and stops it (SIGTERM, then SIGKILL) on the timeout or when the calling task is
    /// cancelled.
    func run(_ arguments: [String], timeout: Duration) async -> Outcome {
        guard let executable else { return .refused("Codex CLI not found") }
        let environment = ChildEnvironment.forCodex(parent: parentEnvironment, codexHome: codexHome, log: { _ in })
        if let why = CodexHome.refusal(codexHome, userHome: environment["HOME"] ?? NSHomeDirectory()) {
            return .refused("codex home: \(why)")
        }
        do {
            try CodexHome.prepare(codexHome)
        } catch {
            return .refused("codex home: \(error)")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = codexHome
        let output = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let (ended, signal) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { signal.yield($0.terminationStatus); signal.finish() }
        let collected = OutputBox()
        do {
            try process.run()
        } catch {
            return .refused(CodexDriver.launchError(error) == CodexLocator.notFoundMessage
                            ? "Codex CLI not found" : "cannot start codex: \(error.localizedDescription)")
        }
        let reader = Thread {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            collected.set(String(decoding: data, as: UTF8.self))
        }
        reader.start()
        let pid = process.processIdentifier
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { collected.markTimedOut(); Self.stop(pid) }
        }
        let exit: Int32 = await withTaskCancellationHandler {
            var status: Int32 = -1
            for await s in ended { status = s }
            return status
        } onCancel: {
            collected.markCancelled()
            Self.stop(pid)
        }
        timer.cancel()
        withExtendedLifetime(process) {}
        if collected.cancelled { return .cancelled }
        if collected.timedOut { return .timedOut }
        return .finished(exit: exit, output: collected.waitForText())
    }

    /// SIGTERM, then SIGKILL two seconds later if it is still there.
    private static func stop(_ pid: pid_t) {
        _ = kill(pid, SIGTERM)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
    }
}

/// The output read off the reader thread, and why the run was stopped.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSCondition()
    private var text: String?
    private var stoppedForTime = false
    private var stoppedByCaller = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedForTime
    }

    var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedByCaller
    }

    func set(_ value: String) {
        lock.lock()
        text = value
        lock.broadcast()
        lock.unlock()
    }

    /// The whole output, once the pipe has closed (at most 5 s after the process ended).
    func waitForText() -> String {
        lock.lock()
        defer { lock.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while text == nil && lock.wait(until: deadline) {}
        return text ?? ""
    }

    func markTimedOut() {
        lock.lock()
        stoppedForTime = true
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        stoppedByCaller = true
        lock.unlock()
    }
}
