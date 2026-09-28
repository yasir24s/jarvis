import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_corrections.golden.json (M01 §2.5, §3.7, §6 T6): CorrectionsLogic against the real
/// _corr_norm, _parse_teach, _is_teach_correction, learn_correction, forget_correction and
/// _apply_corrections. Scenario steps run with a live _corr_cache on the Python side; here a
/// driver holds the cache the way CoreState will (load once on first use, replaced by the
/// capped list on every save) and writes corrections.json through StateStore. Per step: the
/// reply / result, corrections.json's bytes, the cache, and the research bumps (none).
/// The "constants" case compares the regex sources, thresholds and cap with jarvis.py's.
///
/// Registered divergences (`native` blocks in the fixture; hand-edited files only):
/// - `corr-malformed-pair-raises`: a pair whose heard/meant is not a string makes Python's
///   _apply_corrections raise; native returns the transcript unchanged.
/// - `sub-literal-repl`: a `meant` with a backslash is a re.sub template in Python; native
///   substitutes it literally.
/// Native is asserted positively; only Python's result is the known issue.
@Suite("M1 corrections golden (jarvis.py _corr_* / learn / forget / _apply_corrections)")
struct M1CorrectionsTests {
    static let suite = "m1_corrections"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        try CorrHistGolden.record(c, Self.check(c))
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() throws {
        try CorrHistGolden.summarise(Self.suite, Self.check)
    }

    static func check(_ c: GoldenCase) throws -> CorrHistGolden.Report {
        var r = CorrHistGolden.Report()
        let e = c.expected
        switch c.input.string("kind") {
        case "constants":
            r.hard = constants(e)
        case "norm":
            let text = try #require(c.input.string("text"))
            let got = CorrectionsLogic.norm(text)
            if .string(got) != e["result"] { r.hard.append("norm: got \(got.debugDescription), want \(e["result"] ?? .null)") }
        case "teach":
            let text = try #require(c.input.string("text"))
            let parsed: JSONValue = CorrectionsLogic.parseTeach(text).map { .array([.string($0.heard), .string($0.meant)]) } ?? .null
            if parsed != e["parse"] { r.hard.append("parseTeach: got \(parsed), want \(e["parse"] ?? .null)") }
            let teach = CorrectionsLogic.isTeachCorrection(text)
            if .bool(teach) != e["is_teach"] { r.hard.append("isTeachCorrection: got \(teach)") }
        case "scenario":
            r = try scenario(c)
        default:
            r.hard.append("unknown case kind \(c.input["kind"] ?? .null)")
        }
        return r
    }

    // MARK: - Scenarios

    /// The `_corr_cache` owner: what CoreState does around CorrectionsLogic.
    final class Driver {
        let store: StateStore
        var cache: [JSONObject]?
        init(store: StateStore) { self.store = store }

        func load() -> [JSONObject] {                       // _corrections_load
            if cache == nil { cache = CorrectionsLogic.filter(store.load(.corrections)) }
            return cache ?? []
        }

        func save(_ pairs: [JSONObject]) {                  // _corrections_save
            let kept = CorrectionsLogic.capped(pairs)
            cache = kept
            _ = store.save(.corrections, .array(kept.map { .object($0) }))
        }

        var cacheJSON: JSONValue { cache.map { .array($0.map { .object($0) }) } ?? .null }
    }

