import Foundation
import JarvisCore

public enum CodexInvocationError: Error, Equatable {
    /// An argument equal to a forbidden flag (or `<flag>=…`) would have been emitted.
    case forbiddenFlag(String)
    /// An argument holding a forbidden sandbox value would have been emitted.
    case forbiddenValue(String)
}

/// The argv for one `codex exec` turn (B2), the sibling of `ClaudeInvocation`. Found against
/// codex-cli 0.159.2 (`codex exec --help`, `codex features list`, and the request the CLI sends
/// to a local stand-in for the model server):
///
/// - The user's `~/.codex/config.toml` is never loaded (`--ignore-user-config`), so its
///   `sandbox_mode = "danger-full-access"`, its MCP servers, profiles and hooks never apply.
///   Every setting that matters is given here, and `--strict-config` makes a key this CLI no
///   longer knows an error, so a renamed setting fails the turn instead of being dropped.
/// - The model comes from a per-turn catalog file (`catalog(model:instructions:)`): JARVIS's
///   system prompt is its base instructions, and it leaves out code mode, sub-agents,
///   apply_patch, web search and the shell, which codex's own catalog turns on for every
///   current model and no flag turns off.
/// - Every feature that brings a built-in tool or loads the user's own setup is disabled
///   (`disabledFeatures`), as defence in depth behind the catalog.
/// - JARVIS's tools are the existing per-turn relay, configured for this run only, offered
///   directly (not deferred behind a tool search), approved by JARVIS's gateway rather than by
///   codex, and limited to `enabledTools`.
/// - The sandbox is read-only with approval "never", and the prompt goes in on stdin (`-`),
///   so the message never shows in a process listing.
public struct CodexInvocation: Sendable, Equatable {
    /// Never emitted: each skips the sandbox or approvals, loads other configuration or files,
    /// or points the CLI somewhere other than the user's ChatGPT sign-in.
    public static let forbiddenFlags = ["--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
                                        "--approve-for-me", "--full-auto", "--yolo", "--add-dir", "--worktree",
                                        "--profile", "-p", "--oss", "--local-provider", "--remote", "--image", "-i"]
    /// Never inside any argument: the sandbox modes that can write.
    public static let forbiddenValues = ["danger-full-access", "workspace-write"]
    public static let serverName = "jarvis"
    /// The sandbox, always.
    public static let sandbox = "read-only"
    /// codex-cli 0.159.2's features that bring a built-in tool (shell, code mode, sub-agents,
    /// browser, computer use, images, sleep), load the user's own setup (apps, plugins, skills,
    /// hooks, memories, goals), or run more than the one turn asked for. `fast_mode` would put
    /// the turn on the priority tier, which spends more of the plan; `unbounded_connection_retries`
    /// would keep an offline turn retrying until the timeout.
    public static let disabledFeatures = [
        "shell_tool", "unified_exec", "unified_exec_tty", "shell_snapshot", "code_mode_host",
        "multi_agent", "multi_agent_v2", "apps", "plugins", "remote_plugin", "plugin_sharing",
        "skill_search", "skill_mcp_dependency_install", "tool_suggest", "hooks", "memories", "goals",
        "image_generation", "view_image", "browser_use", "browser_use_external", "browser_use_full_cdp_access",
        "computer_use", "sleep_tool", "workspace_dependencies", "worktrees", "guardian_approval", "fast_mode",
        "daemon_auto_start", "realtime_conversation", "unbounded_connection_retries",
    ]

    /// The relay that serves JARVIS's tools for one turn: the command and arguments the
    /// per-turn MCP config names (`ClaudeInvocation.mcpConfig`).
    public struct Relay: Sendable, Equatable {
        public let command: String
        public let arguments: [String]

        public init(command: String, arguments: [String]) {
            self.command = command
            self.arguments = arguments
        }

        /// The `jarvis` server in a per-turn MCP config file, as `MCPTurnRegistry` writes it.
        public static func read(mcpConfig url: URL) throws -> Relay {
            let value = try PyJSON.loads(Data(contentsOf: url))
            guard case .object(let root) = value, case .object(let servers)? = root["mcpServers"],
                  case .object(let server)? = servers[serverName], case .string(let command)? = server["command"],
                  case .array(let args)? = server["args"] else {
                throw RelayConfigError()
            }
            var arguments: [String] = []
            for arg in args {
                guard case .string(let s) = arg else { throw RelayConfigError() }
                arguments.append(s)
            }
            return Relay(command: command, arguments: arguments)
        }
    }

    public struct RelayConfigError: Error, Equatable, CustomStringConvertible {
        public var description: String { "MCP config has no jarvis server" }
    }

    public let executable: URL
    public let arguments: [String]

