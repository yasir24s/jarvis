import Foundation

// emotions.json (plan: M01 §2.3, §3.7). Mirrors jarvis.py _EMO_DIMS, _emotions_load,
// _emotions_decay, _EMO_DELTAS, emotion_event, the praise/thanks/insult classifiers,
// emotion_react, _EMO_BANDS, _emo_word and emotion_context; proven against Python by the
// `m1_emotions_tone` golden suite.
//
// Numbers are read with `pyFloat` (JSON ints and bools allowed; a string raises, §8 R8) and
// the arithmetic keeps Python's operation order: `max(0.0, (now - at) / 60.0)`,
// `pow(0.5, dt / half)` (Darwin libm, the pow CPython's float.__pow__ calls),
// `base + (v - base) * factor` and `min(1.0, max(0.0, v + d * mag))`. One `now` per call
// stands for Python's up-to-three time.time() reads (§8 R13).

public enum EmotionLogic {
    public struct Dim: Sendable {
        public let name: String
        public let baseline: Double
        public let halfLifeMinutes: Double
    }

    /// `_EMO_DIMS`, in dict order: (baseline, half-life in minutes).
    public static let dims: [Dim] = [
        Dim(name: "mood", baseline: 0.60, halfLifeMinutes: 90.0),
        Dim(name: "energy", baseline: 0.60, halfLifeMinutes: 45.0),
        Dim(name: "warmth", baseline: 0.70, halfLifeMinutes: 240.0),
        Dim(name: "patience", baseline: 0.80, halfLifeMinutes: 30.0),
    ]

    /// `_EMO_DELTAS`, in dict order. `task_ok` is defined but jarvis.py never emits it; native
    /// callers must not either (§8 R11).
    public static let deltas: [(event: String, changes: [(dim: String, delta: Double)])] = [
        ("praise", [("mood", +0.15), ("warmth", +0.10), ("energy", +0.05)]),
        ("gratitude", [("mood", +0.08), ("warmth", +0.06)]),
        ("insult", [("patience", -0.18), ("mood", -0.05)]),
        ("task_ok", [("mood", +0.03)]),
        ("task_fail", [("mood", -0.08), ("patience", -0.08)]),
        ("barge_in", [("patience", -0.10)]),
        ("user_urgent", [("energy", +0.06)]),
        ("corrected", [("mood", -0.04), ("patience", -0.04)]),
    ]

    /// `_EMO_BANDS`, in dict order: five words per dimension, low to high.
    public static let bands: [(dim: String, words: [String])] = [
        ("mood", ["genuinely displeased", "flat", "even-keeled", "quietly pleased", "quietly delighted"]),
        ("energy", ["running on fumes", "subdued", "steady", "crisp", "crackling"]),
        ("warmth", ["cool", "professional", "cordial", "fond", "genuinely fond"]),
        ("patience", ["at the end of your tether", "wearing thin", "adequate", "ample", "infinite"]),
    ]

