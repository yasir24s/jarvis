import Darwin
import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// Codex review finding 1 (D-44): byte limits on bound traffic, with small budgets. A line over
/// the cap, input piled up behind a parked tool call and replies nobody reads each disconnect,
/// and the relay exits 1 once one side falls too far behind. The assertions are on the byte
/// counters, never on RSS.
@Suite("MCPByteLimitTests")
struct MCPByteLimitTests {
    static let small = MCPServer.Limits(lineBytes: 1024, inboundBytes: 16 << 10, outboundBytes: 64 << 10)

    @Test func aLineOverTheCapDisconnectsWithALogLine() async throws {
        let h = try MCPHarness(limits: Self.small)
        let (_, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        // A line of exactly 1024 bytes is served.
        let ping = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        let padded = String(ping.dropLast()) + String(repeating: " ", count: 1024 - ping.utf8.count) + "}"
        #expect(padded.utf8.count == 1024)
        end.send(padded + "\n")
        #expect(await end.line() == #"{"jsonrpc": "2.0", "id": 1, "result": {}}"#)
        // One byte more is not.
        end.send(String(repeating: " ", count: 1025) + "\n")
        #expect(await end.closed(), "a 1025-byte line left the connection open")
        #expect(await h.logs.waitFor("mcp: relay disconnected: line over 1024 bytes"))
        end.close()
        // Nor is a line that never ends.
        let (_, _, second) = try await h.openTurn()
        let unended = try await h.bound(token: second)
        unended.send(String(repeating: "x", count: 4000))
        #expect(await unended.closed(), "an unended 4000-byte line left the connection open")
        #expect(await eventually {
            h.logs.all.filter { $0 == "mcp: relay disconnected: line over 1024 bytes" }.count == 2
        })
        #expect(await eventually { h.server.liveConnections == 0 })
        #expect(await h.server.peakInboundBytes <= Self.small.inboundBytes)
        unended.close()
        await h.remove()
    }

    @Test func inputPiledUpBehindAParkedCallDisconnectsAtTheBudget() async throws {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate())
        let release = TestGate()
        let (entered, enteredContinuation) = AsyncStream.makeStream(of: Void.self)
        await gateway.register(ParkedTool(entered: enteredContinuation, release: release))
        let h = try MCPHarness(tools: [ParkedTool.schema], gateway: gateway, limits: Self.small)
        let (_, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        end.send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"park","arguments":{}}}"# + "\n")
        var calls = entered.makeAsyncIterator()
        _ = await calls.next()
        // 64 KB of pipelined pings while the one call is parked: four times the 16 KB budget.
        let ping = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n"
        let pings = String(repeating: ping, count: (64 << 10) / ping.utf8.count)
        let sending = Task { await offPool { end.send(pings) } }
        // The read side closes the connection while the call is still parked.
        #expect(await end.closed(), "piled-up input left the connection open")
        await sending.value
        await release.open()
        #expect(await h.logs.waitFor("mcp: relay disconnected: over 16384 bytes read and not yet handled"))
        #expect(await eventually { h.server.liveConnections == 0 })
        let peak = await h.server.peakInboundBytes
        #expect(peak > 0 && peak <= Self.small.inboundBytes, "peak \(peak)")
        #expect(await end.line(seconds: 0.1) == nil, "a reply came back from the piled-up input")
        end.close()
        await h.remove()
    }

    @Test func aReaderThatStopsReadingIsDisconnectedAtTheBudget() async throws {
        let h = try MCPHarness(limits: Self.small)   // the full catalog
        let (_, _, token) = try await h.openTurn()
        let end = try await h.bound(token: token)
        let list = #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"# + "\n"
        end.send(list)
        let one = try #require(await end.line()).utf8.count + 1
        #expect(one > 10_000 && one < 16_000, "tools/list reply of \(one) bytes")
        end.send(String(repeating: list, count: 40))   // 40 replies, over 400 KB, and no reads
        #expect(await h.logs.waitFor("mcp: relay disconnected: over 65536 bytes of replies not yet read"))
        #expect(await eventually { h.server.liveConnections == 0 })
        let peak = await h.server.peakOutboundBytes
        #expect(peak > Self.small.outboundBytes / 2 && peak <= Self.small.outboundBytes, "peak \(peak)")
        #expect(await end.closed())
        end.close()
        await h.remove()
    }

    @Test func theRelayExitsOneWhenEitherSideFallsBehind() async throws {
        let limit = 64 << 10
        let flood = [UInt8](repeating: 0x41, count: 1 << 20)
        // Toward claude: the app floods the socket and nobody reads the relay's stdout.
        do {
            let p = try RelayTests.Plumbing()
            let (relaySocket, app) = try socketPair()
            let pumping = Task {
                await offPool {
                    MCPRelay.pumpReport(input: p.stdinRead, output: p.stdoutWrite, socket: relaySocket,
                                        backlogLimit: limit, diagnostics: p.stderrWrite)
                }
            }
            let writing = Task { await offPool { RelayTests.write(app, flood) } }
            let report = await pumping.value
            #expect(report.status == 1)
            #expect(report.peakBacklog[1] > 0 && report.peakBacklog[1] <= limit, "peak \(report.peakBacklog)")
            #expect(p.diagnostics() == "JARVIS relay: over 65536 bytes waiting for claude\n")
            close(relaySocket)   // the blocked writer gets EPIPE
            await writing.value
            close(app)
            p.closeAll()
        }
        // Toward the app: claude floods stdin and the app never reads the socket.
        do {
            let p = try RelayTests.Plumbing()
            let (stdinRelay, stdinClaude) = try socketPair()
            let (relaySocket, app) = try socketPair()
            let pumping = Task {
                await offPool {
                    MCPRelay.pumpReport(input: stdinRelay, output: p.stdoutWrite, socket: relaySocket,
                                        backlogLimit: limit, diagnostics: p.stderrWrite)
                }
            }
            let writing = Task { await offPool { RelayTests.write(stdinClaude, flood) } }
            let report = await pumping.value
            #expect(report.status == 1)
            #expect(report.peakBacklog[0] > 0 && report.peakBacklog[0] <= limit, "peak \(report.peakBacklog)")
            #expect(p.diagnostics() == "JARVIS relay: over 65536 bytes waiting for the app\n")
            close(stdinRelay)
            await writing.value
            for fd in [stdinClaude, relaySocket, app] { close(fd) }
            p.closeAll()
        }
    }
}
