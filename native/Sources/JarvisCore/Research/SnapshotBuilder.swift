import Foundation

// The daily dataset row (plan: M01b §2.1, §2.2, §3.3, §3.4 D5). jarvis.py research_snapshot
// (2484–2522) builds the 8 schema-1 keys; native appends the schema-2 keys after them:
//
//     ts, date, code{bytes, lines, git_head, git_commits}, personality, emotions,
//     counts{profile_facts, corrections, kb_topics, history_turns}, voiceprint_enrolled,
//     usage_today, | emotions_at, schema (2), runtime{…}, code_native{bytes, lines, files}
//
// and appends `json.dumps(row) + "\n"` to research/metrics.jsonl. The schema-1 part is
// byte-identical to Python's line (m1b_snapshot golden suite: the test strips the four
// schema-2 keys and compares bytes). Where Python raises, no row is written (`.failed`),
// with one registered deviation, D5: a missing or unreadable jarvis.py still gives a row,
// with code.bytes and code.lines null.

public enum SnapshotOutcome: Sendable, Equatable {
    case written(date: String)
    case skippedAlreadyToday
    case failed(String)
}

public struct SnapshotBuilder: Sendable {
    /// The schema-1 keys in Python's order, then the schema-2 keys native appends.
    public static let schema1Keys = ["ts", "date", "code", "personality", "emotions", "counts",
                                     "voiceprint_enrolled", "usage_today"]
    public static let schema2Keys = ["emotions_at", "schema", "runtime", "code_native"]
    public static let schema: Int64 = 2

    public let paths: ResearchPaths
    public let clock: ResearchClock
    public let sources: any SnapshotSources
    private let runtime: @Sendable () -> RuntimeInfo
    private let git: GitProbe.Runner
    private let host: @Sendable () -> HostSample

    /// `git` runs research_snapshot's two git commands (tests inject a recorder); `host`
    /// samples the OS / hardware / memory facts of the runtime block.
    public init(paths: ResearchPaths, clock: ResearchClock, sources: any SnapshotSources,
                runtime: @escaping @Sendable () -> RuntimeInfo,
                git: @escaping GitProbe.Runner = GitProbe.run,
                host: @escaping @Sendable () -> HostSample = { HostSample.current() }) {
        self.paths = paths
        self.clock = clock
        self.sources = sources
        self.runtime = runtime
        self.git = git
        self.host = host
    }

    /// jarvis.py's code measure: `sum(1 for _ in open(me))` (UTF-8 text mode, universal
    /// newlines) and `os.path.getsize(me)`. nil where Python raises (missing, a directory,
    /// unreadable, not UTF-8): deviation D5.
    public static func codeMeasure(_ jarvisPy: URL) -> (bytes: Int, lines: Int)? {
        guard let data = AtomicFile.read(jarvisPy.path(percentEncoded: false)),
              String(validating: data, as: UTF8.self) != nil else { return nil }
        return (data.count, PyLineCount.lines(data))
    }

    /// `round(v, 3)` for an emotions value: ints (and bools, as ints) unchanged, floats
    /// Python-rounded; anything else raises TypeError in Python.
    static func round3(_ v: JSONValue, key: String) throws(SnapshotSourceError) -> JSONValue {
        switch v {
        case .int, .bigInt: return v
        case .bool(let b): return .int(b ? 1 : 0)
        case .double(let d): return .double(PyMath.round(d, 3))
        default: throw SnapshotSourceError("emotions[\(key)] doesn't define __round__")
        }
    }

    /// The row research_snapshot builds at `now`, plus the schema-2 keys. Throws where Python
    /// raises. `codeUnreadable` is set when D5 applied.
    public func row(now: Double) throws(SnapshotSourceError) -> (row: JSONObject, date: String, codeUnreadable: Bool) {
        let day = clock.localDate(now)
        let (head, commits) = GitProbe.headAndCommits(repo: paths.here, timeout: 5, run: git)
        let code = Self.codeMeasure(paths.jarvisPy)
        let personality = sources.personality()
        let usageToday = UsageStore(url: paths.usage, clock: clock).day(day)
        let emo = try sources.emotions(now: now)
        var emotions: [JSONObject.Member] = []
        for m in emo.members where !Py.eq(m.key, "at") {
            emotions.append(.init(key: m.key, value: try Self.round3(m.value, key: m.key)))
        }
        let counts = JSONObject([
            .init(key: "profile_facts", value: .int(Int64(try sources.profileFactsCount()))),
            .init(key: "corrections", value: .int(Int64(sources.correctionsCount()))),
            .init(key: "kb_topics", value: .int(Int64(try sources.kbTopicsCount()))),
            .init(key: "history_turns", value: .int(Int64(sources.historyTurns()))),
        ])
        let voiceprint = FileManager.default.fileExists(atPath: paths.voiceprint.path(percentEncoded: false))
        let native = PyLineCount.codeNative(paths.nativeSources)
        let row = JSONObject([
            .init(key: "ts", value: .double(now)),
            .init(key: "date", value: .string(day)),
            .init(key: "code", value: .object(JSONObject([
                .init(key: "bytes", value: code.map { .int(Int64($0.bytes)) } ?? .null),
                .init(key: "lines", value: code.map { .int(Int64($0.lines)) } ?? .null),
                .init(key: "git_head", value: .string(head)),
                .init(key: "git_commits", value: .string(commits)),
            ]))),
            .init(key: "personality", value: personality),
            .init(key: "emotions", value: .object(JSONObject(emotions))),
            .init(key: "counts", value: .object(counts)),
            .init(key: "voiceprint_enrolled", value: .bool(voiceprint)),
            .init(key: "usage_today", value: usageToday),
            // schema 2 (additive): see research/README.md
            .init(key: "emotions_at", value: emo["at"] ?? .null),
            .init(key: "schema", value: .int(Self.schema)),
            .init(key: "runtime", value: .object(runtime().json(utcOffset: clock.utcOffset(now), host: host()))),
            .init(key: "code_native", value: .object(JSONObject([
                .init(key: "bytes", value: .int(Int64(native.bytes))),
                .init(key: "lines", value: .int(Int64(native.lines))),
                .init(key: "files", value: .int(Int64(native.files))),
            ]))),
        ])
        return (row, day, code == nil)
    }

    /// `research_snapshot()`: builds the row at the clock's now and appends
    /// `json.dumps(row) + "\n"` to metrics.jsonl (MetricsLog: D4). `.failed` = no row.
    public func snapshot() -> SnapshotOutcome {
        let built: (row: JSONObject, date: String, codeUnreadable: Bool)
        do {
            built = try row(now: clock.now())
        } catch {
            JarvisLog.log("Research snapshot: \(error)", category: .research)
            return .failed(error.detail)
        }
        if built.codeUnreadable {
            JarvisLog.log("Research snapshot: jarvis.py unreadable; code.bytes/lines recorded as null (D5)",
                          category: .research)
        }
        do {
            try MetricsLog(paths: paths).append(PyJSON.dumps(.object(built.row)))
        } catch {
            JarvisLog.log("Research snapshot: \(error)", category: .research)
            return .failed("\(error)")
        }
        JarvisLog.log("Research snapshot appended for \(built.date).", category: .research)
        return .written(date: built.date)
    }
}
