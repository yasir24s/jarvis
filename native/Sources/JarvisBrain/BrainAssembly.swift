import Foundation
import JarvisCore
import JarvisTools

/// Builds the brain from its parts (plan: M02-M04 §3.5-§3.11): one confirmation gate, a
/// gateway that counts and logs, the MCP turn registry and server on the run directory, the
/// Claude driver, the on-device brain on the same gateway, the backend reporter, the router,
/// the personality upkeep (P1), the long-term memory (P2) and the turn coordinator. `start()`
/// creates the run directory and starts the server; `stop()` stops it.
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
    /// The personality upkeep (P1): the hourly consolidation check, and the distillation a
    /// typed dismissal starts through the coordinator's hook, both written by the
    /// collaborative writer. Not started here: the app starts it at launch and stops it
    /// before the lock is released.
    public let personality: PersonalitySchedule
    /// The long-term memory's fact compile (P2), run after the personality distillation in the
    /// same background task a dismissal starts, so it shares that task's start and stop. nil
    /// without a `memory` store.
    public let facts: FactCompiler?
    /// The long-term memory's recall (P2), which the router appends to each turn's prompt. nil
    /// without a `memory` store.
    public let recall: MemoryRecall?
    /// The `claude` found on the child's PATH, or nil. With none, the driver is given
    /// `~/.local/bin/claude` (where the installer puts it, first on that PATH), so each Claude
    /// turn fails with ENOENT ("Claude Code CLI not found") and falls back to the local model,
    /// as Python's does when the CLI is missing.
    public let claudeExecutable: URL?
    /// The state owner the personality tool bodies write through (`start()` registers them).
    private let core: CoreState

    /// - Parameters:
    ///   - research: every counter the brain bumps: the gateway's `taint_block`, the driver's,
    ///     the backend's and the router's.
    ///   - environment: the app's environment; the child env is built from it by
    ///     `ChildEnvironment`.
    ///   - claudeExecutable: overrides the PATH search (the smoke mode's stream tap).
    ///   - localBrain: builds the on-device brain on this assembly's gateway; nil means
    ///     `LocalBrain` (T3.6). Tests pass a fake.
    ///   - personaWriter: what consolidation and distillation are written by; nil means
    ///     `CollaborativePersonaLLM` over `LocalPersonaLLM` and a `ClaudePersonaLLM` with the
    ///     driver's config, executable, working directory, environment and `online`. Tests pass
    ///     a fake.
    ///   - memory: the long-term memory (D-51 P2) on the same lease-holding store; nil means
    ///     none: no archive, no fact compile and no recall.
    ///   - factWriter: what the fact compile is written by; nil means a `CollaborativePersonaLLM`
    ///     over the same two writers as the default persona writer, with
    ///     `FactExtraction.passesCheck` as its validator and Claude's input redacted
    ///     (`Redactor`, D-51 P3). Tests pass a fake.
    ///   - embedding: the sentence vectors for recall and duplicate merging.
    ///   - log: every log line of the parts, with its category. Tests pass their own.
    public init(core: CoreState, research: any ResearchCounting,
                config: ClaudeConfig, environment: [String: String],
                runDirectory: URL, claudeWorkingDirectory: URL, claudeExecutable: URL? = nil,
                localBrain: ((ToolGateway) -> any LocalGenerating)? = nil,
                personaWriter: (any PersonaLLM)? = nil,
                memory: MemoryStore? = nil, factWriter: (any AttributedWriting)? = nil,
                embedding: any SentenceEmbedding = SystemSentenceEmbedding(),
                textAuthenticator: any ConfirmAuthenticator, fastPath: any FastPathRouting = NoFastPath(),
                online: @escaping @Sendable () async -> Bool,
                onTurnStart: (@Sendable (TurnContext) -> Void)? = nil,
                log: @escaping @Sendable (String, LogCategory) -> Void = { JarvisLog.log($0, category: $1) }) {
        let brainLog: @Sendable (String) -> Void = { log($0, .brain) }
        self.core = core
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
        let vectors = FactVectors(embedding: embedding)
        let recall = memory.map { MemoryRecall(memory: $0, vectors: vectors) }
        self.recall = recall
        router = BrainRouter(core: core, config: config, claude: driver, local: local, backend: backend,
                             research: research, recall: recall, log: brainLog)
        // P1's two writers, shared by the persona writer and the fact compile (P2).
        let localWriter = LocalPersonaLLM()
        let claudeWriter = ClaudePersonaLLM(config: config, executable: executable,
                                            workingDirectory: claudeWorkingDirectory,
                                            parentEnvironment: environment, online: online, log: brainLog)
        let writer = personaWriter ?? CollaborativePersonaLLM(local: localWriter, claude: claudeWriter)
        let facts = memory.map {
            FactCompiler(memory: $0, writer: factWriter ?? Self.factWriter(local: localWriter, claude: claudeWriter),
                         vectors: vectors)
        }
        self.facts = facts
        // The convenience init's two closures, with the fact compile after the distillation.
        let personality = PersonalitySchedule(
            consolidate: { await core.consolidatePersonalityIfDue(using: writer) },
            distill: {
                await core.distillPersonalityIfDue(using: writer)
                await facts?.compile()
            })
        self.personality = personality
        coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: confirmations,
                                      textAuthenticator: textAuthenticator, online: online,
                                      onTurnStart: onTurnStart,
                                      onConversationEnded: { personality.conversationEnded() },
                                      archive: memory.map { MemoryArchiver(memory: $0) })
    }

    /// Registers the built-in tool bodies on the gateway (the system clock, the system time
    /// zone as `autoupdatingCurrent`, so a change of zone needs no restart, and the CoreState
    /// the personality tools write through), then creates the run directory (0700) and starts
    /// the MCP server on it.
    public func start() async throws {
        await BuiltInTools.register(on: gateway, core: core, clock: SystemClock(), timeZone: .autoupdatingCurrent)
        try await server.start()
    }

    public func stop() async {
        await server.stop()
    }

    /// The fact compile's default writer: P1's two writers collaborating under P2's validator,
    /// with what Claude is given redacted (D-51 P3) and the on-device model's input unchanged.
    static func factWriter(local: any PersonaLLM, claude: any PersonaLLM,
                           log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) })
        -> CollaborativePersonaLLM {
        CollaborativePersonaLLM(local: local, claude: claude, validator: FactExtraction.passesCheck,
                                name: "Memory writer", claudeInput: Redactor.redacted, log: log)
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
