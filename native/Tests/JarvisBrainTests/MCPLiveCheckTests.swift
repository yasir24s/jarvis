import Foundation
@testable import JarvisBrain
import JarvisTools
import Testing

/// MCP review finding 3, both halves joined: the `live` check MCPServer hands the gateway for a
/// connection's calls. The gateway half (a call queued in the turn's FIFO runs its body only
/// while `live` holds) is proven in ToolGatewayTests; this proves the check the server builds.
@Suite("MCP live check (review finding 3)")
struct MCPLiveCheckTests {
    @Test func holdsWhileTheBindingStandsAndFailsOnceTheTurnCloses() async throws {
        let h = try MCPHarness()
        let (_, files, _) = try await h.openTurn()
        let live = MCPServer.liveCheck(handle: MCPServeHandle(), registry: h.registry, turnID: files.turnID)
        #expect(await live())
        await h.registry.closeTurn(files.turnID)
        #expect(await !live(), "a call queued behind another operation could still run after closeTurn")
        await h.remove()
    }

    @Test func failsForARevokedHandleEvenWhileTheTurnIsOpen() async throws {
        let h = try MCPHarness()
        let (_, files, _) = try await h.openTurn()
        let handle = MCPServeHandle()
        let live = MCPServer.liveCheck(handle: handle, registry: h.registry, turnID: files.turnID)
        handle.revoke()
        #expect(await h.registry.isOpen(files.turnID))
        #expect(await !live())
        await h.remove()
    }
}
