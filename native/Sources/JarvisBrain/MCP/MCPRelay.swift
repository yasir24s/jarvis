import Darwin
import Dispatch
import Foundation
import JarvisCore
import Synchronization

/// The relay's work (plan §3.7 "Relay mode"), on file descriptors so tests can drive it
/// in-process with pipes and a socketpair. `RelayMain` in the app wires it to stdin/stdout.
/// Nothing here parses MCP traffic or writes anything but that traffic to `output`;
/// diagnostics go to `diagnostics`, and never include the token.
public enum MCPRelay {
    /// How long the relay waits for `{"jarvis_relay_ok":1}`, in milliseconds.
    public static let handshakeTimeoutMS: Int32 = 2000
    /// Bytes read from one side and not yet written to the other (Codex review finding 1). MCP
    /// lines are KBs and the server closes at 4 MiB of unread replies, so a side this far
    /// behind is stuck, and the relay exits 1 instead of holding more.
    public static let maxBacklogBytes = 4 << 20

    /// Reads the token file (no symlinks, at most 4 KB), trimmed. Nil if it cannot be read or is empty.
    public static func readToken(at path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var count = 0
        while count < buffer.count {
            let n = buffer[count...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            count += n
        }
        let token = String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Connects to `socketPath`, handshakes with the token read from `tokenFile`, then pumps.
    /// Returns the exit status: 0 after EOF on either side, 1 if anything before the pump fails.
    public static func main(socketPath: String, tokenFile: String, input: Int32, output: Int32,
                            diagnostics: Int32 = STDERR_FILENO) -> Int32 {
        guard let token = readToken(at: tokenFile) else {
            say("cannot read the token file", to: diagnostics)
            return 1
        }
        let socket: Int32
        do {
            socket = try MCPSocket.connect(to: socketPath)
        } catch {
            say("cannot connect: \(error)", to: diagnostics)
            return 1
        }
        defer { close(socket) }
        return run(socket: socket, token: token, input: input, output: output, diagnostics: diagnostics)
    }

    /// Sends `{"jarvis_relay":1,"token":"<hex>"}`, waits up to 2 s for `{"jarvis_relay_ok":1}`,
    /// then pumps. Returns 1 on handshake failure, else what `pump` returns.
    public static func run(socket: Int32, token: String, input: Int32, output: Int32,
                           diagnostics: Int32 = STDERR_FILENO) -> Int32 {
        let hello = #"{"jarvis_relay":1,"token":"# + PyJSON.dumps(.string(token)) + "}\n"
        guard writeAll(socket, Array(hello.utf8)) else {
            say("handshake failed: cannot write to the socket", to: diagnostics)
            return 1
        }
        let reply: (line: [UInt8], rest: [UInt8])
        switch readLine(socket, timeoutMS: handshakeTimeoutMS, limit: 4096) {
        case .line(let line, let rest): reply = (line, rest)
        case .failed(let why):
            say("handshake failed: \(why)", to: diagnostics)
            return 1
        }
        guard let ok = (try? PyJSON.loads(Data(reply.line)))?.objectValue, ok["jarvis_relay_ok"] == .int(1) else {
            say("handshake failed: unexpected reply", to: diagnostics)
            return 1
        }
        if !reply.rest.isEmpty, !writeAll(output, reply.rest) { return 1 }
        return pump(input: input, output: output, socket: socket, diagnostics: diagnostics)
    }

    /// Copies input to socket and socket to output, through a DispatchIO channel per
    /// descriptor, until either side reaches EOF; what is already queued for the other side
    /// is written first. Returns 0 after EOF, 1 after a read or write error or once more than
    /// `maxBacklogBytes` wait for one side (said on `diagnostics`). The descriptors stay open;
    /// the caller owns them.
    public static func pump(input: Int32, output: Int32, socket: Int32,
                            diagnostics: Int32 = STDERR_FILENO) -> Int32 {
        pumpReport(input: input, output: output, socket: socket, backlogLimit: maxBacklogBytes,
                   diagnostics: diagnostics).status
    }

    /// `pump` with its backlog limit given, reporting the most bytes each direction ever held:
    /// `[to the socket, to the output]`.
    static func pumpReport(input: Int32, output: Int32, socket: Int32, backlogLimit: Int,
                           diagnostics: Int32) -> (status: Int32, peakBacklog: [Int]) {
        let queue = DispatchQueue(label: "com.jarvis.mcp.relay")
        let released = DispatchGroup()
        let finished = DispatchSemaphore(value: 0)
        let state = PumpState(finished: finished)

        func channel(_ fd: Int32) -> DispatchIO {
            released.enter()
            let io = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in released.leave() }
            io.setLimit(lowWater: 1)
            return io
        }
        let fromInput = channel(input)
        let throughSocket = channel(socket)
        let toOutput = channel(output)

        func forward(_ source: DispatchIO, to sink: DispatchIO, direction: Int) {
            source.read(offset: 0, length: Int.max, queue: queue) { done, data, error in
                if let data, !data.isEmpty {
                    let count = data.count
                    guard state.queued(direction, bytes: count, limit: backlogLimit) else {
                        if state.finish(1) {
                            say("over \(backlogLimit) bytes waiting for \(direction == 0 ? "the app" : "claude")",
                                to: diagnostics)
                        }
                        return
                    }
                    sink.write(offset: 0, data: data, queue: queue) { writeDone, _, writeError in
                        guard writeDone else { return }
                        if writeError != 0 { state.finish(1) } else { state.written(direction, bytes: count) }
                    }
                }
                if done {
                    if error == 0 { state.reachedEOF(direction) } else { state.finish(1) }
                }
            }
        }
        forward(fromInput, to: throughSocket, direction: 0)
        forward(throughSocket, to: toOutput, direction: 1)

        finished.wait()
        for io in [fromInput, throughSocket, toOutput] { io.close(flags: .stop) }
        released.wait()
        return (state.status, state.peaks)
    }

    // MARK: - Pieces

    enum LineRead {
        case line([UInt8], rest: [UInt8])
        case failed(String)
    }

    /// Reads up to the first newline within `timeoutMS`, keeping any bytes after it.
    static func readLine(_ fd: Int32, timeoutMS: Int32, limit: Int) -> LineRead {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMS) * 1_000_000
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let end = bytes.firstIndex(of: 0x0A) {
                return .line(Array(bytes[..<end]), rest: Array(bytes[(end + 1)...]))
            }
            guard bytes.count <= limit else { return .failed("reply longer than \(limit) bytes") }
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .failed("no reply within \(timeoutMS) ms") }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, Int32(clamping: (deadline - now + 999_999) / 1_000_000))
            if ready < 0, errno == EINTR { continue }
            guard ready >= 0 else { return .failed("poll: \(String(cString: strerror(errno)))") }
            guard ready > 0 else { continue }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return .failed(n == 0 ? "server closed the connection" : "read failed") }
            bytes.append(contentsOf: chunk[..<n])
        }
    }

    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            written += n
        }
        return true
    }

    static func say(_ message: String, to fd: Int32) {
        _ = writeAll(fd, Array("JARVIS relay: \(message)\n".utf8))
    }
}

