import Darwin
import Foundation

// The git half of research_snapshot (jarvis.py 2481–2487, plan: M01b §2.2, §3.2):
//     head    = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"],
//                              capture_output=True, text=True, timeout=5).stdout.strip()
//     commits = subprocess.run(["git", "-C", HERE, "rev-list", "--count", "HEAD"], …).stdout.strip()
//     any exception → head, commits = "", ""
// The exit status is ignored: a non-repo or an empty repo gives empty stdout, hence "".
// Only a launch failure, a timeout, or undecodable output (UnicodeDecodeError under
// text=True) is an exception, and it blanks BOTH fields. `git_commits` stays a string.

public enum GitProbe {
    /// Runs one git command: `arguments` is the full argv as Python passes it (starting with
    /// "git"). Returns stdout decoded as UTF-8, or nil for what Python raises on (launch
    /// failure, timeout, invalid UTF-8).
    public typealias Runner = @Sendable (_ arguments: [String], _ timeout: Double) -> String?

    public static func headAndCommits(repo: URL, timeout: Double = 5) -> (head: String, commits: String) {
        headAndCommits(repo: repo, timeout: timeout, run: run)
    }

    public static func headAndCommits(repo: URL, timeout: Double,
                                      run: Runner) -> (head: String, commits: String) {
        var here = repo.path(percentEncoded: false)
        while here.count > 1 && here.hasSuffix("/") { here.removeLast() }
        guard let head = run(["git", "-C", here, "rev-parse", "--short", "HEAD"], timeout),
              let commits = run(["git", "-C", here, "rev-list", "--count", "HEAD"], timeout) else {
            return ("", "")
        }
        return (PyStr.strip(head), PyStr.strip(commits))
    }

    /// The real runner: `/usr/bin/env <arguments>` (PATH lookup, like Python's execvp), stdout
    /// captured, stderr discarded. The deadline covers both child exit and pipe EOF.
    /// A timeout kills the child's process group, including inherited pipe writers.
    public static let run: Runner = { arguments, timeout in
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return nil }
        let reader = pipe.fileHandleForReading
        defer { try? reader.close() }
        let deadline = DispatchTime.now() + timeout

        func fail() -> String? {
            // Foundation Process launches a new process group. The leader may already
            // have exited while one of its children still owns stdout's write end.
            let pid = p.processIdentifier
            if pid > 1 {
                kill(-pid, SIGKILL)
                if p.isRunning { kill(pid, SIGKILL) }
            }
            // Never use waitUntilExit here: its run-loop wait can hang on task threads.
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }

        // Drain on this thread with bounded, nonblocking reads. A background
        // readDataToEndOfFile could remain stuck even after its caller timed out.
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return fail() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return fail() }
            let remaining = deadline.uptimeNanoseconds - now
            let millis = Int32(min(UInt64(Int32.max), (remaining + 999_999) / 1_000_000))
            var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&event, 1, millis)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, event.revents & Int16(POLLNVAL | POLLERR) == 0 else { return fail() }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break } // POLLHUP still allows buffered bytes to be read first.
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return fail()
            }
            output.append(contentsOf: buffer.prefix(count))
        }
        guard exited.wait(timeout: deadline) == .success else { return fail() }
        return String(validating: output, as: UTF8.self)
    }
}
