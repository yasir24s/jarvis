import Darwin
import Synchronization

/// The MCP server's admission slots (Codex review finding 2). A connection holds a slot from
/// accept until its serve task ends, handshaking ones included, and one past `limit` is closed
/// as it is accepted. An accepted descriptor waits here, under a ticket, until its serve task
/// claims it, so `stop()` can close the ones no task has claimed yet. Accept runs on the I/O
/// queue and serve tasks on the server actor, hence the lock.
final class MCPAdmission: Sendable {
    /// One accepted descriptor waiting for its serve task.
    struct Ticket: Hashable, Sendable {
        fileprivate let number: UInt64
    }

    enum Decision: Equatable, Sendable {
        case admitted(Ticket)
        /// The descriptor was closed: `limit` connections are live.
        case full
        /// The descriptor was closed: the server has stopped.
        case stopped
    }

    private struct State {
        var live = 0
        var waiting: [Ticket: Int32] = [:]
        var nextTicket: UInt64 = 0
        var stopped = false
    }

    let limit: Int
    private let state = Mutex(State())

    init(limit: Int) {
        self.limit = limit
    }

    /// Connections holding a slot: waiting for a serve task, or being served.
    var live: Int { state.withLock { $0.live } }

    /// Accepted descriptors no serve task has claimed yet.
    var waiting: Int { state.withLock { $0.waiting.count } }

    /// Takes a slot for `fd`, or closes `fd` at once.
    func admit(_ fd: Int32) -> Decision {
        let decision = state.withLock { (s: inout State) -> Decision in
            if s.stopped { return .stopped }
            guard s.live < limit else { return .full }
            let ticket = Ticket(number: s.nextTicket)
            s.nextTicket += 1
            s.live += 1
            s.waiting[ticket] = fd
            return .admitted(ticket)
        }
        if case .admitted = decision { return decision }
        close(fd)
        return decision
    }

    /// Hands the descriptor over to its serve task, which then owns it and calls `release()`
    /// when done. Nil when `stop()` has already closed it.
    func claim(_ ticket: Ticket) -> Int32? {
        state.withLock { $0.waiting.removeValue(forKey: ticket) }
    }

    /// Closes a descriptor that never reached a serve task and frees its slot.
    func discard(_ ticket: Ticket) {
        guard let fd = claim(ticket) else { return }
        release()
        close(fd)
    }

    /// A served connection has ended.
    func release() {
        state.withLock { $0.live -= 1 }
    }

    /// Refuses everything from now on and closes the descriptors no serve task has claimed.
    /// Connections being served keep their slots until their tasks end.
    func stop() {
        let unclaimed = state.withLock { (s: inout State) -> [Int32] in
            s.stopped = true
            let fds = Array(s.waiting.values)
            s.waiting.removeAll()
            s.live -= fds.count
            return fds
        }
        for fd in unclaimed { close(fd) }
    }

    /// Admits again after `stop()`.
    func reopen() {
        state.withLock { $0.stopped = false }
    }
}
