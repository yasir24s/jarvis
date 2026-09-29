import Darwin
import Dispatch
import Foundation

/// One connected socket (plan §3.13). All of its I/O runs on the server's private serial queue
/// through a DispatchIO channel; what arrives reaches the server actor through `events`.
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

    /// Takes ownership of `fd`: it is closed when the channel lets go of it.
    init(fd: Int32, queue: DispatchQueue, handshakeWindow: DispatchTimeInterval) {
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        self.events = events
        self.queue = queue
        channel = DispatchIO(type: .stream, fileDescriptor: fd, queue: queue) { _ in
            close(fd)
            continuation.yield(.closed)
            continuation.finish()
        }
        channel.setLimit(lowWater: 1)
        channel.read(offset: 0, length: Int.max, queue: queue) { done, data, _ in
            if let data, !data.isEmpty { continuation.yield(.data(Data(data))) }
            if done { continuation.yield(.closed) }
        }
        queue.asyncAfter(deadline: .now() + handshakeWindow) { continuation.yield(.deadline) }
    }

    /// Queues `line` and a newline behind any earlier writes. A failed write drops the connection.
    func send(_ line: String) {
        var bytes = Array(line.utf8)
        bytes.append(0x0A)
        let data = bytes.withUnsafeBytes { DispatchData(bytes: $0) }
        channel.write(offset: 0, data: data, queue: queue) { [channel] done, _, error in
            if done, error != 0 { channel.close(flags: .stop) }
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
