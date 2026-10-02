import Foundation
import JarvisCore

/// B2: the ChatGPT brain's settings, read from an environment the way `ClaudeConfig` reads its
/// own. JARVIS reaches ChatGPT through the Codex CLI on the user's ChatGPT sign-in.
///
///     JARVIS_USE_CHATGPT         "0" turns the ChatGPT brain off for the launch (default on)
///     JARVIS_CHATGPT_MODEL       the model (default "gpt-6-luna")
///     JARVIS_CHATGPT_EFFORT      the reasoning effort (default "low"; "" leaves it to the model)
///     JARVIS_CHATGPT_TIMEOUT_MS  the turn's budget in milliseconds (default "45000")
///     JARVIS_CODEX_CLI           the `codex` executable, ahead of the search (`CodexLocator`)
public struct CodexConfig: Sendable, Equatable {
    /// "Fast and affordable model for easier tasks" in codex-cli 0.159.2's model catalog.
    public static let defaultModel = "gpt-6-luna"
    public static let defaultEffort = "low"
    public static let defaultTimeoutMS = "45000"
    /// The environment variable that names the `codex` executable.
    public static let executableKey = "JARVIS_CODEX_CLI"

    public var enabled: Bool
    public var model: String
    /// "" means no `model_reasoning_effort` override.
    public var effort: String
    public var timeoutMS: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        enabled = !Py.eq(environment["JARVIS_USE_CHATGPT"] ?? "1", "0")
        let model = Py.strip(environment["JARVIS_CHATGPT_MODEL"] ?? "")
        self.model = model.isEmpty ? Self.defaultModel : model
        effort = Py.strip(environment["JARVIS_CHATGPT_EFFORT"] ?? Self.defaultEffort)
        let timeout = Py.strip(environment["JARVIS_CHATGPT_TIMEOUT_MS"] ?? "")
        timeoutMS = timeout.isEmpty ? Self.defaultTimeoutMS : timeout
    }
}
