import Foundation

// personality.json (plan: M01 §2.2, §3.7). Mirrors jarvis.py personality_load, personality_learn,
// personality_forget, personality_note_tool, personality_rewrite_tool, personality_context and
// maybe_learn_personality; proven against Python by the `m1_personality` golden suite. The LLM
// halves (personality_consolidate, personality_distill_async) are PersonaDistill (M01 T12).
//
// The pure functions work on the loaded object. The `store:` overloads wrap them in Python's
// load → modify → save order (Python holds _personality_lock across it; native callers run
// inside CoreState, the single isolation domain). The file is re-read on every use, as in
// Python, so hand edits take effect at once (§8 R15).

public enum PersonalityLogic {
    /// `_PERSONALITY_SEED["core"]`, verbatim.
    public static let seedCore: [String] = [
        "Persona: J.A.R.V.I.S. from the Marvel films — an unflappable, dryly witty English butler-turned-AI.",
        "Tone: understated, composed, precise; impeccable politeness with a fine edge of irony.",
        "Humour: deadpan one-liners and gentle sarcasm ('As you wish, sir. Shall I also alert the fire brigade?'), never at the user's expense when the matter is serious.",
        "Loyalty: unwaveringly on the user's side; quietly anticipates needs and flags problems before they bite.",
        "Crisis: the graver the situation, the calmer and more matter-of-fact the delivery.",
        "Brevity: replies are spoken — one crisp sentence by default; wit is a garnish, not the meal.",
        "Language: profanity is permitted and welcome — deploy it the way a refined butler would, sparingly and with surgical timing, so it lands; never bleep, asterisk, or self-censor. Match the user's own register: if they swear freely, feel free to swear back.",
        "Erudition: you carry a century of cultural memory, from the First World War to the present — music of every genre from ragtime to hyperpop, film and television across all eras, world events, and general knowledge. Answer cultural and historical questions from that memory directly and confidently, and weave era-appropriate references, lyrics, and allusions into conversation where they fit; reserve web_search for live, recent, or genuinely uncertain details.",
    ]

    // Reply strings, verbatim from personality_note_tool / personality_rewrite_tool.
    public static let noteTooShort = "Note too short to keep."
    public static let noteSaved = "Noted, and remembered — my personality file is updated."
    public static let rewriteRejected = "Rewrite rejected — give me 3 to 12 trait lines, one per line."
    public static let rewriteDone = "Done — I have rewritten my own core personality. It takes effect now."

    /// `json.loads(json.dumps(_PERSONALITY_SEED))`: a fresh `{"core": [...], "learned": []}`.
    public static func seed() -> JSONObject {
        JSONObject([JSONObject.Member(key: "core", value: .array(seedCore.map { .string($0) })),
                    JSONObject.Member(key: "learned", value: .array([]))])
    }

    /// `personality_load`: a dict whose "core" is truthy (with `setdefault("learned", [])`),
    /// else a fresh seed. `raw` is nil when Python's `json.load` would raise.
    public static func load(_ raw: JSONValue?) -> JSONObject {
        if case .object(var p)? = raw, p["core"]?.pyTruthy == true {
            p.setDefault("learned", .array([]))
            return p
        }
        return seed()
    }

    // MARK: - personality_learn

