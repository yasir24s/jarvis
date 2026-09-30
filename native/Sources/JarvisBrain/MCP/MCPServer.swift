import Darwin
import Dispatch
import Foundation
import JarvisCore
import JarvisTools

/// The MCP tool server (plan §3.7). It listens on `run/mcp.sock`; `claude` reaches it through
/// the relay (`JARVIS --mcp-relay`). Each connection must pass the handshake, which binds it to
/// the TurnContext its token names; every `tools/call` then goes through the gateway with that
/// turn and `.model(.claude)`. Socket I/O runs on a private serial queue, bridged to this actor
/// with AsyncStream (§3.13).
public actor MCPServer {
    /// The handshake line must arrive within this long of the connection, and be at most
    /// `handshakeMaxBytes` long.
    public static let handshakeWindow: DispatchTimeInterval = .seconds(2)
    public static let handshakeMaxBytes = 4096
    /// Live connections, handshaking ones included (Codex review finding 2). A turn needs one
    /// relay, so 4 is headroom, and one past it is closed at accept, before any check or task.
    public static let maxConnections = 4

    public nonisolated let runDirectory: URL
    public nonisolated let socketPath: String

    private let registry: MCPTurnRegistry
    private let gateway: ToolGateway
    private let rpc: MCPJSONRPC
    private let log: @Sendable (String) -> Void
    /// The relay is this same binary, so a peer must be running this path.
    private let ownExecutablePath: String?
    private let queue = DispatchQueue(label: "com.jarvis.mcp.server")

    private var listener: DispatchSourceRead?
    private var connections: [Int: MCPConnection] = [:]
    private var nextConnection = 0
    private let admission = MCPAdmission(limit: MCPServer.maxConnections)

    /// Connections holding an admission slot: accepted and waiting for a serve task, or being
    /// served. Never more than `maxConnections`.
    nonisolated var liveConnections: Int { admission.live }

    /// Accepted descriptors no serve task has claimed yet; `stop()` closes them.
    nonisolated var unclaimedConnections: Int { admission.waiting }

    /// `tools` is what tools/list serves and what tools/call accepts: the Python catalog unless a
    /// test passes its own.
    public init(runDirectory: URL, registry: MCPTurnRegistry, gateway: ToolGateway,
                tools: [ToolSchema] = ToolCatalog.tools,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.runDirectory = runDirectory
        self.socketPath = MCPSocket.socketPath(in: runDirectory)
        self.registry = registry
        self.gateway = gateway
        self.rpc = MCPJSONRPC(tools: tools)
        self.log = log
        self.ownExecutablePath = MCPPeer.executablePath(of: getpid())
    }

    /// Prepares the run directory (0700), binds `mcp.sock` (0600) and starts accepting.
    public func start() throws {
        guard listener == nil else { return }
        try MCPSocket.prepareRunDirectory(runDirectory)
        let fd = try MCPSocket.listen(at: socketPath)
        admission.reopen()
        // Admission already holds the handoff to `maxConnections` tickets; the buffer bound makes
        // that explicit, and a ticket it will not take is closed rather than queued.
        let (accepted, continuation) = AsyncStream.makeStream(
            of: MCPAdmission.Ticket.self, bufferingPolicy: .bufferingOldest(Self.maxConnections))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let admission = admission
        let log = log
        source.setEventHandler {
            while let connection = MCPSocket.accept(fd) {
                let decision = admission.admit(connection)
                guard case .admitted(let ticket) = decision else {
                    log(Self.refusal(decision))
                    continue
                }
                if case .enqueued = continuation.yield(ticket) { continue }
                admission.discard(ticket)
            }
        }
        source.setCancelHandler {
            close(fd)
            continuation.finish()
        }
        listener = source
        source.resume()
        Task { [weak self] in
            for await ticket in accepted {
                guard let self else {
                    admission.discard(ticket)
                    continue
                }
                Task { await self.serve(ticket) }
            }
        }
        log("mcp: listening on \(socketPath)")
    }

    /// Stops accepting, removes the socket file and drops every connection.
    public func stop() {
        if let source = listener {
            listener = nil
            source.cancel()
            unlink(socketPath)
            log("mcp: stopped")
        }
        // Closes accepted descriptors no serve task has claimed; a serve task that starts later
        // finds nothing to claim and registers nothing.
        admission.stop()
        for connection in connections.values { connection.abort() }
        connections.removeAll()
    }

    /// Serves one connected socket until it closes: the handshake, then JSON-RPC. Tests hand it
    /// one end of a socketpair; accepted connections come in through `serve(_:)`. Takes
    /// ownership of `fd`. With `maxConnections` live, or after `stop()`, `fd` is closed at once
    /// and nothing is registered.
    public func serve(connection fd: Int32) async {
        let decision = admission.admit(fd)
        guard case .admitted(let ticket) = decision else {
            log(Self.refusal(decision))
            return
        }
        await serve(ticket)
    }

    /// Serves an admitted descriptor, once claimed. Nothing to claim means `stop()` ran first
    /// and has closed it.
    private func serve(_ ticket: MCPAdmission.Ticket) async {
        guard let fd = admission.claim(ticket) else { return }
        let peer = MCPPeer(connection: fd)
        let connection = MCPConnection(fd: fd, queue: queue, handshakeWindow: Self.handshakeWindow)
        let key = nextConnection
        nextConnection += 1
        connections[key] = connection
        defer {
            connections[key] = nil
            admission.release()
        }

        if let reason = peerProblem(peer) {
            reject(connection, reason)
            return
        }
        var lines = LineBuffer()
        var bound: MCPTurnRegistry.Binding?
        for await event in connection.events {
            switch event {
            case .deadline:
                if bound == nil {
                    reject(connection, "no handshake line within 2 s")
                    return
                }
            case .closed:
                if bound == nil { log("relay rejected: connection closed before the handshake") }
                connection.finish()
                return
            case .data(let data):
                lines.append(data)
                while true {
                    if let binding = bound {
                        guard let line = lines.nextLine() else { break }
                        if let reply = await respond(to: line, binding) { connection.send(reply) }
                        continue
                    }
                    guard let line = lines.nextLine() else {
                        if lines.pendingCount > Self.handshakeMaxBytes {
                            reject(connection, "handshake line over \(Self.handshakeMaxBytes) bytes")
                            return
                        }
                        break
                    }
                    guard line.count <= Self.handshakeMaxBytes else {
                        reject(connection, "handshake line over \(Self.handshakeMaxBytes) bytes")
                        return
                    }
                    switch await handshake(line, peer: peer) {
                    case .rejected(let reason):
                        reject(connection, reason)
                        return
                    case .bound(let binding):
                        bound = binding
                        connection.send(#"{"jarvis_relay_ok":1}"#)
                        log("mcp: relay bound to turn \(binding.turnID)")
                    }
                }
            }
        }
    }

    // MARK: - Handshake

    /// The peer-credential checks, in plan order: same uid, a peer pid, and this executable.
    private func peerProblem(_ peer: MCPPeer) -> String? {
        guard let uid = peer.uid else { return "getpeereid failed" }
        guard uid == getuid() else { return "peer uid \(uid) is not ours" }
        guard let pid = peer.pid else { return "LOCAL_PEERPID failed" }
        guard let path = peer.executablePath, let own = ownExecutablePath else {
            return "no executable path for pid \(pid)"
        }
        guard path == own else { return "pid \(pid) runs \(path), not this app" }
        return nil
    }

    /// `{"jarvis_relay":1,"token":"<hex>"}` naming an open turn whose claude is the peer's parent.
    private func handshake(_ line: [UInt8], peer: MCPPeer) async -> MCPTurnRegistry.Claim {
        guard let hello = (try? PyJSON.loads(Data(line)))?.objectValue,
              hello["jarvis_relay"] == .int(1),
              let token = hello["token"]?.stringValue else {
            return .rejected("malformed handshake line")
        }
        let claim = await registry.claim(token: Array(token.utf8), parentPID: peer.parentPID)
        if case .bound(let binding) = claim, !(await binding.turn.isOpen) {
            return .rejected("turn \(binding.turnID) is closed")
        }
        return claim
    }

    private func reject(_ connection: MCPConnection, _ reason: String) {
        log("relay rejected: \(reason)")
        connection.abort()
    }

    /// The log line for a descriptor admission has closed.
    private static func refusal(_ decision: MCPAdmission.Decision) -> String {
        decision == .stopped ? "mcp: connection closed: the server has stopped"
            : "mcp: connection refused: \(maxConnections) already live"
    }

    // MARK: - JSON-RPC

    /// The reply line for one request line, or nil for a notification.
    private func respond(to line: [UInt8], _ binding: MCPTurnRegistry.Binding) async -> String? {
        let turn = binding.turn
        switch MCPJSONRPC.parse(line) {
        case .invalid(let error):
            return MCPJSONRPC.encode(error)
        case .notification(let method):
            log("mcp: notification \(method)")
            return nil
        case .request(let id, let method, let params):
            guard await turn.isOpen, await registry.isOpen(binding.turnID) else {
                return MCPJSONRPC.encode(MCPJSONRPC.turnClosed(id: id))
            }
            switch rpc.action(method: method, id: id, params: params) {
            case .reply(let reply):
                return MCPJSONRPC.encode(reply)
            case .callTool(let name, let arguments):
                let result = await gateway.call(name, arguments, turn: turn, origin: .model(.claude))
                return MCPJSONRPC.encode(MCPJSONRPC.toolResult(id: id, result))
            }
        }
    }
}
