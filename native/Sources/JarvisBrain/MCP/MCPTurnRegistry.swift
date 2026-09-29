import Darwin
import Foundation
import JarvisCore
import JarvisTools
import Security

public enum MCPTurnError: Error, Equatable {
    /// `openTurn` was called twice for one TurnContext.
    case alreadyOpen(UUID)
    /// `SecRandomCopyBytes` failed with this status.
    case randomBytes(Int32)
}

/// The per-turn half of plan §3.7: tokens, the two 0600 files the relay needs, and the claude
/// pid the handshake checks. The token lives only here and in the token file: never in a log,
/// in argv, in the environment, or in `MCPTurnFiles`.
public actor MCPTurnRegistry: MCPTurnBridge {
    public nonisolated let runDirectory: URL
    public nonisolated let socketPath: String
    /// The `command` written into each turn's MCP config: the app's own executable.
    public nonisolated let relayCommand: String

    private struct Entry {
        let turn: TurnContext
        let token: [UInt8]           // the hex text, as the relay sends it
        let files: MCPTurnFiles
        var claudePID: Int32?
        var bound = false
    }

    private var entries: [UUID: Entry] = [:]

    /// `relayCommand` defaults to this process's executable, which is what the app wants.
    public init(runDirectory: URL, relayCommand: String? = nil) {
        self.runDirectory = runDirectory
        self.socketPath = MCPSocket.socketPath(in: runDirectory)
        self.relayCommand = relayCommand ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// `<runDirectory>/turn-<uuid>.token`, named from B1's `mcpConfigURL(in:turnID:)` so the two
    /// files always share the lowercase `turn-<uuid>` stem.
    public static func tokenURL(in runDirectory: URL, turnID: UUID) -> URL {
        let config = ClaudeInvocation.mcpConfigURL(in: runDirectory, turnID: turnID).lastPathComponent
        let suffix = ".mcp.json"
        precondition(config.hasSuffix(suffix), "mcpConfigURL no longer ends in \(suffix)")
        return runDirectory.appending(path: String(config.dropLast(suffix.count)) + ".token",
                                      directoryHint: .notDirectory)
    }

    public func openTurn(_ turn: TurnContext) async throws -> MCPTurnFiles {
        let id = await turn.turnID
        guard entries[id] == nil else { throw MCPTurnError.alreadyOpen(id) }
        var raw = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, raw.count, &raw)
        guard status == errSecSuccess else { throw MCPTurnError.randomBytes(status) }
        let token = Array(raw.map { String(format: "%02x", $0) }.joined().utf8)

        let tokenURL = Self.tokenURL(in: runDirectory, turnID: id)
        let tokenPath = tokenURL.path(percentEncoded: false)
        try Self.writeExclusive(token, to: tokenPath)
        let configURL: URL
        do {
            configURL = try ClaudeInvocation.writeMCPConfig(in: runDirectory, turnID: id, command: relayCommand,
                                                            socket: socketPath, tokenFile: tokenPath)
        } catch {
            unlink(tokenPath)
            throw error
        }
        let files = MCPTurnFiles(turnID: id, tokenPath: tokenURL, configPath: configURL)
        entries[id] = Entry(turn: turn, token: token, files: files)
        return files
    }

    public func setClaudePID(_ pid: Int32, for turnID: UUID) async {
        entries[turnID]?.claudePID = pid
    }

    public func closeTurn(_ turnID: UUID) async {
        guard let entry = entries.removeValue(forKey: turnID) else { return }
        unlink(entry.files.tokenPath.path(percentEncoded: false))
        unlink(entry.files.configPath.path(percentEncoded: false))
    }

    /// True while the turn is registered: after `openTurn`, before `closeTurn`.
    public func isOpen(_ turnID: UUID) -> Bool {
        entries[turnID] != nil
    }

    /// A connection that passed the handshake, and the turn it now serves.
    struct Binding: Sendable {
        let turn: TurnContext
        let turnID: UUID
    }

    enum Claim: Sendable {
        case bound(Binding)
        case rejected(String)
    }

    /// The token half of the handshake: the token must match an open turn (compared in constant
    /// time against every entry), the relay's parent must be that turn's claude, and no earlier
    /// connection may have bound it. Only a connection that passes binds the turn.
    func claim(token presented: [UInt8], parentPID: pid_t?) -> Claim {
        var match: UUID?
        for (id, entry) in entries where Self.constantTimeEqual(presented, entry.token) {
            match = id
        }
        guard let id = match, var entry = entries[id] else { return .rejected("unknown token") }
        guard let expected = entry.claudePID else { return .rejected("no claude pid registered for turn \(id)") }
        guard let parentPID, parentPID == expected else {
            return .rejected("parent pid \(parentPID.map(String.init) ?? "unknown") is not claude pid \(expected)")
        }
        guard !entry.bound else { return .rejected("second connection for turn \(id)") }
        entry.bound = true
        entries[id] = entry
        return .bound(Binding(turn: entry.turn, turnID: id))
    }

    /// Runs over every byte of `expected` whatever `presented` holds, so the time taken does not
    /// depend on where the first difference is.
    static func constantTimeEqual(_ presented: [UInt8], _ expected: [UInt8]) -> Bool {
        var difference: UInt8 = presented.count == expected.count ? 0 : 1
        for i in expected.indices {
            difference |= expected[i] ^ (i < presented.count ? presented[i] : 0)
        }
        return difference == 0
    }

    /// O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600.
    private static func writeExclusive(_ bytes: [UInt8], to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        do {
            guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var written = 0
            while written < bytes.count {
                let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                written += n
            }
        } catch {
            unlink(path)
            throw error
        }
    }
}
