import Foundation
import JarvisTools

// The contract between the Claude driver (T3.4) and the MCP server (T3.3), plan §3.7.
// Written by the orchestrator: executors implement or call it, never edit it.

/// The two per-turn files the relay needs, both mode 0600: `run/turn-<uuid>.token` and
/// `run/turn-<uuid>.mcp.json`. The token itself never leaves the bridge: it is not in this
/// struct, in argv, in the environment or in any log.
public struct MCPTurnFiles: Sendable, Equatable {
    public let turnID: UUID
    public let tokenPath: URL
    public let configPath: URL

    public init(turnID: UUID, tokenPath: URL, configPath: URL) {
        self.turnID = turnID
        self.tokenPath = tokenPath
        self.configPath = configPath
    }
}

/// Per turn, in this order: `openTurn`; `setClaudePID` once `claude` has started (the
/// handshake checks the relay's parent pid against it); `closeTurn` on every exit path.
/// `closeTurn` is idempotent.
public protocol MCPTurnBridge: Sendable {
    func openTurn(_ turn: TurnContext) async throws -> MCPTurnFiles
    func setClaudePID(_ pid: Int32, for turnID: UUID) async
    func closeTurn(_ turnID: UUID) async
}
