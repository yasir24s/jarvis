import Foundation
import JarvisCore
import JarvisTools

/// What the file scanner (D-51 P3) needs from the app: the folder to walk, JARVIS's state root
/// (never read), the lease-holding store its index is written through, the extractors, which
/// include JarvisApp's PDFKit and AppKit readers, and (P6) the user's consent.
public struct FileScanSetup: Sendable {
    public let home: URL
    public let stateRoot: URL
    public let store: StateStore
    public let extractors: TextExtractors
    /// P6: whether the user allows learning from their files ("Learn About Me From My Files").
    public let enabled: @Sendable () -> Bool

    public init(home: URL, stateRoot: URL, store: StateStore, extractors: TextExtractors,
                enabled: @escaping @Sendable () -> Bool = { true }) {
        self.home = home
        self.stateRoot = stateRoot
        self.store = store
        self.extractors = extractors
        self.enabled = enabled
    }
}

/// Builds the brain from its parts (plan: M02-M04 §3.5-§3.11): one confirmation gate, a
/// gateway that counts and logs, the MCP turn registry and server on the run directory, the
/// Claude driver, the on-device brain on the same gateway, the backend reporter, the router,
/// the personality upkeep (P1), the long-term memory (P2), the file scanner (P3) and the turn
/// coordinator. `start()`
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
    /// B2: the ChatGPT brain, through Codex on the user's ChatGPT sign-in, on the same relay.
    public let chatgpt: CodexDriver
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
    /// Each accepted turn, for background work that waits while one runs (P3).
    public let turnActivity: TurnActivity
    /// W1: the search database in memory/web/ (the conversations' index, part 7c). nil without a
    /// `memory` store.
    public let database: MemoryDatabase?
    /// W1 part 3: every page JARVIS reads, in the same database. nil without a `memory` store.
    public let webMemory: WebMemory?
    /// W1 part 6: the storage rule (10% of the drive for memory/, 3% of it kept free), checked
    /// after each web-store write; the app checks it at launch too. nil without a `memory` store.
    public let memoryBudget: MemoryBudget?
    /// W1 part 3: what summarises those pages: the on-device model within P3's budget, else the
    /// page's first sentences. Never Claude.
    public let pageSummarizer: any PageSummarizing
    /// W1 part 4: the pages waiting for a summary, summarised in the background while no turn
    /// runs. nil without a `memory` store. The app stops it at quit, before the lock is released.
    public let webSummaries: WebSummaryQueue?
    /// W1 part 4: web_search's deep mode (the reader, and the web memory that keeps each page),
    /// registered by `start()`. nil without a reader.
    private let webTools: BuiltInTools.Web?
    /// W1: the page reader, for the background reading pass (part 5).
    public let reader: (any PageReading)?
    /// W1 part 5: the background reading of news, pop culture and the user's interests, every
    /// three hours. nil without a `memory` store or a reader. Not started here: the app starts it
    /// once the brain has started and stops it at quit, before the lock is released.
    public let backgroundReader: BackgroundReader?
    /// P6: the fact compile after 30 idle minutes, beside the dismissal's. nil without a
    /// `memory` store. Not started here: the app starts it once the brain has started and stops
    /// it at quit, before the lock is released.
    public let idleCompile: IdleCompile?
    /// The memory tools' store and search (P4), registered by `start()`. nil without a
    /// `memory` store.
    private let memoryTools: BuiltInTools.Memory?
    /// Batch C: tools the app adds, served after the memory tools and registered at start.
    private let extraTools: [any ToolImpl]
    /// F1: alarms.json, which set_reminder and set_alarm write, registered by `start()`. nil
    /// means neither tool has a body.
    private let alarms: AlarmBook?
    /// PR2: what the fast path's own tools read from the app (the running apps), and the last
    /// reply the coordinator records for "copy that".
    private let quick: QuickPlatform
    public var lastReply: LastReply { quick.lastReply }
    /// The background reading of the user's files (P3), into the same facts. nil without a
    /// `memory` store or `files`. Not started here: the app starts it once the brain has
    /// started and stops it at quit, before the lock is released.
    public let fileScanner: FileScanner?
    /// The `claude` found on the child's PATH, or nil. With none, the driver is given
    /// `~/.local/bin/claude` (where the installer puts it, first on that PATH), so each Claude
    /// turn fails with ENOENT ("Claude Code CLI not found") and falls back to the local model,
    /// as Python's does when the CLI is missing.
    public let claudeExecutable: URL?
    /// B2: the `codex` CLI `CodexLocator` found, or nil. With none, the driver is given the
    /// override or the ChatGPT app's path, so each ChatGPT turn fails with "Codex CLI not found"
    /// and falls back to the local model.
    public let codexExecutable: URL?
    /// The state owner the personality tool bodies write through (`start()` registers them).
    private let core: CoreState

    /// - Parameters:
    ///   - research: every counter the brain bumps: the gateway's `taint_block`, the driver's,
    ///     the backend's and the router's.
    ///   - environment: the app's environment; the child env is built from it by
    ///     `ChildEnvironment`.
    ///   - claudeExecutable: overrides the PATH search (the smoke mode's stream tap).
    ///   - codexConfig: B2, the ChatGPT brain's settings; nil reads them from `environment`.
    ///   - codexWorkingDirectory: the empty folder `codex` runs in; nil means `codex-cwd/` beside
    ///     `claudeWorkingDirectory`.
    ///   - codexExecutable: overrides `CodexLocator` (the smoke mode's stream tap).
    ///   - codexHome: part 6, the `CODEX_HOME` of every codex child; nil means `CodexHome.directory`.
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
    ///   - files: what the file scanner needs from the app (P3); nil means no scanner. It reads
    ///     with the same two writers and merges into the same facts.
    ///   - reader: W1: what reads web pages (JarvisApp's WebKit reader); nil means web_search
    ///     has no deep mode and there is no background reading.
    ///   - waitForSilence: W1 part 5: returns once no reply is being spoken (the app's voice),
    ///     so the background reading waits while JARVIS talks.
    ///   - embedding: the sentence vectors for recall and duplicate merging.
    ///   - alarms: F1: the alarms and reminders set_reminder and set_alarm write; nil means
    ///     neither tool has a body.
    ///   - makeFastPath: PA batch A: builds the fast path on this assembly's confirmation gate;
    ///     when given, it replaces `fastPath`. PR2: with its gateway and backend report too.
    ///   - runningApps: PR2: the running apps, which the fast path's quit commands read.
    ///   - browserSetter: PR2: the default-browser switch ("make chrome my default browser").
    ///   - log: every log line of the parts, with its category. Tests pass their own.
    public init(core: CoreState, research: any ResearchCounting,
                config: ClaudeConfig, environment: [String: String],
                runDirectory: URL, claudeWorkingDirectory: URL, claudeExecutable: URL? = nil,
                codexConfig: CodexConfig? = nil, codexWorkingDirectory: URL? = nil, codexExecutable: URL? = nil,
                codexHome: URL? = nil,
                localBrain: ((ToolGateway) -> any LocalGenerating)? = nil,
                personaWriter: (any PersonaLLM)? = nil,
                memory: MemoryStore? = nil, factWriter: (any AttributedWriting)? = nil,
                files: FileScanSetup? = nil, reader: (any PageReading)? = nil,
                waitForSilence: @escaping @Sendable () async -> Void = {},
                embedding: any SentenceEmbedding = SystemSentenceEmbedding(),
                alarms: AlarmBook? = nil,
                textAuthenticator: any ConfirmAuthenticator, fastPath: any FastPathRouting = NoFastPath(),
                makeFastPath: ((FastPathParts) -> any FastPathRouting)? = nil,
                runningApps: any RunningAppsControlling = NoRunningApps(),
                browserSetter: any DefaultBrowserSetting = NoBrowserSetter(),
                online: @escaping @Sendable () async -> Bool,
                onTurnStart: (@Sendable (TurnContext) -> Void)? = nil,
                voiceConfirmation: VoiceConfirmation? = nil,
                brainChoice: @escaping @Sendable () -> BrainChoice = { .claude },
                extraTools: [any ToolImpl] = [],
                log: @escaping @Sendable (String, LogCategory) -> Void = { JarvisLog.log($0, category: $1) }) {
        let brainLog: @Sendable (String) -> Void = { log($0, .brain) }
        self.core = core
        self.extraTools = extraTools
        self.alarms = alarms
        let quick = QuickPlatform(runningApps: runningApps, browserSetter: browserSetter)
        self.quick = quick
        confirmations = ConfirmationGate()
        gateway = ToolGateway(confirmationGate: confirmations, log: { log($0, .tools) }, research: research,
                              journal: memory.map { ToolJournal(memory: $0) })
        registry = MCPTurnRegistry(runDirectory: runDirectory)
        let claudeTools = Self.claudeTools(memory: memory != nil, deepWeb: reader != nil,
                                           extra: extraTools.map { type(of: $0).schema })
        server = MCPServer(runDirectory: runDirectory, registry: registry, gateway: gateway,
                           tools: claudeTools.tools, log: brainLog)
        let backend = BackendReporter(research: research, log: brainLog)
        self.backend = backend

        let located = claudeExecutable ?? Self.locateClaude(environment: environment, config: config)
        self.claudeExecutable = located
        let home = environment["HOME"] ?? NSHomeDirectory()
        let executable = located ?? URL(fileURLWithPath: Py.rstrip(home, "/") + "/.local/bin/claude")
        driver = ClaudeDriver(config: config, executable: executable, bridge: registry,
                              workingDirectory: claudeWorkingDirectory, research: research, backend: backend,
                              parentEnvironment: environment, allowedTools: claudeTools.allowed, log: brainLog)
        // B2: ChatGPT gets the tools Claude is offered, by their MCP names.
        let codexConfig = codexConfig ?? CodexConfig(environment: environment)
        let codexLocated = codexExecutable ?? Self.locateCodex(environment: environment)
        self.codexExecutable = codexLocated
        let codexPath = codexLocated
            ?? URL(fileURLWithPath: environment[CodexConfig.executableKey] ?? ("/Applications/" + CodexLocator.appRelativePath))
        chatgpt = CodexDriver(config: codexConfig, executable: codexPath, bridge: registry,
                              workingDirectory: codexWorkingDirectory
                                  ?? claudeWorkingDirectory.deletingLastPathComponent()
                                  .appending(path: "codex-cwd", directoryHint: .isDirectory),
                              codexHome: codexHome ?? CodexHome.directory,
                              research: research, backend: backend, parentEnvironment: environment,
                              allowedTools: claudeTools.tools.map(\.name), log: brainLog,
                              preflight: { [home = codexHome ?? CodexHome.directory] in
                                  await CodexLogin(executable: codexPath, codexHome: home,
                                                   parentEnvironment: environment).status()
                              })
        let local = localBrain?(gateway) ?? LocalBrain(gateway: gateway, embedding: embedding, log: brainLog)
        let vectors = FactVectors(embedding: embedding)
        // W1 part 7c: search_memory reads the conversations and the journal from the index.
        // W1 part 3: and the pages JARVIS has read, from the web memory in the same database.
        let database = memory.map { MemoryDatabase(memory: $0) }
        self.database = database
        // W1 part 6: the storage rule is checked after every write to the web store.
        let hook = BudgetHook()
        let webMemory = database.map { WebMemory(database: $0, embedding: embedding, afterWrite: { hook.check() }) }
        self.webMemory = webMemory
        let budget = memory.flatMap { store in webMemory.map { MemoryBudget(memory: store, web: $0) } }
        if let budget { hook.set(budget) }
        memoryBudget = budget
        let recall = memory.map { store in
            MemoryRecall(memory: store, vectors: vectors, index: database.map { MemoryIndex(database: $0, memory: store) },
                         web: webMemory)
        }
        self.recall = recall
        memoryTools = memory.flatMap { store in recall.map { BuiltInTools.Memory(store: store, search: $0) } }
        router = BrainRouter(core: core, config: config, claude: driver, chatgpt: chatgpt,
                             chatgptEnabled: codexConfig.enabled, local: local, backend: backend,
                             research: research, recall: recall, choice: brainChoice, log: brainLog)
        // P1's two writers, shared by the persona writer and the fact compile (P2). B2 part 4:
        // they, and P3's file reading, stay on Claude whichever brain the Brain item picks for
        // replies; only JARVIS_USE_CLAUDE=0 moves them on-device.
        let localWriter = LocalPersonaLLM()
        let claudeWriter = ClaudePersonaLLM(config: config, executable: executable,
                                            workingDirectory: claudeWorkingDirectory,
                                            parentEnvironment: environment, online: online, log: brainLog)
        let writer = personaWriter ?? CollaborativePersonaLLM(local: localWriter, claude: claudeWriter)
        // MEM1 part 4: the memory writer's fallback when Claude cannot write: ChatGPT with no tools.
        let chatgptWriter = ChatGPTPersonaLLM(
            config: codexConfig, executable: codexPath,
            workingDirectory: codexWorkingDirectory
                ?? claudeWorkingDirectory.deletingLastPathComponent().appending(path: "codex-cwd", directoryHint: .isDirectory),
            codexHome: codexHome ?? CodexHome.directory, catalogDirectory: runDirectory,
            parentEnvironment: environment, online: online,
            preflight: { [home = codexHome ?? CodexHome.directory] in
                await CodexLogin(executable: codexPath, codexHome: home, parentEnvironment: environment).status()
            }, log: brainLog)
        let summarizer = FallbackSummarizer(LocalPageSummarizer(model: localWriter, budget: .system()))
        pageSummarizer = summarizer
        let turns = TurnActivity()
        turnActivity = turns
        let summaries = webMemory.map { WebSummaryQueue(memory: $0, summarizer: summarizer, turns: turns) }
        webSummaries = summaries
        self.reader = reader
        backgroundReader = memory.flatMap { store in
            webMemory.flatMap { web in
                reader.map { reader in
                    BackgroundReader(memory: web, facts: store, reader: reader, web: LiveWebFetch(), online: online,
                                     turns: turns, conditions: .init(waitForSilence: waitForSilence), summaries: summaries)
                }
            }
        }
        webTools = reader.map { reader in
            BuiltInTools.Web(reader: reader, keep: { page, query in
                webMemory?.store(page, source: .search, query: query)
                summaries?.kick()
            }, model: localWriter)   // PB: summarize_page and find_song_by_lyrics ask the on-device model
        }
        let facts = memory.map {
            FactCompiler(memory: $0, writer: factWriter ?? Self.factWriter(local: localWriter, claude: claudeWriter,
                                                                           chatgpt: chatgptWriter),
                         vectors: vectors, turns: turns)
        }
        self.facts = facts
        idleCompile = memory.flatMap { memory in facts.map { IdleCompile(compiler: $0, memory: memory, turns: turns) } }
        fileScanner = memory.flatMap { memory in
            files.map { files in
                let quota = ClaudeReadQuota()
                let reader = FileFactReader(memory: memory, local: localWriter, claude: claudeWriter,
                                            budget: .system(), quota: quota, turns: turns, vectors: vectors,
                                            userName: NSFullUserName())
                return FileScanner(home: files.home, stateRoot: files.stateRoot, store: files.store,
                                   extractors: files.extractors, reader: reader, quota: quota, turns: turns,
                                   enabled: files.enabled)
            }
        }
        // The convenience init's two closures, with the fact compile after the distillation.
        let personality = PersonalitySchedule(
            consolidate: { await core.consolidatePersonalityIfDue(using: writer) },
            distill: {
                await core.distillPersonalityIfDue(using: writer)
                await facts?.compile()
            })
        self.personality = personality
        // PA batch A: a fast path made here stashes into the gate this coordinator consumes.
        let fastPath = makeFastPath?(FastPathParts(
            confirmations: confirmations, tools: gateway,
            backendReport: { await backend.report(localModelName: BackendReporter.localDisplayName) })) ?? fastPath
        coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: confirmations,
                                      textAuthenticator: textAuthenticator, online: online,
                                      onTurnStart: onTurnStart,
                                      onConversationEnded: { personality.conversationEnded() },
                                      archive: memory.map { MemoryArchiver(memory: $0) }, activity: turns,
                                      voiceConfirmation: voiceConfirmation, lastReply: quick.lastReply)
    }

    /// Registers the built-in tool bodies on the gateway (the system clock, the system time
    /// zone as `autoupdatingCurrent`, so a change of zone needs no restart, and the CoreState
    /// the personality tools write through, and with a memory store the P4 memory tools), then
    /// creates the run directory (0700) and starts the MCP server on it.
    public func start() async throws {
        await BuiltInTools.register(on: gateway, core: core, clock: SystemClock(), timeZone: .autoupdatingCurrent,
                                    memory: memoryTools, web: webTools, alarms: alarms, quick: quick)
        // Batch C: the app's own tools (identify_song, the media catalogue, TV and AirPlay).
        for tool in extraTools { await gateway.register(tool) }
        try await server.start()
    }

    public func stop() async {
        await server.stop()
    }

    /// What Claude is offered: the Python catalog, then (P4), with a memory store, the native
    /// memory tools. The MCP server serves `tools` and `--allowedTools` lists `allowed`, which
    /// R3 requires to be the same set; without memory both are Python's 46.
    /// W1 part 4: with a page reader (`deepWeb`), web_search is offered with its deep flag.
    static func claudeTools(memory: Bool, deepWeb: Bool = false, extra: [ToolSchema] = []) -> (tools: [ToolSchema], allowed: [String]) {
        let python = deepWeb ? ToolCatalog.tools.map { $0.name == "web_search" ? NativeToolCatalog.webSearchDeep : $0 }
            : ToolCatalog.tools
        let tools = python + (memory ? NativeToolCatalog.memoryTools : []) + extra
        return (tools, tools.map { ClaudeInvocation.allowedToolName($0.name) })
    }

    /// The fact compile's default writer: P1's two writers collaborating under P2's validator,
    /// with what Claude is given redacted (D-51 P3) and the on-device model's input unchanged.
    /// MEM1 part 4: `chatgpt` is tried when Claude's call throws, with the same redacted input.
    static func factWriter(local: any PersonaLLM, claude: any PersonaLLM, chatgpt: (any PersonaLLM)? = nil,
                           log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) })
        -> CollaborativePersonaLLM {
        CollaborativePersonaLLM(local: local, claude: claude, chatgpt: chatgpt, validator: FactExtraction.passesCheck,
                                name: "Memory writer", claudeInput: Redactor.redacted, log: log)
    }

    /// `ClaudeLocator` over the PATH `ChildEnvironment` builds for the child.
    public static func locateClaude(environment: [String: String], config: ClaudeConfig) -> URL? {
        let child = ChildEnvironment.forClaude(parent: environment, config: config, assertOnDrop: false,
                                               log: { _ in })
        return ClaudeLocator.find(path: child["PATH"] ?? "")
    }

    /// B2: `CodexLocator` over `JARVIS_CODEX_CLI`, the PATH `ChildEnvironment.forCodex` builds,
    /// and the ChatGPT app's own copy.
    public static func locateCodex(environment: [String: String]) -> URL? {
        let child = ChildEnvironment.forCodex(parent: environment, codexHome: CodexHome.directory, assertOnDrop: false,
                                              log: { _ in })
        return CodexLocator.find(environment: environment, path: child["PATH"] ?? "",
                                 home: child["HOME"] ?? NSHomeDirectory())
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

/// PR2: what BrainAssembly gives the fast path it builds: the confirmation gate its coordinator
/// consumes, the gateway its helpers run through, and `_backend_report()`.
public struct FastPathParts: Sendable {
    public let confirmations: ConfirmationGate
    public let tools: ToolGateway
    public let backendReport: @Sendable () async -> String
}