    public static let praisePattern = compile(
        #"\b(good (?:job|work|one)|well done|brilliant|amazing|impressive|perfect|nailed it|love (?:you|it|that)|you'?re (?:the best|awesome|great|hilarious|good))\b"#)
    public static let thanksPattern = compile(
        #"\b(thank(?:s| you)|cheers|appreciate (?:it|you))\b"#)
    public static let insultPattern = compile(
        #"\byou(?:'re| are)? (?:(?:fucking|bloody|damn|so|absolutely|completely|utterly|such) )*(?:useless|stupid|an? idiot|dumb|shit|crap|rubbish|hopeless|pathetic)\b|\b(?:shut up|fuck (?:you|off)|piss off)\b|\b(?:stupid|dumb|useless) (?:machine|robot|assistant|program)\b"#)

    /// The research counter an event bumps, `"emotion_" + name`.
    public static func counterKey(_ event: String) -> String { "emotion_" + event }

    /// The seed `_emotions_load` falls back to: every baseline, then `"at": now`.
    public static func seed(now: Double) -> JSONObject {
        JSONObject(dims.map { JSONObject.Member(key: $0.name, value: .double($0.baseline)) }
                   + [JSONObject.Member(key: "at", value: .double(now))])
    }

    /// `_emotions_load`: the file when `all(k in e for k in _EMO_DIMS)` holds, else the seed.
    /// A list or str passes that test by *containing* every name, and Python then raises in
    /// `_emotions_decay` (AttributeError), so those shapes throw here. `raw` is nil when
    /// `json.load` would raise.
    public static func load(_ raw: JSONValue?, now: Double) throws(StateShapeError) -> JSONObject {
        switch raw {
        case .object(let o)? where dims.allSatisfy({ o[$0.name] != nil }):
            return o
        case .array(let a)? where dims.allSatisfy({ d in a.contains { $0 == .string(d.name) } }):
            throw shape("a list naming every dimension ('list' has no attribute 'get')")
        case .string(let s)? where dims.allSatisfy({ Py.contains(s, $0.name) }):
            throw shape("a str containing every dimension ('str' has no attribute 'get')")
        default:
            return seed(now: now)
        }
    }

    /// `_emotions_decay`: each dimension relaxes toward its baseline by
    /// `0.5 ** (dt_min / half)`, dt clamped at 0 (a clock that went backwards decays nothing);
    /// then `"at" = now`. No clamp. A missing dimension counts as its baseline, a missing
    /// "at" as now. Throws where `float()` or the subtraction raises.
    public static func decay(_ e: inout JSONObject, now: Double) throws(StateShapeError) {
        var at = now
        if let v = e["at"] {
            guard let d = v.pyFloat else { throw shape("\"at\" is not a number (TypeError)") }
            at = d
        }
        let dtMin = Py.pyMax(0.0, (now - at) / 60.0)
        var decayed: [(String, Double)] = []
        for d in dims {
            let factor = pow(0.5, dtMin / d.halfLifeMinutes)
            var v = d.baseline
            if let x = e[d.name] {
                guard let f = x.pyFloat else { throw shape("\"\(d.name)\" is not a number (float() raises)") }
                v = f
            }
            decayed.append((d.name, d.baseline + (v - d.baseline) * factor))
        }
        for (k, v) in decayed { e[k] = .double(v) }
        e["at"] = .double(now)
    }

    /// The deltas `emotion_event(name)` applies; nil for an unknown name (a no-op in Python:
    /// no load, no save, no bump).
    public static func changes(for event: String) -> [(dim: String, delta: Double)]? {
        deltas.first { Py.eq($0.event, event) }?.changes
    }

    /// emotion_event's update, on a decayed object: `e[k] = min(1.0, max(0.0, e[k] + d * mag))`
    /// per delta, in `_EMO_DELTAS` order. False = unknown event (`e` untouched).
    @discardableResult
    public static func apply(_ event: String, magnitude: Double = 1.0,
                             to e: inout JSONObject) throws(StateShapeError) -> Bool {
        guard let changes = changes(for: event) else { return false }
        for (k, d) in changes {
            guard let v = e[k]?.pyFloat else { throw shape("\"\(k)\" is missing or not a number") }
            e[k] = .double(Py.pyMin(1.0, Py.pyMax(0.0, v + d * magnitude)))
        }
        return true
    }

    /// `emotion_react`'s decision: insult, then praise, then gratitude; at most one event.
    public static func classify(_ text: String) -> String? {
        if insultPattern.search(text) != nil { return "insult" }
        if praisePattern.search(text) != nil { return "praise" }
        if thanksPattern.search(text) != nil { return "gratitude" }
        return nil
    }

    /// `_emo_word(k, v)`: `_EMO_BANDS[k][min(4, max(0, int(v * 5)))]`. `int()` truncates
    /// toward zero; NaN and ±inf raise in Python, and throw here.
    public static func word(_ dim: String, _ v: Double) throws(StateShapeError) -> String {
        guard let words = bands.first(where: { Py.eq($0.dim, dim) })?.words else {
            throw shape("no band for \(dim.debugDescription) (KeyError)")
        }
        let x = v * 5
        guard x.isFinite else { throw shape("\(dim) is \(PyFloat.repr(v)): int() of a non-finite float") }
        let t = x.rounded(.towardZero)
        return words[t >= 4 ? 4 : (t <= 0 ? 0 : Int(t))]
    }

    /// `emotion_context()`'s sentence over an already-decayed object.
    public static func context(_ e: JSONObject) throws(StateShapeError) -> String {
        func w(_ k: String) throws(StateShapeError) -> String {
            guard let v = e[k] else { throw shape("no \"\(k)\" (KeyError)") }
            guard let d = v.pyFloat else { throw shape("\"\(k)\" is not a number") }
            return try word(k, d)
        }
        let mood = try w("mood"), energy = try w("energy"), warmth = try w("warmth")
        let patience = try w("patience")
        return " CURRENT EMOTIONAL STATE (virtual; shifts with how the day goes) — "
            + "mood: \(mood); energy: \(energy); "
            + "warmth toward the user: \(warmth); "
            + "patience: \(patience). Let this subtly colour word "
            + "choice, pacing, and wit — a touch warmer, terser, or drier as it moves. If asked "
            + "how you feel, answer honestly from this state, in character; never recite it as data."
    }

    // MARK: - Helpers

    private static func compile(_ pattern: String) -> PyRegex {
        do { return try PyRegex(pattern, ignoreCase: true) } catch {
            preconditionFailure("EmotionLogic: \(error)")
        }
    }

    private static func shape(_ detail: String) -> StateShapeError {
        StateShapeError(file: .emotions, detail: detail)
    }
}

// MARK: - The Python functions, with their file IO and counter bumps

public extension EmotionLogic {
    /// `emotion_event(name, mag)`: load → decay → apply → save, then (after the save, as
    /// Python bumps after releasing its lock) `research_bump("emotion_" + name)`. Returns false
    /// for an unknown name, which touches nothing.
    @discardableResult
    static func event(_ name: String, magnitude: Double = 1.0, store: StateStore, now: Double,
                      research: any ResearchCounting) throws(StateShapeError) -> Bool {
        guard changes(for: name) != nil else { return false }
        var e = try load(store.load(.emotions), now: now)
        try decay(&e, now: now)
        try apply(name, magnitude: magnitude, to: &e)
        store.save(.emotions, .object(e))
        research.bump(counterKey(name), by: 1)
        return true
    }

    /// `emotion_react(text)`: classify, then `event`. Returns the event it fired, if any.
    @discardableResult
    static func react(_ text: String, store: StateStore, now: Double,
                      research: any ResearchCounting) throws(StateShapeError) -> String? {
        guard let name = classify(text) else { return nil }
        try event(name, store: store, now: now, research: research)
        return name
    }

    /// `emotion_context()`: load → decay → SAVE (every prompt build writes emotions.json,
    /// §8 R12), then the sentence. A non-finite value throws after the save, as in Python.
    static func context(store: StateStore, now: Double) throws(StateShapeError) -> String {
        var e = try load(store.load(.emotions), now: now)
        try decay(&e, now: now)
        store.save(.emotions, .object(e))
        return try context(e)
    }
}
