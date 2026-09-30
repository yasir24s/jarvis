import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// The relay (plan §3.7 "Relay mode"), driven in-process: pipes stand in for claude's stdin and
/// stdout, and a socketpair (or the real socket) for the app. The app binary is never launched.
@Suite("RelayTests")
struct RelayTests {
    /// Exactly `count` bytes from `fd`, or nil on EOF or after `seconds` of awake time (the
    /// suspending clock, so a Mac asleep with its lid closed does not use the wait up).
    static func read(_ fd: Int32, count: Int, seconds: Double = 5) async -> [UInt8]? {
        await offPool {
            let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
            var bytes: [UInt8] = []
            while bytes.count < count {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ms = Int32(max(0, SuspendingClock.now.duration(to: deadline) / .milliseconds(1)))
                guard poll(&pfd, 1, ms) > 0 else { return nil }
                var chunk = [UInt8](repeating: 0, count: count - bytes.count)
                let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                guard n > 0 else { return nil }
                bytes += chunk[..<n]
            }
            return bytes
        }
    }

    /// True if nothing can be read from `fd` within `ms`.
    static func silent(_ fd: Int32, ms: Int32 = 200) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pfd, 1, ms) == 0
    }

    static func isOpen(_ fd: Int32) -> Bool { fcntl(fd, F_GETFD) != -1 }

    static func write(_ fd: Int32, _ bytes: [UInt8]) {
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { return }
            written += n
        }
    }

    /// Claude's side of the relay's stdio, and the relay's end of the app socket.
    struct Plumbing {
        let stdinRead: Int32, stdinWrite: Int32
        let stdoutRead: Int32, stdoutWrite: Int32
        let stderrRead: Int32, stderrWrite: Int32

        init() throws {
            (stdinRead, stdinWrite) = try pipePair()
            (stdoutRead, stdoutWrite) = try pipePair()
            (stderrRead, stderrWrite) = try pipePair()
        }

        func closeAll() {
            for fd in [stdinRead, stdinWrite, stdoutRead, stdoutWrite, stderrRead, stderrWrite] { close(fd) }
        }

        /// What the relay wrote to its diagnostics pipe so far.
        func diagnostics() -> String {
            var text = ""
            while !RelayTests.silent(stderrRead, ms: 50) {
                var chunk = [UInt8](repeating: 0, count: 4096)
                let n = chunk.withUnsafeMutableBytes { Darwin.read(stderrRead, $0.baseAddress, $0.count) }
                guard n > 0 else { break }
                text += String(decoding: chunk[..<n], as: UTF8.self)
            }
            return text
        }
    }

    // MARK: - The pump

    @Test func pumpCopiesBytesBothWaysAndExitsOnStdinEOF() async throws {
        let p = try Plumbing()
        let (relaySocket, app) = try socketPair()
        let pumping = Task { await offPool { MCPRelay.pump(input: p.stdinRead, output: p.stdoutWrite, socket: relaySocket) } }

        let up: [UInt8] = Array(#"{"method":"initialize","jsonrpc":"2.0","id":0}"#.utf8) + [0x0A, 0x00, 0xFF, 0xC3]
        Self.write(p.stdinWrite, up)
        #expect(await Self.read(app, count: up.count) == up)
        let down: [UInt8] = Array((0...255).map(UInt8.init)) + Array("\n".utf8)
        Self.write(app, down)
        #expect(await Self.read(p.stdoutRead, count: down.count) == down)
        // A reply larger than any socket or pipe buffer arrives whole and in order.
        let big = (0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        async let received = Self.read(p.stdoutRead, count: big.count, seconds: 10)
        await offPool { Self.write(app, big) }
        #expect(await received == big)

        close(p.stdinWrite)   // claude closed the relay's stdin
        #expect(await pumping.value == 0)
        #expect(Self.silent(app) && Self.silent(p.stdoutRead), "the pump wrote something of its own")
        #expect(Self.isOpen(relaySocket) && Self.isOpen(p.stdinRead) && Self.isOpen(p.stdoutWrite))
        close(relaySocket)
        close(app)
        for fd in [p.stdinRead, p.stdoutRead, p.stdoutWrite, p.stderrRead, p.stderrWrite] { close(fd) }
    }

    @Test func pumpDrainsWhatTheAppSentThenExitsOnSocketEOF() async throws {
        let p = try Plumbing()
        let (relaySocket, app) = try socketPair()
        let pumping = Task { await offPool { MCPRelay.pump(input: p.stdinRead, output: p.stdoutWrite, socket: relaySocket) } }
        let last = Array(#"{"jsonrpc": "2.0", "id": 9, "result": {}}"#.utf8) + [0x0A]
        Self.write(app, last)
        close(app)   // the app side went away right after its last reply
        #expect(await pumping.value == 0)
        #expect(await Self.read(p.stdoutRead, count: last.count) == last)
        close(relaySocket)
        p.closeAll()
    }

    // MARK: - Handshake

    @Test func aRejectedHandshakeExitsOneAndWritesNothingToStdout() async throws {
        let h = try MCPHarness()
        _ = try await h.openTurn()
        let p = try Plumbing()
        let (served, relaySocket) = try socketPair()
        let server = h.server
        Task { await server.serve(connection: served) }
        let wrong = String(repeating: "0", count: 64)
        let status = await offPool {
            MCPRelay.run(socket: relaySocket, token: wrong, input: p.stdinRead, output: p.stdoutWrite,
                         diagnostics: p.stderrWrite)
        }
        #expect(status == 1)
        #expect(await h.logs.waitFor("relay rejected: unknown token"))
        #expect(Self.silent(p.stdoutRead))
        let diagnostics = p.diagnostics()
        #expect(diagnostics.contains("handshake failed: server closed the connection"), "\(diagnostics)")
        #expect(!diagnostics.contains(wrong))
        close(relaySocket)
        p.closeAll()
        await h.remove()
    }

    @Test func aSilentOrWrongReplyExitsOne() async throws {
        let p = try Plumbing()
        let (relaySocket, app) = try socketPair()
        // Awake time only, like the relay's 2 s handshake deadline (DispatchTime uptime, which
        // does not count system sleep): a closed lid cannot push `waited` past 5 s.
        let start = SuspendingClock.now
        let status = await offPool {
            MCPRelay.run(socket: relaySocket, token: "abc", input: p.stdinRead, output: p.stdoutWrite,
                         diagnostics: p.stderrWrite)
        }
        let waited = SuspendingClock.now - start
        #expect(status == 1)
        #expect(waited >= .milliseconds(1900) && waited < .seconds(5), "gave up after \(waited)")
        #expect(p.diagnostics().contains("handshake failed: no reply within 2000 ms"))
        // The relay sent exactly the handshake line, token included, and nothing else.
        let hello = Array(#"{"jarvis_relay":1,"token":"abc"}"#.utf8) + [0x0A]
        #expect(await Self.read(app, count: hello.count) == hello)
        #expect(Self.silent(app))
        close(relaySocket)
        close(app)

        let (relaySocket2, app2) = try socketPair()
        Self.write(app2, Array(#"{"jarvis_relay_ok":0}"#.utf8) + [0x0A])
        let status2 = await offPool {
            MCPRelay.run(socket: relaySocket2, token: "abc", input: p.stdinRead, output: p.stdoutWrite,
                         diagnostics: p.stderrWrite)
        }
        #expect(status2 == 1)
        #expect(p.diagnostics().contains("handshake failed: unexpected reply"))
        #expect(Self.silent(p.stdoutRead))
        close(relaySocket2)
        close(app2)
        p.closeAll()
    }

    // MARK: - End to end, in-process

    @Test func relayAndServerCarryAToolsListExchange() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        let p = try Plumbing()
        let (served, relaySocket) = try socketPair()
        let server = h.server
        Task { await server.serve(connection: served) }
        let relaying = Task {
            await offPool {
                MCPRelay.run(socket: relaySocket, token: token, input: p.stdinRead, output: p.stdoutWrite,
                             diagnostics: p.stderrWrite)
            }
        }
        let stdout = TestEnd(fd: p.stdoutRead)
        Self.write(p.stdinWrite, Array(#"{"method":"tools/list","jsonrpc":"2.0","id":1}"#.utf8) + [0x0A])
        let first = try json(await stdout.line())
        // The first bytes claude sees are the reply: the handshake's OK line stays in the relay.
        #expect(first.objectValue?["id"] == .int(1))
        #expect(first.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.count == 46)
        close(p.stdinWrite)
        #expect(await relaying.value == 0)
        #expect(Self.silent(p.stdoutRead))
        #expect(p.diagnostics().isEmpty)
        close(relaySocket)
        for fd in [p.stdinRead, p.stdoutRead, p.stdoutWrite, p.stderrRead, p.stderrWrite] { close(fd) }
        await h.remove()
    }

    @Test func mainReadsTheTokenFileAndUsesTheRealSocket() async throws {
        let h = try MCPHarness()
        try await h.server.start()
        let (_, files, _) = try await h.openTurn()
        let p = try Plumbing()
        let socket = h.server.socketPath
        let tokenFile = files.tokenPath.path(percentEncoded: false)
        let relaying = Task {
            await offPool {
                MCPRelay.main(socketPath: socket, tokenFile: tokenFile, input: p.stdinRead, output: p.stdoutWrite,
                              diagnostics: p.stderrWrite)
            }
        }
        let stdout = TestEnd(fd: p.stdoutRead)
        Self.write(p.stdinWrite, Array(#"{"jsonrpc":"2.0","id":"a","method":"ping"}"#.utf8) + [0x0A])
        #expect(await stdout.line() == #"{"jsonrpc": "2.0", "id": "a", "result": {}}"#)
        close(p.stdinWrite)
        #expect(await relaying.value == 0)

        let missing = await offPool {
            MCPRelay.main(socketPath: socket, tokenFile: tokenFile + ".gone", input: p.stdinRead,
                          output: p.stdoutWrite, diagnostics: p.stderrWrite)
        }
        #expect(missing == 1)
        #expect(p.diagnostics().contains("cannot read the token file"))
        await h.server.stop()
        let refused = await offPool {
            MCPRelay.main(socketPath: socket, tokenFile: tokenFile, input: p.stdinRead,
                          output: p.stdoutWrite, diagnostics: p.stderrWrite)
        }
        #expect(refused == 1)
        #expect(p.diagnostics().contains("cannot connect"))
        #expect(Self.silent(p.stdoutRead))
        for fd in [p.stdinRead, p.stdoutRead, p.stdoutWrite, p.stderrRead, p.stderrWrite] { close(fd) }
        await h.remove()
    }
}
