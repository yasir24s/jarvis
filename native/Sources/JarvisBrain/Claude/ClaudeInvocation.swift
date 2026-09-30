import Foundation
import JarvisCore

public enum ClaudeInvocationError: Error, Equatable {
    /// An argument equal to a forbidden flag (or `<flag>=…`) would have been emitted.
    case forbiddenFlag(String)
}

/// The argv for one `claude` turn and its per-turn MCP config (plan: M02-M04 §3.6, §3.7).
/// The socket and token files are made by the caller (T3.3); only their paths come here.
public struct ClaudeInvocation: Sendable, Equatable {
    /// Never emitted: `--bare` forces API-key auth, and the rest skip or bypass permissions.
    public static let forbiddenFlags = ["--bare", "--dangerously-skip-permissions",
                                        "--allow-dangerously-skip-permissions", "--permission-mode"]
    public static let serverName = "jarvis"

    public let executable: URL
    public let arguments: [String]

    /// The allowed-tools entry for a TOOLS name: `mcp__jarvis__<name>` (jarvis.py
    /// `_build_claude_server`).
    public static func allowedToolName(_ tool: String) -> String {
        "mcp__\(serverName)__\(tool)"
    }

    /// argv in §3.6's order. `allowedTools` comes from the caller, already in TOOLS order.
    public init(executable: URL, systemPrompt: String, mcpConfig: URL, allowedTools: [String],
                config: ClaudeConfig) throws(ClaudeInvocationError) {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                 "--include-partial-messages",
                 "--system-prompt", systemPrompt,
                 "--tools", "",
                 "--setting-sources=",
                 "--strict-mcp-config",
                 "--mcp-config", mcpConfig.path(percentEncoded: false),
                 "--allowedTools", allowedTools.joined(separator: ","),
                 "--max-turns", String(config.maxTurns),
                 "--model", config.model]
        if !config.effort.isEmpty {
            a += ["--effort", config.effort]
        }
        a += ["--no-session-persistence", "--permission-prompts", "none"]
        try Self.refuseForbiddenFlags(a)
        self.executable = executable
        self.arguments = a
    }

    /// argv for a one-shot call with no tools and no MCP server (the persona writer): the
    /// turn's flags in the turn's order without `--mcp-config` and `--allowedTools`, and one
    /// turn. `--tools ""` and `--strict-mcp-config` stay, so neither a built-in tool nor any
    /// other MCP configuration loads; the partial messages stay because R6's refusal stop
    /// reason arrives in them.
    public init(oneShot executable: URL, systemPrompt: String, config: ClaudeConfig) throws(ClaudeInvocationError) {
        var a = ["-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
                 "--include-partial-messages",
                 "--system-prompt", systemPrompt,
                 "--tools", "",
                 "--setting-sources=",
                 "--strict-mcp-config",
                 "--max-turns", "1",
                 "--model", config.model]
        if !config.effort.isEmpty {
            a += ["--effort", config.effort]
        }
        a += ["--no-session-persistence", "--permission-prompts", "none"]
        try Self.refuseForbiddenFlags(a)
        self.executable = executable
        self.arguments = a
    }

    /// Throws for any argument equal to a forbidden flag or starting with `<flag>=`.
    private static func refuseForbiddenFlags(_ a: [String]) throws(ClaudeInvocationError) {
        for arg in a where forbiddenFlags.contains(where: { Py.eq(arg, $0) || Py.startsWith(arg, $0 + "=") }) {
            throw .forbiddenFlag(arg)
        }
    }

    /// `<directory>/turn-<uuid>.mcp.json`, the uuid lowercased.
    public static func mcpConfigURL(in directory: URL, turnID: UUID) -> URL {
        directory.appending(path: "turn-\(turnID.uuidString.lowercased()).mcp.json", directoryHint: .notDirectory)
    }

    /// The §3.7 config: `{"mcpServers":{"jarvis":{"type":"stdio","command":…,"args":
    /// ["--mcp-relay",<socket>,"--token-file",<token file>],"env":{}}}}`.
    public static func mcpConfig(command: String, socket: String, tokenFile: String) -> JSONValue {
        let server = JSONObject([
            .init(key: "type", value: .string("stdio")),
            .init(key: "command", value: .string(command)),
            .init(key: "args", value: .array([.string("--mcp-relay"), .string(socket),
                                              .string("--token-file"), .string(tokenFile)])),
            .init(key: "env", value: .object(JSONObject())),
        ])
        return .object(JSONObject([.init(key: "mcpServers", value: .object(JSONObject([
            .init(key: serverName, value: .object(server)),
        ])))]))
    }

    /// Writes the config to `mcpConfigURL(in:turnID:)`, created exclusively (O_CREAT|O_EXCL|
    /// O_NOFOLLOW) with mode 0600, and returns its URL. `directory` must already exist.
    public static func writeMCPConfig(in directory: URL, turnID: UUID, command: String, socket: String,
                                      tokenFile: String) throws -> URL {
        let url = mcpConfigURL(in: directory, turnID: turnID)
        let bytes = Data(PyJSON.dumps(mcpConfig(command: command, socket: socket, tokenFile: tokenFile)).utf8)
        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: bytes)
        try handle.close()
        return url
    }
}
