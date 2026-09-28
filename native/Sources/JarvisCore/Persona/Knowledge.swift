import Foundation

// knowledge.json (plan: M01 §2.4, §3.7). Mirrors jarvis.py kb_load, kb_remember, kb_lookup,
// kb_note_topic and kb_context; proven against Python by the `m1_profile_kb` golden suite.
// The web fetch that feeds kb_remember is M6's. None of these functions bumps a research
// counter.
//
// A parseable file that is not a dict, or lacks "topics", makes Python raise (KeyError /
// TypeError / AttributeError) in every kb_* that reads topics: native throws StateShapeError
// there (M01 §8 R8). kb_note_topic touches only "queue", so it works without "topics".

public enum KnowledgeLogic {
    /// `{"topics": {}, "queue": []}`, what kb_load returns when `json.load` raises.
    public static func empty() -> JSONObject {
        JSONObject([JSONObject.Member(key: "topics", value: .object(JSONObject())),
                    JSONObject.Member(key: "queue", value: .array([]))])
    }

    /// `kb_load`: whatever `json.load` returned, else the empty KB. A parseable non-dict
    /// throws: every kb_* caller then raises in Python.
    public static func load(_ raw: JSONValue?) throws(StateShapeError) -> JSONObject {
        guard let raw else { return empty() }
        guard case .object(let kb) = raw else { throw shape("knowledge.json is not a dict (TypeError)") }
        return kb
    }

    /// `(topic or "").strip().lower()[:120]`, the topic / queue-entry normalisation.
    public static func normalize(_ text: String) -> String {
        Py.prefix(Py.lower(Py.strip(text)), 120)
    }

    /// `kb_remember` on a loaded object: `topics[topic] = {"summary": summary[:800],
    /// "updated": now}`; past 200 topics the 50 oldest (stable by "updated", default 0) go.
    /// False = skipped (empty topic or summary): `kb` is untouched and Python does not save.
    public static func remember(topic: String, summary: String, in kb: inout JSONObject,
                                now: Double) throws(StateShapeError) -> Bool {
        let t = normalize(topic)
        if t.isEmpty || summary.isEmpty { return false }
        var topics = try self.topics(kb)
        topics[t] = .object(JSONObject([JSONObject.Member(key: "summary", value: .string(Py.prefix(summary, 800))),
                                        JSONObject.Member(key: "updated", value: .double(now))]))
        if topics.count > 200 {
            for m in try PyObjects.sortedByUpdated(topics, reverse: false, file: .knowledge).prefix(50) {
                topics.removeValue(forKey: m.key)
            }
        }
        kb["topics"] = .object(topics)
        return true
    }

    /// `_KB_STOP`.
    public static let stopWords: Set<PyKey> = Set([
        "the", "a", "an", "is", "are", "was", "were", "who", "what", "when", "where", "why", "how",
        "tell", "me", "about", "of", "to", "do", "you", "know", "please", "sir", "can", "could",
    ].map(PyKey.init))

