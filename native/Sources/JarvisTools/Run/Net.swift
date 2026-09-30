import Foundation
import Network

/// Shared network helpers (M05–M06 §3.4), independent of the app lifecycle.
public enum Net {
    /// A connector must finish within `timeout` seconds and close its connection.
    public typealias Connector = @Sendable (_ host: String, _ port: UInt16, _ timeout: TimeInterval) async -> Bool

    /// Matches Python's is_online: try the two numeric hosts in order, without DNS.
    /// Reachability of these endpoints does not guarantee the Claude service is available.
    public static func isOnline() async -> Bool {
        await isOnline { host, port, timeout in
            await connect(NetworkProbe(host: host, port: port), timeout: timeout)
        }
    }

    /// Injection point for offline tests and callers with their own transport.
    public static func isOnline(connector: Connector) async -> Bool {
        for host in ["1.1.1.1", "8.8.8.8"] {
            guard !Task.isCancelled else { return false }
            let connected = await connector(host, 53, 1.2)
            guard !Task.isCancelled else { return false }
            if connected { return true }
        }
        return false
    }

    // Tests inject a transport here to exercise the real timeout/cancellation bridge.
    static func connect(_ connection: any NetProbeConnection, timeout: TimeInterval) async -> Bool {
        await ConnectionAttempt(connection: connection, timeout: timeout).run()
    }
}

/// Implementations deliver completion on `queue`; duplicate callbacks are tolerated.
protocol NetProbeConnection: Sendable {
    func start(queue: DispatchQueue, completion: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

private struct NetworkProbe: NetProbeConnection {
    let connection: NWConnection

    init(host: String, port: UInt16) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start(queue: DispatchQueue, completion: @escaping @Sendable (Bool) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: completion(true)
            case .failed, .waiting, .cancelled: completion(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

/// All mutable state is confined to `queue`, including cancellation before start.
private final class ConnectionAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.jarvis.net.probe")
    private let connection: any NetProbeConnection
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Bool, Never>?
    private var deadline: DispatchWorkItem?
    private var result: Bool?

    init(connection: any NetProbeConnection, timeout: TimeInterval) {
        self.connection = connection
        self.timeout = timeout
    }

    func run() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    if let result {
                        continuation.resume(returning: result)
                        return
                    }
                    self.continuation = continuation
                    let deadline = DispatchWorkItem { [weak self] in self?.finish(false) }
                    self.deadline = deadline
                    queue.asyncAfter(deadline: .now() + timeout, execute: deadline)
                    connection.start(queue: queue) { [self] connected in
                        finish(connected)
                    }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(false) }
        }
    }

    private func finish(_ connected: Bool) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard result == nil else { return }
        result = connected
        deadline?.cancel()
        deadline = nil
        connection.cancel()
        continuation?.resume(returning: connected)
        continuation = nil
    }
}
