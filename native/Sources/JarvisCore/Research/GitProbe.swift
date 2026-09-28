import Foundation
import Synchronization

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
    /// captured, stderr discarded, killed with SIGKILL at the deadline (Python's
    /// `subprocess.run` timeout does `kill()` then raises).
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
        let output = Mutex<Data?>(nil)
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = reader.readDataToEndOfFile()
            output.withLock { $0 = data }
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            exited.wait()
            return nil
        }
        drained.wait()
        guard let data = output.withLock({ $0 }) else { return nil }
        return String(validating: data, as: UTF8.self)
    }
}
