import Foundation
import JarvisCore

/// jarvis.py `_claude_reason` (plan: M02-M04 §3.6): a Claude failure message turned into the
/// short reason spoken and logged with the local-model fallback. Proven by golden suite
/// m3_claude_reason.
public enum ClaudeReason {
    /// The keyword groups in Python's order; the first group with a keyword in the lowered
    /// message wins. Matching is code-point substring search, like Python's `k in s`.
    static let groups: [(keys: [String], reason: String)] = [
        (["credit", "billing", "quota", "insufficient", "payment"], "no Agent SDK credit"),
        (["401", "403", "unauthor", "not signed", "login"], "not signed in"),
        (["429", "rate", "overload"], "rate limited"),
        (["timeout", "timed out", "cancel"], "timed out"),
        (["not found", "clinotfound", "enoent"], "Claude Code CLI not found"),
        (["connection", "network", "resolve", "dns", "unreach"], "network unreachable"),
    ]

    /// `_claude_reason(e)` where `message == str(e)`.
    public static func reason(_ message: String) -> String {
        let s = Py.lower(message)
        for group in groups where group.keys.contains(where: { Py.contains(s, $0) }) {
            return group.reason
        }
        let stripped = Py.strip(message)
        return Py.prefix(stripped.isEmpty ? "unavailable" : stripped, 80)
    }
}