    private static let word = compile(#"\w+"#)

    /// `set(re.findall(r"\w+", s)) - _KB_STOP`.
    static func words(_ s: String) -> Set<PyKey> {
        Set(word.findall(s).map(PyKey.init)).subtracting(stopWords)
    }

    /// `kb_lookup(query)`: the exact topic's summary, else the best word overlap (+2 when
    /// either string contains the other; the first strictly better topic wins; needs ≥ 1),
    /// else nil. A blank query is nil before the file is read. Throws where Python raises,
    /// and (native) when the chosen summary is not a str.
    public static func lookup(_ query: String, in kb: JSONObject) throws(StateShapeError) -> String? {
        let q = Py.lower(Py.strip(query))
        if q.isEmpty { return nil }
        let topics = try self.topics(kb)
        if let hit = topics[q] { return try text(summary(hit)) }
        let qwords = words(q)
        var best: JSONValue?
        var bestScore = 0
        for m in topics.members {
            let twords = words(m.key)
            if twords.isEmpty { continue }
            let overlap = qwords.intersection(twords).count
                + (Py.contains(q, m.key) || Py.contains(m.key, q) ? 2 : 0)
            if overlap > bestScore {
                best = try summary(m.value)
                bestScore = overlap
            }
        }
        guard bestScore >= 1, let best else { return nil }
        return try text(best)
    }

    /// `kb_note_topic(text)` on a loaded object: appends the normalised text to "queue"
    /// (`setdefault`) unless it is already there, keeping the last 30. True = changed, and
    /// only then does Python save. Throws where Python raises (a queue it cannot append to).
    public static func noteTopic(_ text: String, in kb: inout JSONObject) throws(StateShapeError) -> Bool {
        let t = normalize(text)
        if t.isEmpty { return false }
        switch kb.setDefault("queue", .array([])) {
        case .array(var q):
            if q.contains(.string(t)) { return false }
            q.append(.string(t))
            kb["queue"] = .array(Py.tail(q, 30))
            return true
        case .string(let s) where Py.contains(s, t):
            return false
        case .object(let o) where o[t] != nil:
            return false
        case .string, .object:
            throw shape("\"queue\" has no append() (AttributeError)")
        default:
            throw shape("\"queue\" is not a container (TypeError)")
        }
    }

    /// `kb_context(n)`: the n newest topics (by "updated", ties in file order) as
    /// `" Recently learned — k: summary[:140]; …"`, or "" when there are none.
    public static func context(_ kb: JSONObject, n: Int = 3) throws(StateShapeError) -> String {
        let items = try PyObjects.sortedByUpdated(topics(kb), reverse: true, file: .knowledge)
        let picked = n < 0 ? Array(items.dropLast(-n)) : Array(items.prefix(n))
        if picked.isEmpty { return "" }
        var parts: [String] = []
        for m in picked {
            let s = try summary(m.value)
            let shown: String = switch s {
            case .string(let text): Py.prefix(text, 140)
            case .array(let a): PyObjects.repr(.array(Array(a.prefix(140))))
            default: throw shape("a summary is not sliceable (TypeError)")
            }
            parts.append("\(m.key): \(shown)")
        }
        return " Recently learned — " + parts.joined(separator: "; ")
    }

    // MARK: - Helpers

    /// `kb["topics"]` used as a dict.
    private static func topics(_ kb: JSONObject) throws(StateShapeError) -> JSONObject {
        guard let t = kb["topics"] else { throw shape("no \"topics\" (KeyError)") }
        guard case .object(let o) = t else { throw shape("\"topics\" is not a dict (TypeError)") }
        return o
    }

    /// `v["summary"]` for a topic entry.
    private static func summary(_ v: JSONValue) throws(StateShapeError) -> JSONValue {
        guard case .object(let o) = v else { throw shape("a topic is not a dict (TypeError)") }
        guard let s = o["summary"] else { throw shape("a topic has no \"summary\" (KeyError)") }
        return s
    }

    /// The summary kb_lookup returns, as the str its caller slices.
    private static func text(_ v: JSONValue) throws(StateShapeError) -> String {
        guard case .string(let s) = v else { throw shape("a summary is not a str (native)") }
        return s
    }

    private static func compile(_ pattern: String) -> PyRegex {
        do { return try PyRegex(pattern) } catch {
            preconditionFailure("KnowledgeLogic: \(error)")
        }
    }

    private static func shape(_ detail: String) -> StateShapeError {
        StateShapeError(file: .knowledge, detail: detail)
    }
}

// MARK: - The Python functions, with their file IO

public extension KnowledgeLogic {
    /// `kb_remember(topic, summary)`: saves only when the topic and summary are non-empty.
    static func remember(topic: String, summary: String, store: StateStore, now: Double) throws(StateShapeError) {
        if normalize(topic).isEmpty || summary.isEmpty { return }
        var kb = try load(store.load(.knowledge))
        if try remember(topic: topic, summary: summary, in: &kb, now: now) {
            store.save(.knowledge, .object(kb))
        }
    }

    /// `kb_lookup(query)`.
    static func lookup(_ query: String, store: StateStore) throws(StateShapeError) -> String? {
        if Py.strip(query).isEmpty { return nil }
        return try lookup(query, in: load(store.load(.knowledge)))
    }

    /// `kb_note_topic(text)`: saves only when the text is new to the queue.
    static func noteTopic(_ text: String, store: StateStore) throws(StateShapeError) {
        if normalize(text).isEmpty { return }
        var kb = try load(store.load(.knowledge))
        if try noteTopic(text, in: &kb) {
            store.save(.knowledge, .object(kb))
        }
    }

    /// `kb_context(n)`.
    static func context(store: StateStore, n: Int = 3) throws(StateShapeError) -> String {
        try context(load(store.load(.knowledge)), n: n)
    }
}
