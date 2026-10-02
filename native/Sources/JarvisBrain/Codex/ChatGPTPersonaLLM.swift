import Foundation
import JarvisCore
import JarvisTools

/// MEM1 part 4: ChatGPT as a writer, the memory writer's fallback when Claude cannot write. One
/// `codex exec` through `CodexDriver` with no MCP server, so no tool at all (C2 stops any), under
/// JARVIS's own Codex home and every override a ChatGPT turn has. Like `ClaudePersonaLLM` it
/// counts nothing and reports no backend: this is not a turn.
///
/// `JARVIS_USE_CHATGPT=0` or offline: it throws without starting `codex`, as a turn falls back
/// there. Signed out, the sign-in check (`preflight`) throws before `codex exec` runs. Any
/// failure, a salvaged half-reply included, throws a reason that holds no model output.
public struct ChatGPTPersonaLLM: PersonaLLM {
    private let config: CodexConfig
    private let executable: URL
    private let workingDirectory: URL
    private let codexHome: URL
    private let catalogDirectory: URL
    private let parentEnvironment: [String: String]
    private let online: @Sendable () async -> Bool
    private let preflight: (@Sendable () async -> CodexLoginStatus)?
    private let log: @Sendable (String) -> Void

    /// - Parameters:
    ///   - config, executable, workingDirectory, codexHome, parentEnvironment: the turn driver's.
    ///   - catalogDirectory: where each call's model catalog is written (the run folder).
    ///   - online: the check a turn makes before trying ChatGPT.
    ///   - preflight: `codex login status` under the Codex home.
    public init(config: CodexConfig, executable: URL, workingDirectory: URL, codexHome: URL = CodexHome.directory,
                catalogDirectory: URL, parentEnvironment: [String: String],
                online: @escaping @Sendable () async -> Bool,
                preflight: (@Sendable () async -> CodexLoginStatus)? = nil,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.config = config
        self.executable = executable
        self.workingDirectory = workingDirectory
        self.codexHome = codexHome
        self.catalogDirectory = catalogDirectory
        self.parentEnvironment = parentEnvironment
        self.online = online
        self.preflight = preflight
        self.log = log
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        guard config.enabled else { throw PersonaWriterError.chatgptOff }
        guard await online() else { throw PersonaWriterError.offline }
        try Task.checkCancellation()
        let driver = CodexDriver(config: config, executable: executable, bridge: nil, catalogDirectory: catalogDirectory,
                                 workingDirectory: workingDirectory, codexHome: codexHome, quiet: true,
                                 research: NoCounts(), backend: NoBackend(), parentEnvironment: parentEnvironment,
                                 allowedTools: [], timeout: timeout, log: log, preflight: preflight)
        let outcome = await driver.outcome(system: system, user: user, turn: TurnContext(channel: .text),
                                           sink: Discarding())
        try Task.checkCancellation()
        if let error = outcome.error {
            throw PersonaWriterError.chatgptFailed(CodexReason.reason(error))
        }
        // The text as written, line breaks kept: a writer's reply is parsed line by line.
        guard outcome.reply != nil, !Py.strip(outcome.text).isEmpty else {
            throw PersonaWriterError.chatgptFailed("empty response")
        }
        return outcome.text
    }

    /// Nothing is counted: a writer call is not a turn.
    private struct NoCounts: ResearchCounting {
        func bump(_ key: String, by n: Int) {}
    }

    /// No backend is reported: a writer call is not a turn.
    private struct NoBackend: BackendReporting {
        func set(_ name: String) async {}
    }

    /// The reply is taken whole from the outcome; nothing is shown or spoken.
    private struct Discarding: ReplySink {
        func sentence(_ text: String) async {}
    }
}
