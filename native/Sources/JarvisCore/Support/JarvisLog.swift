import Foundation
import Synchronization
import os

// Native equivalent of Python's install_logging()/log() (plan: M00 §3.9, jarvis.py:504-517).
// File sink: the shared logs/jarvis.log, line format identical to Python ("[JARVIS] <msg>",
// no timestamp) so `jarvisctl status`/`logs` keep working; eras are separated by the native
// banner. Every line also goes to the unified log (subsystem com.jarvis.assistant) as
// private data — transcripts and tool output must not become public there.

public enum LogCategory: String, Sendable, CaseIterable {
    case app, lock, state, brain, tools, voice, research, security
}

public enum JarvisLog {
    private struct Sink {
        var fd: Int32 = -1
        var mirrorToStdout = false
    }

    private static let sink = Mutex(Sink())
    private static let loggers: [LogCategory: Logger] = Dictionary(
        uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: "com.jarvis.assistant", category: $0.rawValue))
        })

    /// Opens `file` for appending (O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC, 0o666 before umask —
    /// Python's open(LOG_FILE, "a")), creating its parent directory like install_logging does.
    /// Call once, before the lock. A later call replaces the sink; `nil` means unified log only.
    /// Like Python's install_logging, a file that cannot be opened is silently skipped.
    public static func configure(file: URL?, mirrorToStdout: Bool) {
        var fd: Int32 = -1
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            fd = open(file.path(percentEncoded: false), O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o666)
        }
        sink.withLock { s in
            if s.fd >= 0 { close(s.fd) }
            s.fd = fd
            s.mirrorToStdout = mirrorToStdout
        }
    }

    /// Python's log(msg): file (and stdout if mirrored) get "[JARVIS] <message>\n" in one
    /// write(2); the unified log gets the message under `category`.
    public static func log(_ message: String, category: LogCategory = .app) {
        loggers[category]!.notice("\(message, privacy: .private)")
        emit("[JARVIS] " + message + "\n")
    }

    /// The start banner, print()-ed by Python as "\n===== JARVIS starting … =====".
    /// Native says "(native)" so the two eras are distinguishable in the shared log.
    /// Takes the instant directly: no JarvisClock exists yet (M00 §3.6 and M01 disagree on
    /// its shape), so this stays clock-agnostic until that is settled.
    public static func banner(now: Date = Date(), timeZone: TimeZone = .current) {
        let stamp = PyTime.strftime("%Y-%m-%d %H:%M:%S", now, timeZone: timeZone)
        let text = "===== JARVIS (native) starting \(stamp) ====="
        loggers[.app]!.notice("\(text, privacy: .private)")
        emit("\n" + text + "\n")
    }

    /// Swift strings are always valid Unicode, so their UTF-8 needs no repair: Python's
    /// errors="replace" is satisfied by construction.
    private static func emit(_ line: String) {
        let bytes = Array(line.utf8)
        sink.withLock { s in
            if s.fd >= 0 { writeAll(s.fd, bytes) }
            if s.mirrorToStdout { writeAll(STDOUT_FILENO, bytes) }
        }
    }

    /// One write(2) per line; retried only on EINTR or a short write. Errors are swallowed,
    /// like Python's _Tee.
    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    return
                }
                off += n
            }
        }
    }
}
