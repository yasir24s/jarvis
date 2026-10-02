import Darwin
import Foundation
import Synchronization

/// A tiny HTTP/1.1 server on 127.0.0.1 for the reader's tests: it serves fixed responses by
/// path and records each request's path and Cookie header. Bound to the loopback address only,
/// so nothing leaves the machine. Stop it with `stop()`.
final class LoopbackServer: Sendable {
    struct Response: Sendable {
        var status = 200
        var type = "text/html; charset=utf-8"
        var body: Data
        var headers: [String] = []
        /// Seconds to wait before answering.
        var delay: Double = 0

        init(_ html: String, status: Int = 200, type: String = "text/html; charset=utf-8", headers: [String] = [],
             delay: Double = 0) {
            self.status = status
            self.type = type
            self.body = Data(html.utf8)
            self.headers = headers
            self.delay = delay
        }
    }

    struct Request: Sendable, Equatable {
        let path: String
        let cookie: String?
    }

    let port: UInt16
    private let socket: Int32
    private let routes: [String: Response]
    private let seen = Mutex<[Request]>([])
    private let stopped = Mutex(false)

    init(routes: [String: Response]) throws {
        self.routes = routes
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        socket = fd
        let server = self
        Thread.detachNewThread { server.acceptLoop() }
    }

    var requests: [Request] { seen.withLock { $0 } }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() {
        stopped.withLock { $0 = true }
        shutdown(socket, SHUT_RDWR)
        close(socket)
    }

    private func acceptLoop() {
        while !stopped.withLock({ $0 }) {
            let client = accept(socket, nil, nil)
            guard client >= 0 else { if stopped.withLock({ $0 }) { return } else { continue } }
            let server = self
            Thread.detachNewThread { server.serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { return }
            request.append(contentsOf: buffer[0..<n])
            if request.count > 1 << 16 { return }
        }
        let head = String(decoding: request, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let path = parts.count >= 2 ? String(parts[1]) : "/"
        let cookie = lines.first { $0.lowercased().hasPrefix("cookie:") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        seen.withLock { $0.append(Request(path: path, cookie: cookie)) }
        let response = routes[path] ?? Response("<html><body>Not here.</body></html>", status: 404)
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        var reply = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Other")\r\n"
        reply += "Content-Type: \(response.type)\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n"
        for header in response.headers { reply += header + "\r\n" }
        reply += "\r\n"
        let bytes = Data(reply.utf8) + response.body
        bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