    static func scenario(_ c: GoldenCase) throws -> CorrHistGolden.Report {
        var r = CorrHistGolden.Report()
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: sb.root.path(percentEncoded: false), lease: nil)
        let path = store.path(.corrections)
        try CorrHistGolden.put(c.input["initial"], at: path)
        let clock = ManualClock(try #require(c.clock.double("epoch")))
        let d = Driver(store: store)
        let steps = try #require(c.input.array("steps"))
        let want = try #require(c.expected.array("steps"))
        try #require(steps.count == want.count)
        for (k, (sv, wv)) in zip(steps, want).enumerated() {
            let st = try #require(sv.objectValue), w = try #require(wv.objectValue)
            let op = try #require(st.string("op"))
            if let at = st.double("at") { clock.set(at) }
            let text = st.string("text") ?? ""
            var result: String?
            switch op {
            case "learn":
                let (reply, save) = CorrectionsLogic.learn(text, pairs: d.load(), now: clock.now())
                if let save { d.save(save) }
                result = reply
            case "forget":
                let (reply, save) = CorrectionsLogic.forget(text, pairs: d.load())
                d.save(save)
                result = reply
            case "apply":
                result = CorrectionsLogic.apply(text, pairs: d.load())
            case "external_write":
                try CorrHistGolden.put(st["file"], at: path)
            case "restart":
                d.cache = nil
            default:
                r.hard.append("step \(k): unknown op \(op)")
            }
            let at = "step \(k) \(op) \(text.debugDescription)"
            if let native = w.object("native") {
                r.divergence = CorrHistGolden.merge(r.divergence, native.string("divergence"))
                if let result, .string(result) != native["result"] {
                    r.hard.append("\(at): native rule wants \(native["result"] ?? .null), got \(result.debugDescription)")
                }
                if let raised = w.string("raises") {
                    r.python.append("\(at): Python raises \(raised); native returns \(result?.debugDescription ?? "nil")")
                } else if let result, .string(result) != w["result"] {
                    r.python.append("\(at): Python gives \(w["result"] ?? .null), native \(result.debugDescription)")
                }
            } else if let result, .string(result) != w["result"] {
                r.hard.append("\(at): got \(result.debugDescription), want \(w["result"] ?? w["raises"] ?? .null)")
            } else if result == nil, w["result"] != nil, w["result"] != .null {
                r.hard.append("\(at): no result, want \(w["result"] ?? .null)")
            }
            if let m = CorrHistGolden.fileMismatch(path, w["file"]) { r.hard.append("\(at): corrections.json \(m)") }
            if d.cacheJSON != (w["cache"] ?? .null) {
                r.hard.append("\(at): cache \(d.cacheJSON) != Python's \(w["cache"] ?? .null)")
            }
            if w["effects"] != .array([]) {
                r.hard.append("\(at): Python bumped \(w["effects"] ?? .null); CorrectionsLogic bumps nothing")
            }
        }
        return r
    }

    // MARK: - Literals

    static func constants(_ e: JSONObject) -> [String] {
        var out: [String] = []
        let pats = e.object("patterns")
        for (id, mine) in [("_CORR_SAID_RE", CorrectionsLogic.saidPattern), ("_CORR_TO_RE", CorrectionsLogic.toPattern),
                           ("_CORR_WHEN_RE", CorrectionsLogic.whenPattern), ("_CORR_FORGET_RE", CorrectionsLogic.forgetPattern)] {
            let p = pats?.object(id)
            if p?.string("pattern").map({ Py.eq($0, mine) }) != true { out.append("\(id) pattern differs: \(p?["pattern"] ?? .null)") }
            if p?["ignorecase"] != .bool(true) || p?["other_flags"] != .int(0) { out.append("\(id) flags differ") }
        }
        let subs: JSONValue = .array(CorrectionsLogic.normSubs.map { .array([.string($0.pattern), .string($0.repl)]) })
        if e["norm_subs"] != subs { out.append("_corr_norm subs \(e["norm_subs"] ?? .null) != \(subs)") }
        if e["save_slices"] != .object(JSONObject([.init(key: "pairs[-200:]", value: .array([.int(Int64(-CorrectionsLogic.cap)), .null]))])) {
            out.append("_corrections_save slices \(e["save_slices"] ?? .null) (cap \(CorrectionsLogic.cap))")
        }
        out += CorrHistGolden.compares(e.object("learn_compares"), ["len(heard) < 2": Double(CorrectionsLogic.minTeachHeardLength)])
        out += CorrHistGolden.compares(e.object("apply_compares"), [
            "len(heard) < 3": Double(CorrectionsLogic.minApplyHeardLength),
            "len(norm.split()) <= 6": Double(CorrectionsLogic.fuzzyMaxWords),
            "difflib.SequenceMatcher(None, norm, heard).ratio() >= 0.82": CorrectionsLogic.fuzzyThreshold,
        ])
        if e["forget_all_words"] != .array([.array(CorrectionsLogic.forgetAllWords.map { .string($0) })]) {
            out.append("forget_correction words \(e["forget_all_words"] ?? .null)")
        }
        return out
    }
}

