import Foundation
import JarvisCore

/// jarvis.py's CLAUDE_* block (plan: M02-M04 §3.6), read from an environment:
///
///     CLAUDE_ENABLED    = os.environ.get("JARVIS_USE_CLAUDE", "1") != "0"
///     CLAUDE_MODEL      = os.environ.get("JARVIS_CLAUDE_MODEL", "").strip() or None
///     CLAUDE_EFFORT     = os.environ.get("JARVIS_CLAUDE_EFFORT", "low").strip()
///     CLAUDE_MAX_TURNS  = int(os.environ.get("JARVIS_CLAUDE_MAX_TURNS", "6") or "6")
///     CLAUDE_TIMEOUT_MS = os.environ.get("JARVIS_CLAUDE_TIMEOUT_MS", "45000")
///
/// Golden suites m3_claude_config_* record Python's values. Two decided differences:
/// - D-5: with no model set, `model` is "claude-opus-5-5", where Python passes None (the
///   CLI's own default).
/// - Where Python's int() raises at import (a non-integer JARVIS_CLAUDE_MAX_TURNS, or
///   underscores and non-ASCII digits, which int() accepts and Int() does not), `maxTurns`
///   is 6. Surrounding whitespace is stripped first, as int() does.
public struct ClaudeConfig: Sendable, Equatable {
    public static let defaultModel = "claude-opus-5-5"

    public var enabled: Bool
    public var model: String
    /// "" means no `--effort` flag (`effort or None`).
    public var effort: String
    public var maxTurns: Int
    /// Passed verbatim as the child's API_TIMEOUT_MS.
    public var timeoutMS: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        enabled = !Py.eq(environment["JARVIS_USE_CLAUDE"] ?? "1", "0")
        let model = Py.strip(environment["JARVIS_CLAUDE_MODEL"] ?? "")
        self.model = model.isEmpty ? Self.defaultModel : model
        effort = Py.strip(environment["JARVIS_CLAUDE_EFFORT"] ?? "low")
        let turns = environment["JARVIS_CLAUDE_MAX_TURNS"] ?? "6"
        maxTurns = Int(Py.strip(turns.isEmpty ? "6" : turns)) ?? 6
        timeoutMS = environment["JARVIS_CLAUDE_TIMEOUT_MS"] ?? "45000"
    }
}
