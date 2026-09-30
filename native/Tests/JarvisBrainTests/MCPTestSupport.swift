import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Synchronization
import Testing

// Shared by MCPServerTests, MCPTurnRegistryTests and RelayTests. Blocking reads run on a
// Dispatch global queue, never on the test's own task, so parallel tests cannot starve the
// cooperative pool the server needs.

/// A short directory under /tmp: sun_path must stay under 104 bytes, and the usual temp
/// directory (/var/folders/...) plus a sandbox name can exceed that.
final class ShortTempDir: Sendable {
    let url: URL
    var path: String { url.path(percentEncoded: false) }

    init() throws {
        var template = Array("/tmp/jmcp.XXXXXX".utf8CString)
        guard let made = template.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress) }) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        url = URL(fileURLWithPath: String(cString: made), isDirectory: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Log lines the server writes, in order. The global JarvisLog is never touched.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }

    /// Waits up to `seconds` of awake time for a line containing `text`. The deadline is on the
    /// suspending clock, so a Mac asleep with its lid closed does not use the wait up.
    func waitFor(_ text: String, seconds: Double = 5) async -> Bool {
        let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
        while SuspendingClock.now < deadline {
            if all.contains(where: { $0.contains(text) }) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return all.contains(where: { $0.contains(text) })
    }
}

/// One end of a socket or pipe, read line by line off the cooperative pool.
final class TestEnd: Sendable {
    let fd: Int32
    private let buffer = Mutex<[UInt8]>([])

    init(fd: Int32) {
        self.fd = fd
    }

    func close() {
        Darwin.close(fd)
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return }
            written += n
        }
    }

    /// The next line without its newline, or nil on EOF or timeout.
    func line(seconds: Double = 5) async -> String? {
        await offPool { self.blockingLine(seconds: seconds) }
    }

    /// True when the other side closes (EOF) within `seconds`; bytes read meanwhile are kept.
    func closed(seconds: Double = 5) async -> Bool {
        await offPool { self.blockingEOF(seconds: seconds) }
    }

    private func blockingLine(seconds: Double) -> String? {
        buffer.withLock { bytes in
            let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
            while true {
                if let end = bytes.firstIndex(of: 0x0A) {
                    let line = Array(bytes[..<end])
                    bytes.removeSubrange(...end)
                    return String(decoding: line, as: UTF8.self)
                }
                guard let chunk = readChunk(until: deadline), !chunk.isEmpty else { return nil }
                bytes.append(contentsOf: chunk)
            }
        }
    }

    private func blockingEOF(seconds: Double) -> Bool {
        buffer.withLock { bytes in
            let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
            while true {
                guard let chunk = readChunk(until: deadline) else { return false }
                if chunk.isEmpty { return true }
                bytes.append(contentsOf: chunk)
            }
        }
    }

    /// Bytes read before `deadline`: empty at EOF (or on a read error), nil on timeout. The
    /// deadline is awake time, on the suspending clock, so a closed lid does not use it up.
    private func readChunk(until deadline: SuspendingClock.Instant) -> [UInt8]? {
        while true {
            let ms = Int32(max(0, SuspendingClock.now.duration(to: deadline) / .milliseconds(1)))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, ms)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            return n > 0 ? Array(chunk[..<n]) : []
        }
    }
}

func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

/// Polls `condition` every 20 ms for up to `seconds` of awake time. The deadline is on the
/// suspending clock, so a Mac asleep with its lid closed does not use the wait up.
func eventually(seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
    while SuspendingClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}

/// A connected AF_UNIX stream pair, both ends close-on-exec with SO_NOSIGPIPE.
func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try MCPSocket.configure(fds[0])
    try MCPSocket.configure(fds[1])
    return (fds[0], fds[1])
}

/// (read end, write end).
func pipePair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard pipe(&fds) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return (fds[0], fds[1])
}

/// A server in a short temp directory, with its own gateway, registry and log.
struct MCPHarness {
    let dir: ShortTempDir
    let registry: MCPTurnRegistry
    let gateway: ToolGateway
    let server: MCPServer
    let logs = LogLines()

    init(tools: [ToolSchema] = ToolCatalog.tools, gateway: ToolGateway = ToolGateway(confirmationGate: ConfirmationGate())) throws {
        dir = try ShortTempDir()
        let run = dir.url.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        registry = MCPTurnRegistry(runDirectory: run, relayCommand: "/opt/jarvis-test/JARVIS")
        self.gateway = gateway
        server = MCPServer(runDirectory: run, registry: registry, gateway: gateway, tools: tools, log: logs.sink)
    }

    /// Opens a turn whose "claude" is this process's parent: in tests both ends of the socket
    /// are this process, so the relay's parent pid is getppid().
    func openTurn(_ turn: TurnContext = TurnContext(channel: .text), claudePID: Int32 = getppid())
        async throws -> (turn: TurnContext, files: MCPTurnFiles, token: String) {
        let files = try await registry.openTurn(turn)
        await registry.setClaudePID(claudePID, for: files.turnID)
        let token = try #require(MCPRelay.readToken(at: files.tokenPath.path(percentEncoded: false)))
        return (turn, files, token)
    }

    /// One end of a socketpair whose other end the server is serving.
    func connect() throws -> TestEnd {
        let (served, ours) = try socketPair()
        let server = server
        Task { await server.serve(connection: served) }
        return TestEnd(fd: ours)
    }

    /// Connects and sends the handshake; returns the socket once the OK line has arrived.
    func bound(token: String) async throws -> TestEnd {
        let end = try connect()
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        let ok = await end.line()
        try #require(ok == #"{"jarvis_relay_ok":1}"#, "handshake reply: \(ok ?? "nil"); log: \(logs.all)")
        return end
    }

    func remove() async {
        await server.stop()
        dir.remove()
    }
}

/// Parses a JSON line, or fails the test.
func json(_ line: String?) throws -> JSONValue {
    let line = try #require(line)
    return try PyJSON.loads(Data(line.utf8))
}

/// Key-order normalization: every object's members sorted by key, recursively.
func sortedKeys(_ value: JSONValue) -> JSONValue {
    switch value {
    case .array(let items): .array(items.map(sortedKeys))
    case .object(let object):
        .object(JSONObject(object.members.sorted { $0.key < $1.key }
            .map { JSONObject.Member(key: $0.key, value: sortedKeys($0.value)) }))
    default: value
    }
}