/// Shared by the T6 / T10 golden tests (M1CorrectionsTests, M1HistoryAppFeedbackTests).
enum CorrHistGolden {
    struct Report {
        /// Native is wrong: always a failure.
        var hard: [String] = []
        /// Python's expectation differs: a failure, or the known issue when `divergence` is set.
        var python: [String] = []
        var divergence: String?
    }

    static func record(_ c: GoldenCase, _ r: Report) {
        for m in r.hard { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        } else {
            for m in r.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        }
    }

    static func summarise(_ suite: String, _ check: (GoldenCase) throws -> Report) throws {
        let cases = try Golden.cases(suite)
        var passed = 0
        var diverged: [String: Int] = [:]
        for c in cases {
            let r = try check(c)
            if let d = r.divergence, !r.python.isEmpty { diverged[d, default: 0] += 1 }
            // A divergence case passes when native holds and the Python difference shows.
            if r.hard.isEmpty && (r.divergence == nil) == r.python.isEmpty { passed += 1 }
        }
        let summary = diverged.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }
        print("\(suite): \(passed)/\(cases.count)"
              + (summary.isEmpty ? "" : " (known divergences: \(summary.joined(separator: ", ")))"))
        #expect(passed == cases.count)
    }

    static func merge(_ a: String?, _ b: String?) -> String? {
        guard let b else { return a }
        guard let a, a != b else { return b }
        return a.split(separator: ",").contains(Substring(b)) ? a : "\(a),\(b)"
    }

    /// Makes `path` what a fixture file spec says: null (absent), {"dir": true}, {"text"}, {"hex"}.
    static func put(_ spec: JSONValue?, at path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard let o = spec?.objectValue else { return }
        if o["dir"] == .bool(true) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else if let text = o.string("text") {
            try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        } else if let hex = o.string("hex"), let bytes = Golden.bytes(hex: hex) {
            try bytes.write(to: URL(fileURLWithPath: path))
        } else {
            throw GoldenError.malformed(Golden.directory, "bad file spec \(o)")
        }
    }

    /// nil when the file at `path` is what the fixture recorded Python left there.
    static func fileMismatch(_ path: String, _ want: JSONValue?) -> String? {
        var isDir: ObjCBool = false
        let got: JSONValue
        if !FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            got = .null
        } else if isDir.boolValue {
            got = .object(JSONObject([.init(key: "dir", value: .bool(true))]))
        } else if let data = FileManager.default.contents(atPath: path) {
            if let s = String(data: data, encoding: .utf8) {
                got = .object(JSONObject([.init(key: "text", value: .string(s))]))
            } else {
                got = .object(JSONObject([.init(key: "hex", value: .string(data.map { String(format: "%02x", $0) }.joined()))]))
            }
        } else {
            return "unreadable"
        }
        return got == (want ?? .null) ? nil : "is \(got), Python wrote \(want ?? .null)"
    }

    /// A fixture's {"<source of x OP k>": k} map equals `mine` exactly (no extra comparisons).
    static func compares(_ got: JSONObject?, _ mine: [String: Double]) -> [String] {
        guard let got else { return ["comparisons missing"] }
        var out: [String] = []
        if Set(got.keys) != Set(mine.keys) { out.append("comparisons \(got.keys.sorted()) != \(mine.keys.sorted())") }
        for (k, v) in mine where got.double(k) != v {
            out.append("\(k): jarvis.py has \(got[k] ?? .null), native \(v)")
        }
        return out
    }
}
