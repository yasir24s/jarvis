import Foundation

// Conversation memory (plan: M01 §2.7, §3.7). Mirrors jarvis.py _history_load /
// _history_save / _history, process_command's inline history statements and
// _claude_history_preamble; proven against Python by the `m1_history_app` golden suite.
//
// The caller loads once (Python does it at import) with `HistoryLog.load(store.load(.history))`
// and saves with `store.save(.history, log.serialized())` — history.json is compact.

public struct HistoryLog: Sendable, Equatable {
    /// `[-12:]` in _history_load, _history_save and process_command's trim.
    public static let cap = 12
    /// `_history_load` keeps only these roles.
    public static let roles = ["user", "assistant"]

    /// The in-memory `_history`. It may briefly hold 13 turns: an assistant turn is appended
    /// without a trim, and only the save and the next user turn cut it back to 12.
    public private(set) var turns: [JSONObject]

    public init() {
        turns = []
    }

    /// `_history_load`: the dict entries whose "role" is "user" or "assistant", last 12, every
    /// key kept. Anything but a JSON array (nil = Python's except branch) gives an empty log.
    public static func load(_ raw: JSONValue?) -> HistoryLog {
        var log = HistoryLog()
        guard case .array(let items)? = raw else { return log }
        let kept: [JSONObject] = items.compactMap { item in
            guard case .object(let t) = item, case .string(let role)? = t["role"],
                  roles.contains(where: { Py.eq($0, role) }) else { return nil }
            return t
        }
        log.turns = Py.tail(kept, cap)
        return log
    }

    /// `_history.append({"role": "user", "content": text}); _history = _history[-12:]`.
    public mutating func appendUser(_ text: String) {
        turns.append(Self.turn("user", text))
        turns = Py.tail(turns, Self.cap)
    }

    /// `_history.append({"role": "assistant", "content": text})` — no trim.
    public mutating func appendAssistant(_ text: String) {
        turns.append(Self.turn("assistant", text))
    }

    /// `if _history and _history[-1].get("role") == "user": _history.pop()`.
    public mutating func popTrailingUser() {
        if let last = turns.last, last["role"] == .string("user") {
            turns.removeLast()
        }
    }

    /// What `_history_save` writes: `_history[-12:]`.
    public func serialized() -> JSONValue {
        .array(Py.tail(turns, Self.cap).map { .object($0) })
    }

    /// `_claude_history_preamble`: over `_history[-7:-1]` (the just-appended user turn is
    /// excluded), "User: " / "You: " + the stripped non-empty content, one per line.
    ///
    /// Divergence `history-nonstring-content` (hand-edited history.json only): a truthy
    /// non-string content makes Python raise AttributeError; native skips that turn.
    public func claudePreamble() -> String {
        let n = turns.count
        let lo = max(0, n - 7), hi = max(0, n - 1)
        var lines: [String] = []
        if lo < hi {
            for m in turns[lo..<hi] {
                let content: String
                switch m["content"] {
                case .string(let s)?: content = Py.strip(s)
                case let v? where v.pyTruthy: continue                    // Python: AttributeError
                default: content = ""                                     // missing or falsy → ""
                }
                if !content.isEmpty {
                    lines.append((m["role"] == .string("user") ? "User: " : "You: ") + content)
                }
            }
        }
        return lines.isEmpty ? "" : "\n\nRecent conversation:\n" + lines.joined(separator: "\n")
    }

    private static func turn(_ role: String, _ content: String) -> JSONObject {
        JSONObject([.init(key: "role", value: .string(role)), .init(key: "content", value: .string(content))])
    }
}
