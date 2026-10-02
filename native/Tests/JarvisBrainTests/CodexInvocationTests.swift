import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// B2 part 1: the exact `codex exec` argv, the per-turn model catalog and the relay read from
/// the per-turn MCP config. The user's config.toml sets `sandbox_mode = "danger-full-access"`;
/// these prove a JARVIS run never asks for it, never loads that file, and turns Codex's own
/// tools off.
@Suite("B2 Codex invocation: argv, catalog, relay")
struct CodexInvocationTests {
    static let exe = URL(fileURLWithPath: "/opt/codex-test/bin/codex")
    static let cwd = URL(fileURLWithPath: "/private/var/empty/codex-cwd", isDirectory: true)
    static let catalog = URL(fileURLWithPath: "/private/var/empty/run/turn-test.codex-models.json")
    static let relay = CodexInvocation.Relay(command: "/opt/jarvis-test/JARVIS",
                                             arguments: ["--mcp-relay", "/private/var/empty/run/mcp.sock",
                                                         "--token-file", "/private/var/empty/run/turn-test.token"])

    static func invocation(_ config: CodexConfig = CodexConfig(environment: [:]),
                           tools: [String] = ["get_time", "run_command"]) throws -> CodexInvocation {
        try CodexInvocation(executable: exe, workingDirectory: cwd, catalog: catalog, relay: relay,
                            enabledTools: tools, config: config)
    }

    @Test func exactArgv() throws {
        let inv = try Self.invocation()
        #expect(inv.executable == Self.exe)
        var expected = [
            "exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
            "--skip-git-repo-check", "--color", "never",
            "--cd", "/private/var/empty/codex-cwd/",
            "--model", "gpt-6-luna",
            "--sandbox", "read-only",
            "-c", #"approval_policy="never""#,
            "-c", #"model_reasoning_effort="low""#,
            "-c", #"model_catalog_json="/private/var/empty/run/turn-test.codex-models.json""#,
            "-c", #"web_search="disabled""#,
            "-c", "tools.experimental_request_user_input.enabled=false",
            "-c", #"features.code_mode.excluded_tool_namespaces=["clock","functions"]"#,
            "-c", "skills.include_instructions=false",
            "-c", "include_permissions_instructions=false",
            "-c", "include_apps_instructions=false",
            "-c", "include_collaboration_mode_instructions=false",
            "-c", "include_environment_context=false",
            "-c", #"history.persistence="none""#,
            "-c", #"shell_environment_policy.inherit="none""#,
            "-c", "check_for_update_on_startup=false",
        ]
        for feature in ["shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot", "code_mode_host",
                        "multi_agent", "multi_agent_v2", "apps", "plugins", "remote_plugin", "plugin_sharing",
                        "skill_search", "skill_mcp_dependency_install", "tool_suggest", "hooks", "memories", "goals",
                        "image_generation", "view_image", "browser_use", "browser_use_external",
                        "browser_use_full_cdp_access", "computer_use", "sleep_tool", "workspace_dependencies",
                        "worktrees", "guardian_approval", "fast_mode", "daemon_auto_start", "realtime_conversation",
                        "unbounded_connection_retries"] {
            expected += ["--disable", feature]
        }
        expected += [
            "-c", #"mcp_servers.jarvis.command="/opt/jarvis-test/JARVIS""#,
            "-c", #"mcp_servers.jarvis.args=["--mcp-relay","/private/var/empty/run/mcp.sock","--token-file","/private/var/empty/run/turn-test.token"]"#,
            "-c", "mcp_servers.jarvis.required=true",
            "-c", "mcp_servers.jarvis.startup_timeout_sec=10",
            "-c", #"mcp_servers.jarvis.omit_tools_from=["code_mode","deferred"]"#,
            "-c", #"mcp_servers.jarvis.default_tools_approval_mode="approve""#,
            "-c", #"mcp_servers.jarvis.enabled_tools=["get_time","run_command"]"#,
            "-",
        ]
        #expect(inv.arguments == expected)
    }

