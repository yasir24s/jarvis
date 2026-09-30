import Synchronization

/// One served connection as `MCPTurnRegistry.closeTurn` sees it (Codex review finding 3): the
/// connection, to close, and its serve task, to cancel. The registry keeps the handle of the
/// connection a turn is bound to. A revoke that comes before either is attached is applied as
/// soon as it is.
final class MCPServeHandle: Sendable {
    private struct State {
        var connection: MCPConnection?
        var task: Task<Void, Never>?
        var revoked = false
    }

    private let state = Mutex(State())

    /// True once `revoke()` has run.
    var isRevoked: Bool { state.withLock { $0.revoked } }

    func attach(_ task: Task<Void, Never>) {
        let revoked = state.withLock { (s: inout State) -> Bool in
            s.task = task
            return s.revoked
        }
        if revoked { task.cancel() }
    }

    func attach(_ connection: MCPConnection) {
        let revoked = state.withLock { (s: inout State) -> Bool in
            s.connection = connection
            return s.revoked
        }
        if revoked { connection.abort() }
    }

    /// Closes the connection and cancels its serve task.
    func revoke() {
        let (connection, task) = state.withLock { (s: inout State) -> (MCPConnection?, Task<Void, Never>?) in
            s.revoked = true
            return (s.connection, s.task)
        }
        connection?.abort()
        task?.cancel()
    }
}