/// Bookkeeping for `pump`: writes still queued per direction and the bytes they hold, which
/// directions reached EOF, and the first outcome. The first outcome signals `finished`,
/// exactly once.
private final class PumpState: Sendable {
    private struct Counts {
        var queued = [0, 0]
        var bytes = [0, 0]
        var peak = [0, 0]
        var eof = [false, false]
        var status: Int32?
    }

    private let counts = Mutex(Counts())
    private let finished: DispatchSemaphore

    init(finished: DispatchSemaphore) {
        self.finished = finished
    }

    var status: Int32 { counts.withLock { $0.status ?? 0 } }
    var peaks: [Int] { counts.withLock { $0.peak } }

    /// Counts a write of `bytes` one way. False, with nothing counted, when that would put
    /// more than `limit` bytes in flight that way.
    func queued(_ direction: Int, bytes: Int, limit: Int) -> Bool {
        counts.withLock { c -> Bool in
            guard c.bytes[direction] + bytes <= limit else { return false }
            c.queued[direction] += 1
            c.bytes[direction] += bytes
            c.peak[direction] = max(c.peak[direction], c.bytes[direction])
            return true
        }
    }

    func written(_ direction: Int, bytes: Int) {
        let drained = counts.withLock { c -> Bool in
            c.queued[direction] -= 1
            c.bytes[direction] -= bytes
            return c.eof[direction] && c.queued[direction] == 0
        }
        if drained { finish(0) }
    }

    func reachedEOF(_ direction: Int) {
        let drained = counts.withLock { c -> Bool in
            c.eof[direction] = true
            return c.queued[direction] == 0
        }
        if drained { finish(0) }
    }

    /// True for the first outcome only.
    @discardableResult
    func finish(_ status: Int32) -> Bool {
        let first = counts.withLock { c -> Bool in
            guard c.status == nil else { return false }
            c.status = status
            return true
        }
        if first { finished.signal() }
        return first
    }
}
