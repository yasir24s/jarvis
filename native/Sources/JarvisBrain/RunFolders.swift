import CryptoKit
import Foundation

/// Where one state root's `run/` (the MCP socket and the turn tokens) and `claude-cwd/` live,
/// under Application Support (plan §3.6, §3.7). Apps on different state roots hold different
/// locks, so both can run, and they must not share `run/mcp.sock`: the second would unlink the
/// first's socket. The default root keeps `run/` and `claude-cwd/`. Any other root gets
/// `run-<h>/` and `claude-cwd-<h>/`, where h is the first 8 hex digits of the SHA-256 of the
/// root's path. The suffix has a fixed length, so a long root does not lengthen the socket path.
/// B2: `codex-cwd/` (or `codex-cwd-<h>/`), the empty folder `codex` runs in, sits beside them.
public struct RunFolders: Sendable, Equatable {
    public let run: URL
    public let claudeWorkingDirectory: URL
    public let codexWorkingDirectory: URL

    /// - Parameters:
    ///   - stateRoot: the root whose lock this app holds.
    ///   - defaultRoot: the root the app uses without JARVIS_HOME, or nil when there is none.
    ///   - support: `BrainAssembly.supportDirectory`; tests pass their own.
    public init(stateRoot: URL, defaultRoot: URL?, support: URL = BrainAssembly.supportDirectory) {
        let suffix: String
        if let defaultRoot, Self.key(defaultRoot) == Self.key(stateRoot) {
            suffix = ""
        } else {
            suffix = "-" + Self.suffix(for: stateRoot)
        }
        run = support.appending(path: "run" + suffix, directoryHint: .isDirectory)
        claudeWorkingDirectory = support.appending(path: "claude-cwd" + suffix, directoryHint: .isDirectory)
        codexWorkingDirectory = support.appending(path: "codex-cwd" + suffix, directoryHint: .isDirectory)
    }

    /// The root's path as it is hashed and compared: standardized, with no trailing slash.
    public static func key(_ root: URL) -> String {
        var path = root.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The first 8 hex digits (lower case) of the SHA-256 of `key(root)` in UTF-8.
    public static func suffix(for root: URL) -> String {
        SHA256.hash(data: Data(key(root).utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// `<run>/mcp.sock`.
    public var socketPath: String {
        MCPSocket.socketPath(in: run)
    }

    /// Whether the socket path fits `sockaddr_un.sun_path` with its NUL.
    public var socketPathFits: Bool {
        socketPath.utf8.count < MCPSocket.sunPathSize
    }
}