    /// argv for one turn. `enabledTools` are the MCP tool names as the server lists them, in
    /// TOOLS order.
    public init(executable: URL, workingDirectory: URL, catalog: URL, relay: Relay, enabledTools: [String],
                config: CodexConfig) throws(CodexInvocationError) {
        var a = ["exec", "--json", "--ephemeral", "--ignore-user-config", "--ignore-rules", "--strict-config",
                 "--skip-git-repo-check", "--color", "never",
                 "--cd", workingDirectory.path(percentEncoded: false),
                 "--model", config.model,
                 "--sandbox", Self.sandbox,
                 "-c", "approval_policy=" + Self.toml("never")]
        if !config.effort.isEmpty {
            a += ["-c", "model_reasoning_effort=" + Self.toml(config.effort)]
        }
        a += ["-c", "model_catalog_json=" + Self.toml(catalog.path(percentEncoded: false)),
              "-c", "web_search=" + Self.toml("disabled"),
              "-c", "tools.experimental_request_user_input.enabled=false",
              "-c", "features.code_mode.excluded_tool_namespaces=" + Self.toml(["clock", "functions"]),
              "-c", "skills.include_instructions=false",
              "-c", "include_permissions_instructions=false",
              "-c", "include_apps_instructions=false",
              "-c", "include_collaboration_mode_instructions=false",
              "-c", "include_environment_context=false",
              "-c", "history.persistence=" + Self.toml("none"),
              "-c", "shell_environment_policy.inherit=" + Self.toml("none"),
              "-c", "check_for_update_on_startup=false"]
        for feature in Self.disabledFeatures {
            a += ["--disable", feature]
        }
        let server = "mcp_servers." + Self.serverName + "."
        a += ["-c", server + "command=" + Self.toml(relay.command),
              "-c", server + "args=" + Self.toml(relay.arguments),
              "-c", server + "required=true",
              "-c", server + "startup_timeout_sec=10",
              "-c", server + "omit_tools_from=" + Self.toml(["code_mode", "deferred"]),
              "-c", server + "default_tools_approval_mode=" + Self.toml("approve"),
              "-c", server + "enabled_tools=" + Self.toml(enabledTools),
              "-"]
        try Self.refuseForbidden(a)
        self.executable = executable
        self.arguments = a
    }

    /// Throws for an argument equal to a forbidden flag or starting with `<flag>=`, or one that
    /// holds a forbidden sandbox value anywhere.
    private static func refuseForbidden(_ a: [String]) throws(CodexInvocationError) {
        for arg in a {
            if forbiddenFlags.contains(where: { Py.eq(arg, $0) || Py.startsWith(arg, $0 + "=") }) {
                throw .forbiddenFlag(arg)
            }
            if forbiddenValues.contains(where: { Py.contains(arg, $0) }) {
                throw .forbiddenValue(arg)
            }
        }
    }

    /// A TOML basic string: `"`, `\` and the control characters escaped, everything else as is.
    public static func toml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// A TOML array of basic strings.
    public static func toml(_ list: [String]) -> String {
        "[" + list.map { toml($0) }.joined(separator: ",") + "]"
    }

    /// `<directory>/turn-<uuid>.codex-models.json`, the uuid lowercased.
    public static func catalogURL(in directory: URL, turnID: UUID) -> URL {
        directory.appending(path: "turn-\(turnID.uuidString.lowercased()).codex-models.json", directoryHint: .notDirectory)
    }

    /// The turn's model catalog: one entry for `model`, with `instructions` (JARVIS's system
    /// prompt) as its base instructions. The fields codex-cli 0.159.2 requires are set, and the
    /// ones that would add a built-in tool are left out: `tool_mode` (code mode),
    /// `multi_agent_version` (sub-agents), `apply_patch_tool_type`, `web_search_tool_type`,
    /// `supports_search_tool`; `shell_type` is "disabled". With no `default_service_tier` the
    /// turn runs on the standard tier.
    public static func catalog(model: String, instructions: String) -> JSONValue {
        func level(_ effort: String, _ description: String) -> JSONValue {
            .object(JSONObject([.init(key: "effort", value: .string(effort)),
                                .init(key: "description", value: .string(description))]))
        }
        let entry = JSONObject([
            .init(key: "slug", value: .string(model)),
            .init(key: "display_name", value: .string(model)),
            .init(key: "base_instructions", value: .string(instructions)),
            .init(key: "supported_reasoning_levels", value: .array([level("low", "Fast responses with lighter reasoning"),
                                                                    level("medium", "Balanced"),
                                                                    level("high", "Deeper reasoning")])),
            .init(key: "default_reasoning_level", value: .string("low")),
            .init(key: "shell_type", value: .string("disabled")),
            .init(key: "visibility", value: .string("list")),
            .init(key: "supported_in_api", value: .bool(true)),
            .init(key: "priority", value: .int(1)),
            .init(key: "support_verbosity", value: .bool(true)),
            .init(key: "default_verbosity", value: .string("low")),
            .init(key: "truncation_policy", value: .object(JSONObject([.init(key: "mode", value: .string("tokens")),
                                                                       .init(key: "limit", value: .int(10000))]))),
            .init(key: "experimental_supported_tools", value: .array([])),
            .init(key: "context_window", value: .int(272_000)),
            .init(key: "input_modalities", value: .array([.string("text")])),
        ])
        return .object(JSONObject([.init(key: "models", value: .array([.object(entry)]))]))
    }

    /// Writes the catalog to `catalogURL(in:turnID:)`, created exclusively (O_CREAT|O_EXCL|
    /// O_NOFOLLOW) with mode 0600, and returns its URL. `directory` must already exist.
    public static func writeCatalog(in directory: URL, turnID: UUID, model: String, instructions: String) throws -> URL {
        let url = catalogURL(in: directory, turnID: turnID)
        let bytes = Data(PyJSON.dumps(catalog(model: model, instructions: instructions)).utf8)
        let fd = open(url.path(percentEncoded: false), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard fchmod(fd, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try handle.write(contentsOf: bytes)
        try handle.close()
        return url
    }
}
