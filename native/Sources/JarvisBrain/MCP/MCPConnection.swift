import Darwin
import Dispatch
import Foundation
import Synchronization

/// One connected socket (plan §3.13). All of its I/O runs on the server's private serial queue
/// through a DispatchIO channel; what arrives reaches the server actor through `events`.
///
/// Both directions have a byte budget (Codex review finding 1): bytes read and not yet taken
/// by the server count against `inboundLimit`, reply bytes not yet written against
/// `outboundLimit`. A connection that would pass either is closed, not grown, and `overrun`
/// says why.
final class MCPConnection: Sendable {
    enum Event: Sendable {
        case data(Data)
        /// The handshake window has passed. Ignored once the handshake is done.
        case deadline
        /// EOF, a read error, or the channel was closed.
        case closed
    }

    let events: AsyncStream<Event>
    private let channel: DispatchIO
    private let queue: DispatchQueue
    private let budget: ByteBudget
    private let outboundLimit: Int

    /// Takes ownership of `fd`: it is closed when the channel lets go of it.
    init(fd: Int32, queue: DispatchQueue, handshakeWindow: DispatchTimeInterval,
         inboundLimit: Int, outboundLimit: Int) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        let budget = ByteBudget()
        let channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            close(fd)
            continuation.yield(.closed)
            continuation.finish()
        }
        self.events = events
        self.queue = queue
        self.budget = budget
        self.outboundLimit = outboundLimit
        self.channel = channel
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty {
                guard budget.read(data.count, limit: inboundLimit) else {
                    channel.close(flags: .stop)
                    return
                }
                continuation.yield(.data(Data(data)))
            }
            if done { continuation.yield(.closed) }
        }
        queue.asyncAfter(deadline: .now() + handshakeWindow) { continuation.yield(.deadline) }
    }

    /// Why the connection was closed for its byte budget, if it was.
    var overrun: String? { budget.overrun }

    /// The most bytes ever read and not yet taken, and ever queued and not yet written.
    var peaks: (inbound: Int, outbound: Int) { budget.peaks }

    /// The server has taken `count` bytes of `.data` off `events`.
    func took(_ count: Int) {
        budget.took(count)
    }

    /// Queues `line` and a newline behind any earlier writes. A failed write drops the
    /// connection, and so does a line that would put more than `outboundLimit` bytes in flight.
    func send(_ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        let count = bytes.count
        guard budget.queue(count, limit: outboundLimit) else {
            channel.close(flags: .stop)
            return
        }
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { [channel, budget] done, _, error in
            guard done else { return }
            budget.wrote(count)
            if error != 0 { channel.close(flags: .stop) }
        }
    }

    /// Stops all I/O at once; queued writes are dropped.
    func abort() {
        channel.close(flags: .stop)
    }

    /// For after EOF: queued writes finish, then the descriptor is closed.
    func finish() {
        channel.close()
    }
}

/// One connection's bytes in flight each way, with their high-water marks. The read and write
/// handlers run on the I/O queue and the server on its actor, hence the lock.
private final class ByteBudget: Sendable {
    private struct Counts {
        var inbound = 0
        var outbound = 0
        var peakInbound = 0
        var peakOutbound = 0
        var overrun: String?
    }

    private let counts = Mutex(Counts())

    var overrun: String? { counts.withLock { $0.overrun } }
    var peaks: (inbound: Int, outbound: Int) { counts.withLock { ($0.peakInbound, $0.peakOutbound) } }

    /// Counts `count` bytes just read. False, with the overrun recorded, past `limit`.
    func read(_ count: Int, limit: Int) -> Bool {
        counts.withLock { (c: inout Counts) -> Bool in
            guard c.overrun == nil else { return false }
            guard c.inbound + count <= limit else {
                c.overrun = "over \(limit) bytes read and not yet handled"
                return false
            }
            c.inbound += count
            c.peakInbound = max(c.peakInbound, c.inbound)
            return true
        }
    }

    func took(_ count: Int) {
        counts.withLock { $0.inbound -= count }
    }

    /// Counts `count` bytes about to be written. False, with the overrun recorded, past `limit`.
    func queue(_ count: Int, limit: Int) -> Bool {
        counts.withLock { (c: inout Counts) -> Bool in
            guard c.overrun == nil else { return false }
            guard c.outbound + count <= limit else {
                c.overrun = "over \(limit) bytes of replies not yet read"
                return false
            }
            c.outbound += count
            c.peakOutbound = max(c.peakOutbound, c.outbound)
            return true
        }
    }

    func wrote(_ count: Int) {
        counts.withLock { $0.outbound -= count }
    }
}

/// Splits a byte stream into newline-terminated lines. The newline is not part of the line.
struct LineBuffer {
    private var bytes: [UInt8] = []
    private var scanned = 0

    /// Bytes waiting for their newline.
    var pendingCount: Int { bytes.count }

    mutating func append(_ data: Data) {
        bytes.append(contentsOf: data)
    }

    mutating func nextLine() -> [UInt8]? {
        guard let end = bytes[scanned...].firstIndex(of: 0x0A) else {
            scanned = bytes.count
            return nil
        }
        let line = Array(bytes[..<end])
        bytes.removeSubrange(...end)
        scanned = 0
        return line
    }
}
