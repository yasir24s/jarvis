import Foundation
import JarvisCore

/// B2: a ChatGPT failure turned into the short reason logged with the local-model fallback,
/// as `ClaudeReason` does for Claude. The messages are codex-cli 0.159.2's: "unexpected status
/// 401 Unauthorized: …" when signed out, "exceeded retry limit, last status: 429 Too Many
/// Requests" or "You've hit your usage limit…" when rate limited, "Reconnecting... waiting for
/// network (Connection failed: error sending request)" when offline, and the locator's
/// "enoent: codex" when the CLI is not installed.
public enum CodexReason {
    /// The first group with a keyword in the lowered message wins.
    static let groups: [(keys: [String], reason: String)] = [
        (["usage limit", "429", "rate limit", "too many requests", "overload"], "rate limited"),
        (["401", "403", "unauthor", "not logged in", "not signed in", "login", "log in", "sign in"], "not signed in"),
        (["timeout", "timed out", "cancel"], "timed out"),
        (["enoent", "codex cli not found"], "Codex CLI not found"),
        (["waiting for network", "error sending request", "connection", "network", "resolve", "dns", "unreach"],
         "network unreachable"),
    ]

    public static func reason(_ message: String) -> String {
        let s = Py.lower(message)
        for group in groups where group.keys.contains(where: { Py.contains(s, $0) }) {
            return group.reason
        }
        let stripped = Py.strip(message)
        return Py.prefix(stripped.isEmpty ? "unavailable" : stripped, 80)
    }
}
