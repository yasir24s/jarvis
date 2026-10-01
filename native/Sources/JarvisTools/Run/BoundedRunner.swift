import Darwin
import Foundation

/// What a bounded child run produced (plan: M05-M06 §3.4 ShellRunner). `status` is the exit
/// code, or minus the signal number when the child was killed. `timedOut` and `truncated`
/// mean the runner killed the child's process group: at the deadline, or when a stream went
/// past its byte cap. Output read before the kill is kept.
struct ProcessOutput: Sendable, Equatable {
    var stdout: Data
    var stderr: Data
    var status: Int32
    var timedOut: Bool
    var truncated: Bool
    /// Set when the spawn itself failed with this errno (E2BIG for an oversized argv); the
    /// streams are then empty. Python raises `OSError` for it before any output.
    var launchErrno: Int32? = nil

    /// The run finished by itself (no timeout, no cap), as `subprocess.run` would return.
    var completed: Bool { !timedOut && !truncated && launchErrno == nil }

    static func launchFailed(_ code: Int32) -> ProcessOutput {
        ProcessOutput(stdout: Data(), stderr: Data(), status: -1, timedOut: false, truncated: false, launchErrno: code)
    }
}

/// Runs a child process with a deadline. Tools depend on this, never on `Process`, so tests
/// inject a fake that returns canned output and records the argv.
protocol CommandRunning: Sendable {
    /// `argv[0]` is an absolute path. Nil when the child could not be started for a reason
    /// with no errno; a spawn that failed with one returns `launchErrno` instead.
    func run(_ argv: [String], timeout: Double) async -> ProcessOutput?
}

protocol StdinCommandRunning: CommandRunning {
    func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput?
}

