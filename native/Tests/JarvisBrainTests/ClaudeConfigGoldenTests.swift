import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_claude_config_*.golden.json: jarvis.py's CLAUDE_* constants as the REAL module computed
/// them at import under each suite's environment (tools/golden_brain.py).
@Suite("M3 Claude config golden (jarvis.py CLAUDE_* block)")
struct ClaudeConfigGoldenTests {
    static let suites = ["m3_claude_config_default", "m3_claude_config_set", "m3_claude_config_blank",
                         "m3_claude_config_other"]

    @Test(arguments: suites)
    func matchesPython(_ suite: String) throws {
        let c = try #require(try Golden.cases(suite).first)
        var env: [String: String] = [:]
        for m in try #require(c.input.object("env")).members { env[m.key] = m.value.stringValue }
        let config = ClaudeConfig(environment: env)
        #expect(JSONValue.bool(config.enabled) == c.expected["enabled"])
        // D-5, the one decided difference: Python's None (no model set) is claude-opus-5-5 here.
        if c.expected["model"] == .null {
            #expect(config.model == ClaudeConfig.defaultModel)
        } else {
            #expect(JSONValue.string(config.model) == c.expected["model"])
        }
        #expect(JSONValue.string(config.effort) == c.expected["effort"])
        #expect(c.expected.int("max_turns") == Int64(config.maxTurns))
        #expect(JSONValue.string(config.timeoutMS) == c.expected["timeout_ms"])
    }

    /// Where Python's int() raises ValueError at import, native uses the default.
    @Test func unparsableMaxTurnsFallsBackToSix() {
        #expect(ClaudeConfig(environment: ["JARVIS_CLAUDE_MAX_TURNS": "abc"]).maxTurns == 6)
        #expect(ClaudeConfig(environment: ["JARVIS_CLAUDE_MAX_TURNS": "  "]).maxTurns == 6)
    }
}