    /// The user's config.toml is never read, the sandbox is read-only exactly once, approvals
    /// are "never", and no argument names a writable sandbox or a bypass.
    @Test func neverDangerFullAccess() throws {
        for config in [CodexConfig(environment: [:]),
                       CodexConfig(environment: ["JARVIS_CHATGPT_MODEL": "gpt-test", "JARVIS_CHATGPT_EFFORT": "high"])] {
            let a = try Self.invocation(config).arguments
            #expect(a.contains("--ignore-user-config"))
            #expect(a.contains("--strict-config"))
            #expect(!a.contains { $0.contains("danger-full-access") || $0.contains("workspace-write") })
            #expect(!a.contains { $0.hasPrefix("--dangerously") || $0 == "--full-auto" || $0 == "--yolo" })
            #expect(!a.contains { $0 == "--profile" || $0 == "-p" || $0 == "--add-dir" || $0 == "--approve-for-me" })
            #expect(!a.contains { $0 == "-s" })
            let sandboxes = a.indices.filter { a[$0] == "--sandbox" }
            #expect(sandboxes.count == 1)
            #expect(sandboxes.first.map { a[$0 + 1] } == "read-only")
            #expect(a.filter { $0.hasPrefix("approval_policy=") } == [#"approval_policy="never""#])
            #expect(!a.contains { $0.hasPrefix("sandbox_mode") })
            // The prompt is read from stdin, never put in argv.
            #expect(a.last == "-")
        }
    }

    /// Codex's own tools: the shell, code mode, sub-agents, web search, images, apps and plugins
    /// are each turned off, and JARVIS's tools are offered directly and approved by JARVIS.
    @Test func toolOverrides() throws {
        let a = try Self.invocation().arguments
        let disabled = Set(a.indices.filter { a[$0] == "--disable" }.map { a[$0 + 1] })
        for feature in ["shell_tool", "unified_exec", "code_mode_host", "multi_agent", "multi_agent_v2", "apps",
                        "plugins", "image_generation", "view_image", "browser_use", "computer_use", "hooks",
                        "memories", "skill_search", "sleep_tool"] {
            #expect(disabled.contains(feature), "\(feature) stays on")
        }
        #expect(a.contains(#"web_search="disabled""#))
        #expect(a.contains("tools.experimental_request_user_input.enabled=false"))
        #expect(a.contains(#"mcp_servers.jarvis.omit_tools_from=["code_mode","deferred"]"#))
        #expect(a.contains(#"mcp_servers.jarvis.default_tools_approval_mode="approve""#))
        // Only the jarvis server is configured.
        let servers = Set(a.compactMap { arg -> String? in
            guard arg.hasPrefix("mcp_servers.") else { return nil }
            return arg.dropFirst("mcp_servers.".count).split(separator: ".").first.map(String.init)
        })
        #expect(servers == ["jarvis"])
    }

    @Test func effortIsLeftOutWhenEmpty() throws {
        let a = try Self.invocation(CodexConfig(environment: ["JARVIS_CHATGPT_EFFORT": " "])).arguments
        #expect(!a.contains { $0.hasPrefix("model_reasoning_effort") })
        let b = try Self.invocation(CodexConfig(environment: ["JARVIS_CHATGPT_EFFORT": "medium"])).arguments
        #expect(b.contains(#"model_reasoning_effort="medium""#))
    }

