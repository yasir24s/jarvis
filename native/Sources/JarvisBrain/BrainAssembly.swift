import Foundation
import JarvisCore
import JarvisTools

/// Builds the brain from its parts (plan: M02-M04 §3.5-§3.11): one confirmation gate, a
/// gateway that counts and logs, the MCP turn registry and server on the run directory, the
/// Claude driver, the on-device brain on the same gateway, the backend reporter, the router
/// and the turn coordinator. `start()` creates
/// the run directory and starts the server; `stop()` stops it.
public final class BrainAssembly: Sendable {
    /// `~/Library/Application Support/JARVIS/`, which holds `run/` and `claude-cwd/`
    /// (plan §3.6, §3.7).
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "JARVIS", directoryHint: .isDirectory)
    }

    public let confirmations: ConfirmationGate
    public let gateway: ToolGateway
    public let registry: MCPTurnRegistry
    public let server: MCPServer
    public let backend: BackendReporter
    public let driver: ClaudeDriver
    public let router: BrainRouter
    public let coordinator: TurnCoordinator
    /// The `claude` found on the child's PATH, or nil. With none, the driver is given
    /// `~/.local/bin/claude` (where the installer puts it, first on that PATH), so each Claude
    /// turn fails with ENOENT ("Claude Code CLI not found") and falls back to the local model,
    /// as Python's does when the CLI is missing.
    public let claudeExecutable: URL?

    /// - Parameters:
    ///   - research: every counter the brain bumps: the gateway's `taint_block`, the driver's,
    ///     the backend's and the router's.
    ///   - environment: the app's environment; the child env is built from it by
    ///     `ChildEnvironment`.
    ///   - claudeExecutable: overrides the PATH search (the smoke mode's stream tap).
    ///   - localBrain: builds the on-device brain on this assembly's gateway; nil means
    ///     `LocalBrain` (T3.6). Tests pass a fake.
    ///   - log: every log line of the parts, with its category. Tests pass their own.
    public init(core: CoreState, research: any ResearchCounting,
                config: ClaudeConfig, environment: [String: String],
                runDirectory: URL, claudeWorkingDirectory: URL, claudeExecutable: URL? = nil,
                localBrain: ((ToolGateway) -> any LocalGenerating)? = nil,
                textAuthenticator: any ConfirmAuthenticator, fastPath: any FastPathRouting = NoFastPath(),
                online: @escaping @Sendable () async -> Bool,
                onTurnStart: (@Sendable (TurnContext) -> Void)? = nil,
                log: @escaping @Sendable (String, LogCategory) -> Void = { JarvisLog.log($0, category: $1) }) {
        let brainLog: @Sendable (String) -> Void = { log($0, .brain) }
        confirmations = ConfirmationGate()
        gateway = ToolGateway(confirmationGate: confirmations, log: { log($0, .tools) }, research: research)
        registry = MCPTurnRegistry(runDirectory: runDirectory)
        server = MCPServer(runDirectory: runDirectory, registry: registry, gateway: gateway, log: brainLog)
        backend = BackendReporter(research: research, log: brainLog)

        let located = claudeExecutable ?? Self.locateClaude(environment: environment, config: config)
        self.claudeExecutable = located
        let home = environment["HOME"] ?? NSHomeDirectory()
        let executable = located ?? URL(fileURLWithPath: Py.rstrip(home, "/") + "/.local/bin/claude")
        driver = ClaudeDriver(config: config, executable: executable, bridge: registry,
                              workingDirectory: claudeWorkingDirectory, research: research, backend: backend,
                              parentEnvironment: environment, log: brainLog)
        let local = localBrain?(gateway) ?? LocalBrain(gateway: gateway, log: brainLog)
        router = BrainRouter(core: core, config: config, claude: driver, local: local, backend: backend,
                             research: research, log: brainLog)
        coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: confirmations,
                                      textAuthenticator: textAuthenticator, online: online,
                                      onTurnStart: onTurnStart)
    }

    /// Registers the built-in tool bodies on the gateway (the system clock, and the system time
    /// zone as `autoupdatingCurrent`, so a change of zone needs no restart), then creates the
    /// run directory (0700) and starts the MCP server on it.
    public func start() async throws {
        await BuiltInTools.register(on: gateway, clock: SystemClock(), timeZone: .autoupdatingCurrent)
        try await server.start()
    }

    public func stop() async {
        await server.stop()
    }

    /// `ClaudeLocator` over the PATH `ChildEnvironment` builds for the child.
    public static func locateClaude(environment: [String: String], config: ClaudeConfig) -> URL? {
        let child = ChildEnvironment.forClaude(parent: environment, config: config, assertOnDrop: false,
                                               log: { _ in })
        return ClaudeLocator.find(path: child["PATH"] ?? "")
    }

    /// Reads an app secret from the keychain and registers it with `registry` before returning
    /// it, so the log redacts it and `ChildEnvironment` drops any variable that holds it
    /// (plan §3.11). `SecretStore.read` itself does not register what it reads.
    public static func secret(account: String, registry: SecretRegistry = .shared,
                              read: (String, String) -> String? = { SecretStore.read(service: $0, account: $1) })
        -> String? {
        guard let value = read(SecretStore.service, account) else { return nil }
        registry.register(value)
        return value
    }
}
