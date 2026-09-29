import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// argv (plan M02-M04 §3.6), the per-turn MCP config (§3.7), and the allowed-tool names
/// against m3_tools_list (TOOLS and `_claude_allowed` from the REAL module).
@Suite("M3 Claude invocation: argv, MCP config, tool names")
struct ClaudeInvocationTests {
    static let exe = URL(fileURLWithPath: "/opt/claude-test/bin/claude")
    static let mcp = URL(fileURLWithPath: "/private/var/empty/run/turn-test.mcp.json")
    static let configs = [
        ClaudeConfig(environment: [:]),
        ClaudeConfig(environment: ["JARVIS_CLAUDE_EFFORT": " ", "JARVIS_CLAUDE_MAX_TURNS": "3"]),
        ClaudeConfig(environment: ["JARVIS_CLAUDE_MODEL": "claude-sonnet-test", "JARVIS_CLAUDE_EFFORT": "high"]),
    ]

    @Test func exactArgv() throws {
        let inv = try ClaudeInvocation(executable: Self.exe, systemPrompt: "You are JARVIS.", mcpConfig: Self.mcp,
                                       allowedTools: ["mcp__jarvis__get_time", "mcp__jarvis__run_command"],
                                       config: ClaudeConfig(environment: [:]))
        #expect(inv.executable == Self.exe)
        #expect(inv.arguments == [
            "-p", "--output-format", "stream-json", "--verbose", "--input-format", "stream-json",
            "--include-partial-messages",
            "--system-prompt", "You are JARVIS.",
            "--tools", "",
            "--setting-sources=",
            "--strict-mcp-config",
            "--mcp-config", "/private/var/empty/run/turn-test.mcp.json",
            "--allowedTools", "mcp__jarvis__get_time,mcp__jarvis__run_command",
            "--max-turns", "6",
            "--model", "claude-opus-5-5",
            "--effort", "low",
            "--no-session-persistence",
            "--permission-prompts", "none",
        ])
    }

    @Test func emptyEffortOmitsTheFlag() throws {
        let inv = try ClaudeInvocation(executable: Self.exe, systemPrompt: "s", mcpConfig: Self.mcp, allowedTools: [],
                                       config: Self.configs[1])
        #expect(!inv.arguments.contains("--effort"))
        #expect(Array(inv.arguments.suffix(7)) == ["--max-turns", "3", "--model", "claude-opus-5-5",
                                                   "--no-session-persistence", "--permission-prompts", "none"])
    }

    @Test func forbiddenFlagsAreNeverEmitted() throws {
        for config in Self.configs {
            let inv = try ClaudeInvocation(executable: Self.exe, systemPrompt: "s", mcpConfig: Self.mcp,
                                           allowedTools: ["mcp__jarvis__ping"], config: config)
            for arg in inv.arguments {
                #expect(!ClaudeInvocation.forbiddenFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") }, "\(arg)")
            }
        }
        #expect(throws: ClaudeInvocationError.forbiddenFlag("--bare")) {
            try ClaudeInvocation(executable: Self.exe, systemPrompt: "s", mcpConfig: Self.mcp, allowedTools: [],
                                 config: ClaudeConfig(environment: ["JARVIS_CLAUDE_MODEL": "--bare"]))
        }
        #expect(throws: ClaudeInvocationError.forbiddenFlag("--permission-mode=bypassPermissions")) {
            try ClaudeInvocation(executable: Self.exe, systemPrompt: "s", mcpConfig: Self.mcp, allowedTools: [],
                                 config: ClaudeConfig(environment: ["JARVIS_CLAUDE_EFFORT": "--permission-mode=bypassPermissions"]))
        }
        #expect(throws: ClaudeInvocationError.forbiddenFlag("--dangerously-skip-permissions")) {
            try ClaudeInvocation(executable: Self.exe, systemPrompt: "--dangerously-skip-permissions", mcpConfig: Self.mcp,
                                 allowedTools: [], config: ClaudeConfig(environment: [:]))
        }
    }

    /// m3_tools_list: 46 TOOLS names, and `_claude_allowed` is `mcp__jarvis__<name>` in TOOLS order.
    @Test func allowedToolNamesMatchPython() throws {
        let c = try #require(try Golden.cases("m3_tools_list").first)
        let names = try #require(c.expected.array("names")).compactMap(\.stringValue)
        let allowed = try #require(c.expected.array("allowed")).compactMap(\.stringValue)
        #expect(names.count == 46)
        #expect(Set(names).count == names.count)
        #expect(allowed == names.map(ClaudeInvocation.allowedToolName))
        let inv = try ClaudeInvocation(executable: Self.exe, systemPrompt: "s", mcpConfig: Self.mcp,
                                       allowedTools: allowed, config: ClaudeConfig(environment: [:]))
        let i = try #require(inv.arguments.firstIndex(of: "--allowedTools"))
        #expect(inv.arguments[i + 1].split(separator: ",").map(String.init) == allowed)
    }

    @Test func mcpConfigShapeAndMode() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let run = s.root.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let turn = UUID()
        let socket = run.appending(path: "mcp.sock").path(percentEncoded: false)
        let token = run.appending(path: "turn-\(turn.uuidString.lowercased()).token").path(percentEncoded: false)
        let command = "/opt/jarvis-test/JARVIS"

        let url = try ClaudeInvocation.writeMCPConfig(in: run, turnID: turn, command: command, socket: socket,
                                                      tokenFile: token)
        #expect(url == ClaudeInvocation.mcpConfigURL(in: run, turnID: turn))
        #expect(url.lastPathComponent == "turn-\(turn.uuidString.lowercased()).mcp.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let parsed = try PyJSON.loads(try Data(contentsOf: url))
        #expect(parsed == ClaudeInvocation.mcpConfig(command: command, socket: socket, tokenFile: token))
        let servers = try #require(parsed.objectValue?.object("mcpServers"))
        #expect(parsed.objectValue?.keys == ["mcpServers"] && servers.keys == ["jarvis"])
        let jarvis = try #require(servers.object("jarvis"))
        #expect(jarvis.keys == ["type", "command", "args", "env"])
        #expect(jarvis.string("type") == "stdio" && jarvis.string("command") == command)
        #expect(jarvis.array("args")?.compactMap(\.stringValue) == ["--mcp-relay", socket, "--token-file", token])
        #expect(jarvis.object("env")?.count == 0)

        // Created exclusively: an existing file or a planted symlink is never written through.
        #expect(throws: (any Error).self) {
            try ClaudeInvocation.writeMCPConfig(in: run, turnID: turn, command: command, socket: socket, tokenFile: token)
        }
        let planted = UUID()
        let target = s.root.appending(path: "elsewhere.json")
        try FileManager.default.createSymbolicLink(at: ClaudeInvocation.mcpConfigURL(in: run, turnID: planted),
                                                   withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try ClaudeInvocation.writeMCPConfig(in: run, turnID: planted, command: command, socket: socket, tokenFile: token)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path(percentEncoded: false)))
    }
}
