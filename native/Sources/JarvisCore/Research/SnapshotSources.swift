import Foundation

// Where a snapshot row's state comes from (plan: M01b §2.1, §3.2): the same loaders
// research_snapshot calls in jarvis.py 2484–2522, read-only. A method throws exactly where
// Python raises inside research_snapshot (the row is then not written).

public protocol SnapshotSources: Sendable {
    /// `personality_load()`.
    func personality() -> JSONValue
    /// `_emotions_load()` RAW (no decay), key order kept, INCLUDING "at".
    func emotions(now: Double) throws(SnapshotSourceError) -> JSONObject
    /// `len(profile_load().get("facts", {}))`.
    func profileFactsCount() throws(SnapshotSourceError) -> Int
    /// `len(_corrections_load())`.
    func correctionsCount() -> Int
    /// `len(kb_load().get("topics", {}))`.
    func kbTopicsCount() throws(SnapshotSourceError) -> Int
    /// `len(_history)`: the running process's in-memory history.
    func historyTurns() -> Int
}

/// What Python raises in one of the snapshot's loaders (the message is for the log only).
public struct SnapshotSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    public let detail: String
    public init(_ detail: String) { self.detail = detail }
    public var description: String { detail }
}

/// The state files under `here`, with jarvis.py's file semantics. The personality seed and
/// emotion baselines are injected (the app passes M1's, tests pass the golden fixture's).
public struct FileSnapshotSources: SnapshotSources {
    public let state: StatePaths
    public let personalitySeed: JSONValue
    public let emotionBaselines: [(name: String, baseline: Double)]
    private let turns: @Sendable () -> Int

    public init(here: URL,
                personalitySeed: JSONValue = .object(PersonalityLogic.seed()),
                emotionBaselines: [(name: String, baseline: Double)] = EmotionLogic.dims.map { ($0.name, $0.baseline) },
                historyTurns: @escaping @Sendable () -> Int) {
        self.state = StatePaths(root: here)
        self.personalitySeed = personalitySeed
        self.emotionBaselines = emotionBaselines
        self.turns = historyTurns
    }

    /// `json.load(open(path))`; nil where it raises (missing, unreadable, not UTF-8, BOM,
    /// not JSON).
    private func load(_ url: URL) -> JSONValue? {
        guard let data = AtomicFile.read(url.path(percentEncoded: false)) else { return nil }
        return try? PyJSON.loads(data)
    }

    /// A dict whose "core" is truthy, with `setdefault("learned", [])`; else the seed.
    public func personality() -> JSONValue {
        if case .object(var p)? = load(state.personality), p["core"]?.pyTruthy == true {
            p.setDefault("learned", .array([]))
            return .object(p)
        }
        return personalitySeed
    }

    /// The file when `all(k in e for k in _EMO_DIMS)` holds, else the baselines + "at": now.
    /// A list or str that *contains* every dimension name passes that test and then has no
    /// `.items()`: Python raises there, so this throws.
    public func emotions(now: Double) throws(SnapshotSourceError) -> JSONObject {
        let names = emotionBaselines.map(\.name)
        switch load(state.emotions) {
        case .object(let o)? where names.allSatisfy({ o[$0] != nil }):
            return o
        case .array(let a)? where names.allSatisfy({ n in a.contains(.string(n)) }):
            throw SnapshotSourceError("'list' object has no attribute 'items'")
        case .string(let s)? where names.allSatisfy({ Py.contains(s, $0) }):
            throw SnapshotSourceError("'str' object has no attribute 'items'")
        default:
            return JSONObject(emotionBaselines.map { JSONObject.Member(key: $0.name, value: .double($0.baseline)) }
                              + [JSONObject.Member(key: "at", value: .double(now))])
        }
    }

    public func profileFactsCount() throws(SnapshotSourceError) -> Int {
        try Self.count(load(state.profile), key: "facts")
    }

    /// `[p for p in data if isinstance(p, dict) and p.get("heard") and p.get("meant")]`: a
    /// list's qualifying dicts; any other shape iterates no dicts (or raises, which the
    /// loader catches), so 0.
    public func correctionsCount() -> Int {
        guard case .array(let a)? = load(state.corrections) else { return 0 }
        return a.reduce(0) { n, e in
            guard case .object(let o) = e, o["heard"]?.pyTruthy == true, o["meant"]?.pyTruthy == true else {
                return n
            }
            return n + 1
        }
    }

    public func kbTopicsCount() throws(SnapshotSourceError) -> Int {
        try Self.count(load(state.knowledge), key: "topics")
    }

    public func historyTurns() -> Int { turns() }

    /// `len(loaded.get(key, {}))` where `loaded` falls back to a dict holding an empty
    /// `key` when the load raises: a non-dict has no `.get`; `len` takes a dict, list or
    /// str (code points) and raises on anything else.
    static func count(_ raw: JSONValue?, key: String) throws(SnapshotSourceError) -> Int {
        guard let raw else { return 0 }
        guard case .object(let o) = raw else { throw SnapshotSourceError("object has no attribute 'get'") }
        switch o[key] ?? .object(JSONObject()) {
        case .object(let d): return d.count
        case .array(let a): return a.count
        case .string(let s): return Py.len(s)
        default: throw SnapshotSourceError("object of this type has no len()")
        }
    }
}