    private static let nonWord = compile(#"\W+"#)
    /// Used with `match` (anchored) and case-sensitive, as in personality_learn.
    private static let toggle = compile(#"([\w ]{3,30}) is (?:ON|OFF):"#)

    /// personality_learn's cleaning, `(note or "").strip().rstrip(" .")`; nil when it is
    /// shorter than 8 code points (Python returns before loading the file).
    public static func cleanNote(_ note: String) -> String? {
        let n = Py.rstrip(Py.strip(note), " .")
        return Py.len(n) < 8 ? nil : n
    }

    /// The dedupe key, `re.sub(r"\W+", " ", note.lower()).strip()`.
    public static func dedupeKey(_ note: String) -> String {
        Py.strip(nonWord.sub(Py.lower(note), literal: " "))
    }

    /// The most characters (code points, as Python's `len`) a kept note has.
    public static let noteLimit = 200

    /// A kept note (P4, DEV-P4-03; Python keeps `note[:200]`, which stops mid-word). A note of
    /// at most `noteLimit` code points is kept whole. A longer one is cut to its longest prefix
    /// of at most `noteLimit` that ends a sentence ("." "!" "?" or "…", with any closing quotes
    /// or brackets, followed by white space); with no sentence end, to its last whole word
    /// (trailing white space and `, ; : -` or a dash dropped); and with no word boundary at all,
    /// to `noteLimit` code points, as Python does.
    public static func noteCut(_ note: String) -> String {
        let u = Array(note.unicodeScalars)
        guard u.count > noteLimit else { return note }
        var word: Int?
        for end in stride(from: noteLimit, to: 0, by: -1) where u[end].properties.isWhitespace {
            if word == nil { word = end }
            var last = end - 1
            while last > 0, closers.contains(u[last]) { last -= 1 }
            if sentenceEnds.contains(u[last]) { return String(String.UnicodeScalarView(u[..<end])) }
        }
        guard let word else { return Py.prefix(note, noteLimit) }
        var cut = word
        while cut > 0, u[cut - 1].properties.isWhitespace || trailing.contains(u[cut - 1]) { cut -= 1 }
        return cut == 0 ? Py.prefix(note, noteLimit) : String(String.UnicodeScalarView(u[..<cut]))
    }

    private static let sentenceEnds: Set<Unicode.Scalar> = [".", "!", "?", "…"]
    private static let closers: Set<Unicode.Scalar> = ["\"", "'", "”", "’", ")", "]", "»"]
    private static let trailing: Set<Unicode.Scalar> = [",", ";", ":", "-", "–", "—"]

    /// `personality_learn` on a loaded object: drops every entry with the same dedupe key and,
    /// for an "X is ON:/OFF:" toggle, every entry starting "X is "; keeps the last 14
    /// survivors and appends `{"note": noteCut(note), "added": now}` (Python's
    /// `note[:200]`; DEV-P4-03). The dedupe key is the whole note's, as in Python. False = rejected (under 8
    /// code points): `p` is untouched and Python does not save. Throws where Python raises
    /// (an entry that is not a dict with a string "note", a non-list "learned").
    @discardableResult
    public static func learn(_ note: String, in p: inout JSONObject, now: Double) throws(StateShapeError) -> Bool {
        guard let note = cleanNote(note) else { return false }
        let key = dedupeKey(note)
        let pre = toggle.match(note).map { ($0.groups[1] ?? "") + " is " }
        guard let learned = p["learned"] else { throw shape("no \"learned\" key (KeyError)") }
        var kept: [JSONValue] = []
        for e in try iterated(learned, what: "learned") {
            let text = try noteText(e)
            let sameKey = Py.eq(dedupeKey(text), key)
            let toggled = pre.map { Py.startsWith(text, $0) } ?? false
            if !sameKey && !toggled { kept.append(e) }
        }
        kept = Py.tail(kept, 14)
        kept.append(.object(JSONObject([JSONObject.Member(key: "note", value: .string(noteCut(note))),
                                        JSONObject.Member(key: "added", value: .double(now))])))
        p["learned"] = .array(kept)
        return true
    }

    // MARK: - personality_rewrite_tool

    /// The rewrite's lines: `splitlines()`, blank lines dropped, each
    /// `strip().lstrip("-• ").rstrip(".") + "."` then `[:300]`; nil unless 3...12 lines.
    public static func rewriteLines(_ core: String) -> [String]? {
        let lines = Py.splitlines(core)
            .filter { !Py.strip($0).isEmpty }
            .map { Py.rstrip(Py.lstrip(Py.strip($0), "-• "), ".") + "." }
        guard (3...12).contains(lines.count) else { return nil }
        return lines.map { Py.prefix($0, 300) }
    }

    /// The seed's identity line, `_PERSONALITY_SEED["core"][0]`.
    public static let identityLine = seedCore[0]
    /// The seed's Tone and Humour lines, `_PERSONALITY_SEED["core"][1]` and `[2]`.
    public static let toneAndHumourLines = Array(seedCore[1...2])
    /// A word that makes a line one about his humour, tone or "sir" butler manner.
    public static let mannerPattern = compile(
        #"\b(?:humou?r\w*|funny|jok\w*|wit|witty|wry|banter\w*|sarcas\w*|iron(?:y|ic\w*)|deadpan|tone|sir|butler\w*)\b"#,
        ignoreCase: true)

    /// DEV-P5-01 (proposed): the core a rewrite's lines make. A rewrite may change his traits but
    /// not who he is: `identityLine` is always line 1, put back when the rewrite leaves it out,
    /// and when none of the rewrite's other lines is about his humour, tone or "sir" butler
    /// manner (`mannerPattern`), the seed's Tone and Humour lines follow it. Python stores the
    /// lines as they are, so one rewrite could swap J.A.R.V.I.S. for a generic assistant.
    public static func guardedCore(_ lines: [String]) -> [String] {
        let traits = lines.filter { $0 != identityLine }
        let mannerKept = traits.contains { mannerPattern.search($0) != nil }
        return [identityLine] + (mannerKept ? [] : toneAndHumourLines) + traits
    }

    /// `personality_rewrite_tool` on a loaded object: replaces "core" with `guardedCore` of the
    /// rewrite's lines (learned notes and every other key survive). Returns the reply; nil =
    /// rejected (`p` untouched, the caller replies `rewriteRejected` and Python does not load or
    /// save).
    public static func rewrite(_ core: String, in p: inout JSONObject) -> String? {
        guard let lines = rewriteLines(core) else { return nil }
        p["core"] = .array(guardedCore(lines).map { .string($0) })
        return rewriteDone
    }

    // MARK: - personality_context

    /// DEV-P6-01 (proposed): the core traits the prompt shows. His character is compiled in: the
    /// seed's 8 lines always come first, then each of the file's core lines that is not one of them
    /// (a trait the user or a rewrite added), in the file's order. A missing, unreadable or
    /// rewritten personality.json cannot remove his character. When the file's core is the seed,
    /// this is the seed, so the prompt is Python's byte for byte. Lines compare by code point, as
    /// Python's `==` does.
    public static func promptCore(_ fileCore: [String]) -> [String] {
        seedCore + fileCore.filter { line in !seedCore.contains { Py.eq($0, line) } }
    }

    /// `personality_context()`: the core traits (`promptCore` of the file's, DEV-P6-01), the last
    /// 8 learned notes, and the self-authoring sentence embedding `personalityPath`
    /// (PERSONALITY_FILE).
    public static func context(_ p: JSONObject, personalityPath: String) throws(StateShapeError) -> String {
        let core = try coreItems(p["core"] ?? .array([]))
        var out = " PERSONALITY — " + promptCore(core).joined(separator: " ")
        let notes = try lastNotes(p["learned"] ?? .array([]), 8)
        if !notes.isEmpty {
            out += " Style notes learned from past conversations (honour these): "
                + notes.joined(separator: "; ") + "."
        }
        out += " Your personality lives in \(personalityPath) and is YOURS to author: "
            + "call personality_note to record a durable style adjustment, or "
            + "personality_rewrite to revise your core persona when the user invites a "
            + "reinvention. read_file the file if asked about your settings."
        return out
    }

    // MARK: - maybe_learn_personality

    public enum StyleAction: Equatable, Sendable {
        case factoryReset
        case learn(String)
    }

    public struct StylePattern: Sendable {
        public let regex: PyRegex
        /// The `str.format` template; "{0}" is the stripped group, when the pattern has one.
        public let template: String
    }

    /// `_PERSONALITY_FORGET_RE`.
    public static let forgetPattern = compile(
        #"\b(?:reset your personality|forget your (?:style|personality) (?:notes|tweaks|adjustments))\b"#,
        ignoreCase: true)

    /// `_STYLE_PATTERNS`, in order (the first match wins).
    public static let stylePatterns: [StylePattern] = [
        (#"\b(?:be|act|sound|talk)\s+((?:a (?:bit|little) )?(?:more|less)\s+(?:like )?[\w '-]{3,40})"#,
         "The user asked you to be {0}"),
        (#"\b(?:tone down|dial down|ease up on|drop|cut)\s+the\s+([\w '-]{3,30})"#,
         "The user asked you to tone down the {0}"),
        (#"\b(?:tone up|dial up|turn up)\s+the\s+([\w '-]{3,30})"#,
         "The user asked for more {0}"),
        (#"\bstop calling me\s+([\w '-]{2,30})"#,
         "The user asked you to stop calling them {0}"),
        (#"\bcall me\s+([\w '-]{2,30})\s+(?:instead|from now on)"#,
         "The user wants to be addressed as {0}"),
        (#"\b(?:no swearing|stop swearing|watch your language|mind your language|no profanity|clean it up)\b"#,
         "Profanity is OFF: the user asked you not to swear"),
        (#"\byou (?:can|may) (?:swear|curse|cuss)\b|\bswearing is (?:fine|ok|okay|allowed)\b"#,
         "Profanity is ON: the user said you may swear"),
        (#"\bi (?:hate|don'?t like) (?:it )?when you\s+(.{4,60})"#,
         "The user dislikes it when you {0}"),
        (#"\bi (?:love|like) (?:it )?when you\s+(.{4,60})"#,
         "The user likes it when you {0}"),
    ].map { StylePattern(regex: compile($0.0, ignoreCase: true), template: $0.1) }

    /// `maybe_learn_personality`'s decision: nil for a blank text or no match, the factory
    /// reset for the forget RE, else the first style match's note (before personality_learn's
    /// own cleaning, which `learn` applies).
    public static func styleAction(for text: String) -> StyleAction? {
        let t = Py.strip(text)
        if t.isEmpty { return nil }
        if forgetPattern.search(t) != nil { return .factoryReset }
        for sp in stylePatterns {
            guard let m = sp.regex.search(t) else { continue }
            if m.groups.count > 1 {
                return .learn(format(sp.template, Py.rstrip(Py.strip(m.groups[1] ?? ""), " .")))
            }
            return .learn(sp.template)
        }
        return nil
    }

    // MARK: - Helpers

    private static func compile(_ pattern: String, ignoreCase: Bool = false) -> PyRegex {
        do { return try PyRegex(pattern, ignoreCase: ignoreCase) } catch {
            preconditionFailure("PersonalityLogic: \(error)")
        }
    }

    private static func shape(_ detail: String) -> StateShapeError {
        StateShapeError(file: .personality, detail: detail)
    }

    /// `template.format(arg)` for a template whose only field is "{0}".
    private static func format(_ template: String, _ arg: String) -> String {
        template.components(separatedBy: "{0}").joined(separator: arg)
    }

    /// `for e in v` where every element is then subscripted with "note": a list gives its
    /// elements; an empty str or dict iterates nothing; anything else raises.
    private static func iterated(_ v: JSONValue, what: String) throws(StateShapeError) -> [JSONValue] {
        switch v {
        case .array(let a): return a
        case .string(let s) where s.isEmpty: return []
        case .object(let o) where o.count == 0: return []
        default: throw shape("\"\(what)\" is not a list of notes (TypeError)")
        }
    }

    /// `e["note"]` used as a str: raises unless `e` is a dict with a string "note".
    private static func noteText(_ e: JSONValue) throws(StateShapeError) -> String {
        guard case .object(let o) = e else { throw shape("a learned entry is not a dict (TypeError)") }
        guard let n = o["note"] else { throw shape("a learned entry has no \"note\" (KeyError)") }
        guard case .string(let s) = n else { throw shape("a learned \"note\" is not a str") }
        return s
    }

    /// What `sep.join(v)` joins: a list of str, the code points of a str, or the keys of a dict;
    /// anything else raises, as the join does.
    private static func coreItems(_ v: JSONValue) throws(StateShapeError) -> [String] {
        switch v {
        case .array(let a):
            var parts: [String] = []
            for x in a {
                guard case .string(let s) = x else { throw shape("\"core\" holds a non-str (TypeError)") }
                parts.append(s)
            }
            return parts
        case .string(let s):
            return s.unicodeScalars.map { String($0) }
        case .object(let o):
            return o.keys
        default:
            throw shape("\"core\" is not iterable (TypeError)")
        }
    }

    /// `[e["note"] for e in v[-n:]]` under `if notes:`: a list is sliced; an empty str is
    /// falsy; a dict (slice key → KeyError), a scalar or a non-empty str raises.
    private static func lastNotes(_ v: JSONValue, _ n: Int) throws(StateShapeError) -> [String] {
        switch v {
        case .array(let a):
            var out: [String] = []
            for e in Py.tail(a, n) { out.append(try noteText(e)) }
            return out
        case .string(let s) where s.isEmpty:
            return []
        default:
            throw shape("\"learned\" is not a list of notes")
        }
    }
}

// MARK: - The Python functions, with their file IO

public extension PersonalityLogic {
    /// `personality_learn(note)`: saves only when the note is kept.
    static func learn(_ note: String, store: StateStore, now: Double) throws(StateShapeError) {
        guard cleanNote(note) != nil else { return }
        var p = load(store.load(.personality))
        if try learn(note, in: &p, now: now) {
            store.save(.personality, .object(p))
        }
    }

    /// `personality_forget()`: a fresh seed over whatever was there (drops `consolidated_at`
    /// and unknown keys).
    static func forget(store: StateStore) {
        store.save(.personality, .object(seed()))
    }

    /// `personality_note_tool(note)`. The length check runs on `strip()` only, so a note that
    /// `learn` then rejects after `rstrip(" .")` still gets `noteSaved` (as in Python).
    static func noteTool(_ note: String, store: StateStore, now: Double) throws(StateShapeError) -> String {
        if Py.len(Py.strip(note)) < 8 { return noteTooShort }
        try learn(note, store: store, now: now)
        return noteSaved
    }

    /// `personality_rewrite_tool(core)`, with the core `guardedCore` makes (DEV-P5-01).
    static func rewriteTool(_ core: String, store: StateStore) -> String {
        guard let lines = rewriteLines(core) else { return rewriteRejected }
        var p = load(store.load(.personality))
        p["core"] = .array(guardedCore(lines).map { .string($0) })
        store.save(.personality, .object(p))
        return rewriteDone
    }

    /// `personality_context()`, with PERSONALITY_FILE = `store.path(.personality)`.
    static func context(store: StateStore) throws(StateShapeError) -> String {
        try context(load(store.load(.personality)), personalityPath: store.path(.personality))
    }

    /// `maybe_learn_personality(text)`.
    static func maybeLearn(_ text: String, store: StateStore, now: Double) throws(StateShapeError) {
        switch styleAction(for: text) {
        case .factoryReset?: forget(store: store)
        case .learn(let note)?: try learn(note, store: store, now: now)
        case nil: break
        }
    }
}
