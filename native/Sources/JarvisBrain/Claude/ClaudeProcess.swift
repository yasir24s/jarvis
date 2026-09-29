import Foundation

// The pieces of one `claude` run that touch the OS (plan: M02-M04 §3.6, run loop): the
// signals the driver's loop waits on, stdout cut into lines, stderr kept in an 8 KB ring,
// and the signals that stop the child.

/// Everything the driver's loop waits on. The stdout and stderr readers, the timers and the
/// process's termination handler all feed one stream, so the loop sees them in arrival order.
enum ClaudeSignal: Sendable {
    case line(String)
    case stdoutClosed
    case stderrClosed(tail: [UInt8])
    case exited(ClaudeExit)
    case timedOut
    case cancelled
    /// The stop sequence's 2 s wait is over.
    case stopDeadline
}

/// How the child ended. `code` is the exit status, or minus the signal number for a child
/// killed by a signal (how Python's `returncode` reports it).
struct ClaudeExit: Sendable, Equatable {
    let code: Int32

    init(_ process: Process) {
        let status = process.terminationStatus
        code = process.terminationReason == .uncaughtSignal ? -status : status
    }
}

/// The last `capacity` bytes appended.
struct ByteRing: Sendable {
    let capacity: Int
    private var storage: [UInt8] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ byte: UInt8) {
        guard storage.count == capacity else {
            storage.append(byte)
            return
        }
        storage[head] = byte
        head = (head + 1) % capacity
    }

    /// Oldest first.
    var bytes: [UInt8] {
        Array(storage[head...] + storage[..<head])
    }
}

enum ClaudeStreams {
    /// The stderr ring's size (plan §3.6).
    static let stderrCapacity = 8192

    // Each pipe is read by its own thread with blocking read(2). `FileHandle.bytes` is not
    // used: it runs every read in the process one at a time, so an idle stderr read held
    // stdout's lines back until the child exited (observed 2026-09-29: a line written at once
    // arrived after 3.01 s instead of 0.11 s). Its `.lines` also breaks at U+0085, U+2028 and
    // U+2029, which a JSON string may hold raw, and drops empty lines.

    /// Yields each line of `handle` without its "\n" (only "\n" ends a line), then an
    /// unterminated last line if there is one, then `.stdoutClosed`.
    static func startLineReader(_ handle: FileHandle, into signals: AsyncStream<ClaudeSignal>.Continuation) {
        startThread(name: "claude stdout") {
            var line: [UInt8] = []
            readToEOF(handle) { chunk in
                var rest = chunk[...]
                while let newline = rest.firstIndex(of: 0x0A) {
                    line.append(contentsOf: rest[..<newline])
                    signals.yield(.line(String(decoding: line, as: UTF8.self)))
                    line.removeAll(keepingCapacity: true)
                    rest = rest[(newline + 1)...]
                }
                line.append(contentsOf: rest)
            }
            if !line.isEmpty {
                signals.yield(.line(String(decoding: line, as: UTF8.self)))
            }
            signals.yield(.stdoutClosed)
        }
    }

    /// Keeps the last `stderrCapacity` bytes of `handle` and yields them at EOF.
    static func startTailReader(_ handle: FileHandle, into signals: AsyncStream<ClaudeSignal>.Continuation) {
        startThread(name: "claude stderr") {
            var ring = ByteRing(capacity: stderrCapacity)
            readToEOF(handle) { chunk in
                for byte in chunk { ring.append(byte) }
            }
            signals.yield(.stderrClosed(tail: ring.bytes))
        }
    }

    /// Blocking reads until EOF, or an error other than EINTR (which ends the stream like
    /// EOF; R10 then reports the exit). `handle` owns the descriptor, so it is kept alive.
    private static func readToEOF(_ handle: FileHandle, _ body: (ArraySlice<UInt8>) -> Void) {
        withExtendedLifetime(handle) {
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if n > 0 {
                    body(buffer[..<n])
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private static func startThread(name: String, _ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.name = name
        thread.start()
    }
}

/// Sends stop signals to a started child. Foundation's `Process` makes the child the leader
/// of its own process group (observed 2026-09-29), so the signal goes to the whole group and
/// anything the child started (the MCP relay, a script's `sleep`) stops with it. If the
/// child is not a group leader, only its pid is signalled.
struct ClaudeChild: Sendable {
    let pid: pid_t
    let isGroupLeader: Bool

    init(pid: pid_t) {
        self.pid = pid
        isGroupLeader = getpgid(pid) == pid
    }

    func send(_ signal: Int32) {
        _ = kill(isGroupLeader ? -pid : pid, signal)
    }
}