    @Test func refusesAForbiddenFlagOrSandboxValue() {
        #expect(throws: CodexInvocationError.forbiddenFlag("--yolo")) {
            try Self.invocation(CodexConfig(environment: ["JARVIS_CHATGPT_MODEL": "--yolo"]))
        }
        #expect(throws: CodexInvocationError.forbiddenFlag("--dangerously-bypass-approvals-and-sandbox")) {
            try Self.invocation(CodexConfig(environment: ["JARVIS_CHATGPT_MODEL": "--dangerously-bypass-approvals-and-sandbox"]))
        }
        #expect(throws: CodexInvocationError.forbiddenValue(#"model_reasoning_effort="danger-full-access""#)) {
            try Self.invocation(CodexConfig(environment: ["JARVIS_CHATGPT_EFFORT": "danger-full-access"]))
        }
    }

    /// Values are TOML strings, so a quote or a backslash in a path cannot end the value early
    /// or add a key.
    @Test func tomlStrings() {
        #expect(CodexInvocation.toml("plain") == #""plain""#)
        #expect(CodexInvocation.toml(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(CodexInvocation.toml("line\nbreak\ttab\u{01}") == #""line\nbreak\ttab\u0001""#)
        #expect(CodexInvocation.toml("café") == "\"café\"")
        #expect(CodexInvocation.toml(["x", #"y""#]) == #"["x","y\""]"#)
        #expect(CodexInvocation.toml([String]()) == "[]")
    }

    @Test func defaultsAndOverrides() {
        let d = CodexConfig(environment: [:])
        #expect(d.enabled && d.model == "gpt-6-luna" && d.effort == "low" && d.timeoutMS == "45000")
        #expect(!CodexConfig(environment: ["JARVIS_USE_CHATGPT": "0"]).enabled)
        #expect(CodexConfig(environment: ["JARVIS_USE_CHATGPT": "1"]).enabled)
        #expect(CodexConfig(environment: ["JARVIS_USE_CHATGPT": "false"]).enabled)   // only "0" turns it off
        #expect(CodexConfig(environment: ["JARVIS_CHATGPT_MODEL": "  "]).model == "gpt-6-luna")
        #expect(CodexConfig(environment: ["JARVIS_CHATGPT_MODEL": " gpt-test "]).model == "gpt-test")
        #expect(CodexConfig(environment: ["JARVIS_CHATGPT_TIMEOUT_MS": "9000"]).timeoutMS == "9000")
    }

    /// The catalog's one entry carries the system prompt and none of the fields that would add
    /// a built-in tool, the priority tier, or code mode.
    @Test func catalogEntry() throws {
        let value = CodexInvocation.catalog(model: "gpt-6-luna", instructions: "You are JARVIS.\nBe brief.")
        let models = try #require(value.objectValue?["models"]?.arrayValue)
        #expect(models.count == 1)
        let entry = try #require(models.first?.objectValue)
        #expect(entry["slug"] == .string("gpt-6-luna"))
        #expect(entry["base_instructions"] == .string("You are JARVIS.\nBe brief."))
        #expect(entry["shell_type"] == .string("disabled"))
        #expect(entry["experimental_supported_tools"] == .array([]))
        #expect(entry["default_reasoning_level"] == .string("low"))
        for key in ["tool_mode", "multi_agent_version", "apply_patch_tool_type", "web_search_tool_type",
                    "supports_search_tool", "default_service_tier", "service_tiers", "model_messages"] {
            #expect(entry[key] == nil, "\(key) is set")
        }
    }

    @Test func catalogFileIsPrivateAndExclusive() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let id = UUID()
        let url = try CodexInvocation.writeCatalog(in: box.root, turnID: id, model: "gpt-6-luna", instructions: "S")
        #expect(url == CodexInvocation.catalogURL(in: box.root, turnID: id))
        #expect(url.lastPathComponent == "turn-\(id.uuidString.lowercased()).codex-models.json")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let back = try PyJSON.loads(Data(contentsOf: url))
        #expect(back == CodexInvocation.catalog(model: "gpt-6-luna", instructions: "S"))
        #expect(throws: (any Error).self) {
            try CodexInvocation.writeCatalog(in: box.root, turnID: id, model: "gpt-6-luna", instructions: "S")
        }
    }

    /// The relay comes from the same per-turn MCP config Claude is given.
    @Test func relayFromTheTurnsMCPConfig() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let url = try ClaudeInvocation.writeMCPConfig(in: box.root, turnID: UUID(), command: "/opt/jarvis-test/JARVIS",
                                                      socket: "/tmp/s.sock", tokenFile: "/tmp/t.token")
        let relay = try CodexInvocation.Relay.read(mcpConfig: url)
        #expect(relay == CodexInvocation.Relay(command: "/opt/jarvis-test/JARVIS",
                                               arguments: ["--mcp-relay", "/tmp/s.sock", "--token-file", "/tmp/t.token"]))
        try box.write("bad.json", #"{"mcpServers":{"other":{}}}"#)
        #expect(throws: CodexInvocation.RelayConfigError.self) {
            try CodexInvocation.Relay.read(mcpConfig: box.root.appending(path: "bad.json"))
        }
    }
}
