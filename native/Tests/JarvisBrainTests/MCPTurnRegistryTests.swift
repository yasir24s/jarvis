import Darwin
import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Testing

/// MCPTurnRegistry, the MCPTurnBridge the Claude driver calls (plan §3.7 "Per turn").
@Suite("MCPTurnRegistryTests")
struct MCPTurnRegistryTests {
    static func mode(_ url: URL) -> (type: mode_t, permissions: mode_t)? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return (st.st_mode & S_IFMT, st.st_mode & 0o777)
    }

    @Test func openTurnWritesTheTokenAndConfigFiles() async throws {
        let h = try MCPHarness()
        let turn = TurnContext(channel: .text)
        let files = try await h.registry.openTurn(turn)
        let run = h.registry.runDirectory
        let id = await turn.turnID
        #expect(files.turnID == id)
        #expect(files.configPath == ClaudeInvocation.mcpConfigURL(in: run, turnID: id))
        #expect(files.tokenPath.lastPathComponent == "turn-\(id.uuidString.lowercased()).token")
        #expect(files.tokenPath.deletingLastPathComponent().standardizedFileURL == run.standardizedFileURL)
        for url in [files.tokenPath, files.configPath] {
            let m = try #require(Self.mode(url))
            #expect(m.type == S_IFREG && m.permissions == 0o600, "\(url.lastPathComponent)")
        }
        // 32 random bytes as lowercase hex, and nothing else in the file.
        let token = try String(contentsOf: files.tokenPath, encoding: .utf8)
        #expect(token.utf8.count == 64)
        #expect(token.allSatisfy { "0123456789abcdef".contains($0) })
        // B1's config shape, pointing the relay at the socket and the token file by path.
        let config = try String(contentsOf: files.configPath, encoding: .utf8)
        let expected = ClaudeInvocation.mcpConfig(command: "/opt/jarvis-test/JARVIS", socket: h.registry.socketPath,
                                                  tokenFile: files.tokenPath.path(percentEncoded: false))
        #expect(try PyJSON.loads(Data(config.utf8)) == expected)
        #expect(h.registry.socketPath == run.appending(path: "mcp.sock").path(percentEncoded: false))
        #expect(!config.contains(token))
        #expect(await h.registry.isOpen(id))
        await h.registry.closeTurn(id)
        await h.remove()
    }

    @Test func everyTurnGetsItsOwnToken() async throws {
        let h = try MCPHarness()
        let a = try await h.openTurn()
        let b = try await h.openTurn()
        #expect(a.token != b.token)
        #expect(a.files.tokenPath != b.files.tokenPath)
        await h.remove()
    }

    @Test func closeTurnDeletesBothFilesAndIsIdempotent() async throws {
        let h = try MCPHarness()
        let (_, files, token) = try await h.openTurn()
        await h.registry.closeTurn(files.turnID)
        #expect(Self.mode(files.tokenPath) == nil)
        #expect(Self.mode(files.configPath) == nil)
        #expect(await !h.registry.isOpen(files.turnID))
        await h.registry.closeTurn(files.turnID)
        await h.registry.closeTurn(UUID())
        // The forgotten token binds nothing.
        let end = try h.connect()
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        #expect(await end.closed())
        #expect(await h.logs.waitFor("relay rejected: unknown token"))
        end.close()
        await h.remove()
    }

    @Test func openingOneTurnTwiceIsRefused() async throws {
        let h = try MCPHarness()
        let turn = TurnContext(channel: .voice)
        let files = try await h.registry.openTurn(turn)
        await #expect(throws: MCPTurnError.alreadyOpen(files.turnID)) { try await h.registry.openTurn(turn) }
        await h.remove()
    }

    @Test func anythingAlreadyAtTheTokenPathIsRefusedAndUntouched() async throws {
        let h = try MCPHarness()
        let run = h.registry.runDirectory
        let target = h.dir.url.appending(path: "elsewhere")
        try Data("keep".utf8).write(to: target)
        let turn = TurnContext(channel: .text)
        let tokenPath = MCPTurnRegistry.tokenURL(in: run, turnID: await turn.turnID).path(percentEncoded: false)
        #expect(symlink(target.path(percentEncoded: false), tokenPath) == 0)
        await #expect(throws: POSIXError.self) { try await h.registry.openTurn(turn) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(Self.mode(ClaudeInvocation.mcpConfigURL(in: run, turnID: await turn.turnID)) == nil)
        #expect(await !h.registry.isOpen(await turn.turnID))
        await h.remove()
    }

    @Test func aClosedTurnContextCannotBeBound() async throws {
        let h = try MCPHarness()
        let (turn, files, token) = try await h.openTurn()
        await turn.close()
        let end = try h.connect()
        end.send(#"{"jarvis_relay":1,"token":"\#(token)"}"# + "\n")
        #expect(await end.closed())
        #expect(await h.logs.waitFor("relay rejected: turn \(files.turnID) is closed"))
        end.close()
        await h.remove()
    }
}
