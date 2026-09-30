import Darwin
import Foundation
@testable import JarvisBrain
import JarvisCore
import Testing

/// Codex review finding 2 (D-44): connections are capped at accept time, handshaking ones
/// included, and `stop()` closes accepted descriptors no serve task has claimed yet.
@Suite("MCPAdmissionTests")
struct MCPAdmissionTests {
    static func hello(_ token: String) -> String { #"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n" }
    static let ok = #"{"jarvis_relay_ok":1}"#

    @Test func theFifthConnectionIsRefusedWhileFourAreOpen() async throws {
        let h = try MCPHarness()
        try await h.server.start()
        let socket = h.server.socketPath
        // Three bound relays and one still handshaking hold all four slots.
        var ends: [TestEnd] = []
        for _ in 0..<3 {
            let (_, _, token) = try await h.openTurn()
            let end = TestEnd(fd: try MCPSocket.connect(to: socket))
            end.send(Self.hello(token))
            #expect(await end.line() == Self.ok)
            ends.append(end)
        }
        let (_, _, fourthToken) = try await h.openTurn()
        let handshaking = TestEnd(fd: try MCPSocket.connect(to: socket))
        let fifth = TestEnd(fd: try MCPSocket.connect(to: socket))
        #expect(await fifth.closed(seconds: 2), "the fifth connection stayed open")
        #expect(await h.logs.waitFor("mcp: connection refused: 4 already live"))
        #expect(h.server.liveConnections == 4)
        // The handshaking one was admitted: it binds, and every bound relay still answers.
        handshaking.send(Self.hello(fourthToken))
        #expect(await handshaking.line() == Self.ok)
        ends.append(handshaking)
        for (i, end) in ends.enumerated() {
            end.send(#"{"jsonrpc":"2.0","id":\#(i),"method":"ping"}"# + "\n")
            #expect(await end.line() == #"{"jsonrpc": "2.0", "id": \#(i), "result": {}}"#)
        }
        #expect(h.logs.all.filter { $0.hasPrefix("mcp: connection refused") }.count == 1)
        // Closing one frees its slot for the next connection.
        ends[0].close()
        #expect(await eventually { h.server.liveConnections == 3 })
        let (_, _, sixthToken) = try await h.openTurn()
        let sixth = TestEnd(fd: try MCPSocket.connect(to: socket))
        sixth.send(Self.hello(sixthToken))
        #expect(await sixth.line() == Self.ok)
        // stop() drops the four live ones and their slots come back.
        await h.server.stop()
        for end in ends.dropFirst() + [sixth] {
            #expect(await end.closed())
            end.close()
        }
        #expect(await eventually { h.server.liveConnections == 0 })
        fifth.close()
        await h.remove()
    }

    @Test func stopClosesADescriptorNoServeTaskHasClaimed() async throws {
        let admission = MCPAdmission(limit: 4)
        let (accepted, peer) = try socketPair()
        let other = TestEnd(fd: peer)
        guard case .admitted(let ticket) = admission.admit(accepted) else {
            Issue.record("a free slot refused the connection")
            return
        }
        #expect(admission.live == 1)
        #expect(admission.waiting == 1)
        admission.stop()
        #expect(await other.closed(), "stop() left the accepted descriptor open")
        #expect(admission.live == 0)
        #expect(admission.waiting == 0)
        // Its serve task, starting late, finds nothing to claim.
        #expect(admission.claim(ticket) == nil)
        #expect(admission.live == 0)
        other.close()

        // A descriptor accepted after stop() is closed at once, and so is one past the limit.
        let (late, latePeer) = try socketPair()
        let lateEnd = TestEnd(fd: latePeer)
        #expect(admission.admit(late) == .stopped)
        #expect(await lateEnd.closed())
        #expect(admission.live == 0)
        lateEnd.close()
        admission.reopen()
        var peers: [TestEnd] = []
        for _ in 0..<4 {
            let (fd, ours) = try socketPair()
            guard case .admitted = admission.admit(fd) else {
                Issue.record("a free slot refused the connection")
                return
            }
            peers.append(TestEnd(fd: ours))
        }
        let (extra, extraPeer) = try socketPair()
        let extraEnd = TestEnd(fd: extraPeer)
        #expect(admission.admit(extra) == .full)
        #expect(await extraEnd.closed())
        #expect(admission.live == 4)
        extraEnd.close()
        admission.stop()
        for end in peers {
            #expect(await end.closed())
            end.close()
        }
        #expect(admission.live == 0)
    }

    @Test func aServeTaskAfterStopClosesItsDescriptorAndRegistersNothing() async throws {
        let h = try MCPHarness()
        let (_, _, token) = try await h.openTurn()
        try await h.server.start()
        await h.server.stop()
        let end = try h.connect()   // serve(connection:) after stop()
        end.send(Self.hello(token))
        #expect(await end.closed(), "a connection served after stop() stayed open")
        #expect(await end.line(seconds: 0.1) == nil, "a line came back before the close")
        #expect(await h.logs.waitFor("mcp: connection closed: the server has stopped"))
        #expect(h.server.liveConnections == 0)
        #expect(h.server.unclaimedConnections == 0)
        #expect(!h.logs.all.contains { $0.hasPrefix("relay") || $0.hasPrefix("mcp: relay bound") })
        end.close()
        await h.remove()
    }
}