/// The real runner. Prior art: `GitProbe.run` (poll-based drain, process-group kill) and
/// `Net` (cancellation bridge). Differences: stdout and stderr are drained together, each is
/// capped at `cap` bytes, the blocking work runs on a dispatch thread rather than a
/// cooperative one, and cancelling the calling task kills the child.
struct BoundedRunner: StdinCommandRunning {
    /// The largest stream the runner keeps (4 MiB, the MCP connection limit). Every tool
    /// trims its reply far below this; the cap only bounds memory for a runaway child.
    static let defaultCap = 4 << 20
    /// The PATH Python's LaunchAgent gives every child (plan: M05-M06 §3.4), so `run_command`
    /// and the blueutil lookup find what Python finds; an app started outside launchd's
    /// agent has only the system directories.
    static let agentPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    /// The app environment with `agentPATH`, for the M5 action runners.
    static func agentEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["PATH"] = agentPATH
        return environment
    }
    /// The child environment. Nil inherits the app's, as Python's `subprocess.run` does.
    var environment: [String: String]? = nil
    var cap: Int = BoundedRunner.defaultCap

    func run(_ argv: [String], timeout: Double) async -> ProcessOutput? {
        await run(argv, input: Data(), timeout: timeout)
    }

    func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput? {
        let handle = ChildHandle()
        let (environment, cap) = (environment, cap)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ProcessOutput?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: Self.runBlocking(argv, timeout: timeout, cap: cap,
                                                                    environment: environment, handle: handle,
                                                                    input: input))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// The pid of the running child, shared with the cancellation handler.
    final class ChildHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t = 0
        private var cancelled = false

        /// Records the child. Returns false when the task was cancelled before the spawn,
        /// in which case the caller kills the child at once.
        func started(_ pid: pid_t) -> Bool {
            lock.withLock {
                self.pid = pid
                return !cancelled
            }
        }

        func cancel() {
            let pid = lock.withLock { () -> pid_t in
                cancelled = true
                return self.pid
            }
            if pid > 1 { BoundedRunner.killGroup(pid) }
        }

        var isCancelled: Bool { lock.withLock { cancelled } }
    }

    static func killGroup(_ pid: pid_t) {
        // Foundation's Process makes the child a process-group leader, so this also reaches
        // grandchildren that inherited the pipes (GitProbe's reasoning).
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    static func runBlocking(_ argv: [String], timeout: Double, cap: Int,
                            environment: [String: String]?, handle: ChildHandle,
                            input: Data = Data()) -> ProcessOutput? {
        guard let path = argv.first, path.hasPrefix("/"), !handle.isCancelled else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdin = Pipe()
        process.standardInput = input.isEmpty ? FileHandle.nullDevice : stdin.fileHandleForReading
        defer {
            try? stdin.fileHandleForReading.close()
            try? stdin.fileHandleForWriting.close()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            return .launchFailed(Int32(error.code))
        } catch {
            return nil
        }
        let pid = process.processIdentifier
        try? stdin.fileHandleForReading.close()
        let writer = stdin.fileHandleForWriting.fileDescriptor
        var inputOffset = 0
        var inputOpen = !input.isEmpty
        if inputOpen {
            _ = fcntl(writer, F_SETFL, fcntl(writer, F_GETFL) | O_NONBLOCK)
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)
        } else { try? stdin.fileHandleForWriting.close() }
        // Process closes the parent's copies of the write ends after the spawn (GitProbe
        // relies on the same), so EOF arrives when the child and its heirs close theirs.
        let readers = [out.fileHandleForReading, err.fileHandleForReading]
        defer { readers.forEach { try? $0.close() } }
        if !handle.started(pid) { killGroup(pid) }

        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(max(0, timeout) * 1e9)
        var streams = [Data(), Data()]
        var open = [true, true]
        var timedOut = false, truncated = false
        for fd in readers.map(\.fileDescriptor) {
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        drain: while open.contains(true) || inputOpen {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { timedOut = true; break }
            if handle.isCancelled { break }
            let millis = Int32(min(UInt64(250), (deadline - now + 999_999) / 1_000_000))
            var fds = readers.indices.filter { open[$0] }.map {
                pollfd(fd: readers[$0].fileDescriptor, events: Int16(POLLIN), revents: 0)
            }
            if inputOpen { fds.append(pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)) }
            let ready = poll(&fds, nfds_t(fds.count), millis)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for entry in fds where entry.revents != 0 {
                if entry.fd == writer {
                    let count = input.withUnsafeBytes { bytes in
                        Darwin.write(writer, bytes.baseAddress!.advanced(by: inputOffset),
                                     min(65_536, input.count - inputOffset))
                    }
                    if count > 0 { inputOffset += count }
                    if inputOffset == input.count || (count < 0 && errno != EAGAIN && errno != EINTR) {
                        try? stdin.fileHandleForWriting.close()
                        inputOpen = false
                    }
                    continue
                }
                guard let i = readers.firstIndex(where: { $0.fileDescriptor == entry.fd }) else { continue }
                while true {
                    let count = Darwin.read(entry.fd, &buffer, buffer.count)
                    if count > 0 {
                        let room = cap - streams[i].count
                        streams[i].append(contentsOf: buffer.prefix(min(count, max(0, room))))
                        if count > room { truncated = true; break drain }
                        continue
                    }
                    if count == 0 { open[i] = false }
                    else if errno != EAGAIN && errno != EINTR { open[i] = false }
                    break
                }
            }
        }
        let killed = timedOut || truncated || handle.isCancelled
        if killed { killGroup(pid) }
        // Never waitUntilExit (its run-loop wait can hang on task threads): wait for the
        // termination handler, bounded by the deadline, or one second after a kill.
        let limit = killed ? DispatchTime.now() + 1 : DispatchTime(uptimeNanoseconds: deadline)
        if exited.wait(timeout: limit) == .timedOut {
            killGroup(pid)
            timedOut = !truncated
            _ = exited.wait(timeout: .now() + 1)
        }
        let status = process.isRunning ? -SIGKILL
            : (process.terminationReason == .uncaughtSignal ? -process.terminationStatus : process.terminationStatus)
        return ProcessOutput(stdout: streams[0], stderr: streams[1], status: status,
                             timedOut: timedOut, truncated: truncated)
    }
}
