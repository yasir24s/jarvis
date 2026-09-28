import Foundation

// The deterministic halves of personality consolidation and distillation (plan: M01 §2.2,
// §3.7; jarvis.py personality_consolidate, personality_distill_async). This type builds the
// exact system and user strings Python sends to the model, and applies Python's eligibility
// rules and reply filters. The call itself belongs to CoreState, through the injected
// PersonaLLM. It is proven against the real functions, with ollama_post faked, by the
// `m1_persona_llm` golden suite.

public enum PersonaDistill {
    /// personality_consolidate's system message, verbatim.
    public static let consolidateSystem =
        "You maintain the persona file of a JARVIS voice assistant. Merge these "
        + "style notes into at most 8 distinct notes: combine duplicates and "
        + "near-duplicates keeping the strongest and most recent phrasing; drop "
        + "nothing genuinely distinct; where notes conflict, the LATER one wins. "
        + "Reply with ONLY the merged notes, one per line, no bullets or numbering."

    /// personality_distill_async's system message, verbatim.
    public static let distillSystem =
        "You maintain the persona file of a JARVIS voice assistant. From the "
        + "conversation, extract AT MOST ONE durable preference about HOW the "
        + "assistant should speak or behave (tone, humour, form of address, "
        + "verbosity). Ignore one-off tasks and facts about the user's life. "
        + "Reply with just the preference as one short sentence starting "
        + "'The user ', or exactly NONE."

    /// `ollama_post(..., timeout=120)` in personality_consolidate.
    public static let consolidateTimeout: Duration = .seconds(120)
    /// `ollama_post(..., timeout=60)` in personality_distill_async.
    public static let distillTimeout: Duration = .seconds(60)

    // MARK: - Consolidation

    /// `len(notes) >= 10 and time.time() - p.get("consolidated_at", 0) >= 7 * 86400`, written
    /// as Python's `not (… < …)` so a NaN `consolidated_at` counts as due, as it does there.
    /// False wherever Python raises before the call: `len()` of a value with no length, a
    /// `consolidated_at` that is not a number, an int too large for a float.
    public static func consolidationDue(_ p: JSONObject, now: Double) -> Bool {
        guard let n = pyLen(p["learned"] ?? .array([])), n >= 10 else { return false }
        let at: Double
        switch p["consolidated_at"] {
        case nil: at = 0
        case .int(let i)?: at = Double(i)
        case .double(let d)?: at = d
        case .bool(let b)?: at = b ? 1 : 0
        case .bigInt(let s)?:
            guard let d = Double(s), d.isFinite else { return false }     // OverflowError
            at = d
        default: return false                                               // TypeError
        }
        return !(now - at < 7 * 86400)
    }

    /// `"\n".join("- " + e["note"] for e in notes)`. Throws where Python raises inside its try
    /// (logged, no call): "learned" is not a list, or an entry is not a dict with a str "note".
    public static func consolidationListing(_ p: JSONObject) throws(StateShapeError) -> String {
        guard case .array(let notes)? = p["learned"] else { throw shape("\"learned\" is not a list of notes") }
        var parts: [String] = []
        for e in notes {
            guard case .object(let o) = e else { throw shape("a learned entry is not a dict (TypeError)") }
            guard let n = o["note"] else { throw shape("a learned entry has no \"note\" (KeyError)") }
            guard case .string(let s) = n else { throw shape("a learned \"note\" is not a str (TypeError)") }
            parts.append("- " + s)
        }
        return parts.joined(separator: "\n")
    }

    /// `[l.strip().lstrip("-• ")[:200] for l in reply.splitlines() if len(l.strip()) >= 8]`.
    /// The length test runs before the bullets are stripped, as in Python.
    public static func consolidationCandidates(fromReply r: String) -> [String] {
        Py.splitlines(r).filter { Py.len(Py.strip($0)) >= 8 }.map { Py.prefix(Py.lstrip(Py.strip($0), "-• "), 200) }
    }

    /// The candidates, or nil unless there are 1 to 8 (Python's "rejected" path).
    public static func consolidationLines(fromReply r: String) -> [String]? {
        let lines = consolidationCandidates(fromReply: r)
        return (1...8).contains(lines.count) ? lines : nil
    }

    // MARK: - Distillation

    /// The inverse of `time.time() - _last_distill < 900 or len(_history) < 4`.
    public static func distillDue(historyCount: Int, lastDistill: Double, now: Double) -> Bool {
        !(now - lastDistill < 900 || historyCount < 4)
    }

    /// `"\n".join(f"{m['role']}: {(m.get('content') or '')[:200]}" for m in turns if
    /// m.get("content"))` over `turns[-10:]` (so passing `_history` or its last 10 is the same).
    /// Throws where Python's worker raises before the call (logged, no call): a turn with no
    /// "role", or a truthy content that is not a str. A truthy list content is sliced and
    /// formatted by Python; native throws for it too (only a hand-edited history.json has one).
    public static func distillConversation(_ turns: [JSONObject]) throws(StateShapeError) -> String {
        var lines: [String] = []
        for m in Py.tail(turns, 10) {
            guard let content = m["content"], content.pyTruthy else { continue }
            guard let role = m["role"] else { throw history("a turn has no \"role\" (KeyError)") }
            guard case .string(let r) = role else { throw history("a turn's \"role\" is not a str") }
            guard case .string(let s) = content else { throw history("a turn's content is not a str") }
            lines.append(r + ": " + Py.prefix(s, 200))
        }
        return lines.joined(separator: "\n")
    }

    /// `note = reply.strip()`, kept if `note.lower().startswith("the user") and len(note) < 200`.
    /// The kept note then goes through personality_learn, which cleans it again.
    public static func distillNote(fromReply r: String) -> String? {
        let note = Py.strip(r)
        return Py.startsWith(Py.lower(note), "the user") && Py.len(note) < 200 ? note : nil
    }

    // MARK: - Helpers

    /// `len(v)`: a list's items, a str's code points, a dict's keys; nil = TypeError.
    private static func pyLen(_ v: JSONValue) -> Int? {
        switch v {
        case .array(let a): a.count
        case .string(let s): Py.len(s)
        case .object(let o): o.count
        default: nil
        }
    }

    private static func shape(_ detail: String) -> StateShapeError {
        StateShapeError(file: .personality, detail: detail)
    }

    private static func history(_ detail: String) -> StateShapeError {
        StateShapeError(file: .history, detail: detail)
    }
}
