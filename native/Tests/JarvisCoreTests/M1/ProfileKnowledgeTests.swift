import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_profile_kb.golden.json (M01 §2.4, §3.7, §6 T9): ProfileLogic and KnowledgeLogic against
/// the real profile_load / profile_remember / profile_forget / profile_context /
/// maybe_learn_profile and kb_load / kb_remember / kb_lookup / kb_note_topic / kb_context. Per
/// step: the result (or that Python raised), the research_bump sequence (none, in Python as in
/// native), and the state file's bytes on disk. maybe_learn steps also compare
/// `action(for:)` with the profile_remember / profile_forget call Python made. The "literals"
/// case compares the pattern tables and _KB_STOP with jarvis.py's.
///
/// Registered divergences (a `native` block in the fixture, M01 §3.7 / §8 R8):
/// - `R8-nan-sort`: NaN in a fact's "updated". Python sorts it wherever its timsort run leaves
///   it; native throws StateShapeError rather than reproduce that accident.
/// - `R8-kb-summary-not-str`: kb_lookup picks a topic whose "summary" is not a str. Python
///   returns the raw value (its caller then slices it); native's lookup yields `String?`, so
///   it throws StateShapeError.
/// - `R8-load-not-dict`: a parseable non-dict file (a list, a str, null). profile_load /
///   kb_load return it and every caller then raises; native's `load` has the planned
///   `JSONObject` result, so it throws at the load step itself. Only that step differs.
/// In all three, native is asserted positively (throws, writes and bumps nothing); Python's
/// result is the known issue.
@Suite("M1 profile + knowledge golden (jarvis.py profile_* / kb_*)")
struct M1ProfileKnowledgeTests {
    static let suite = "m1_profile_kb"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        if c.name == "literals" {
            for m in Self.literals(c.expected) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            return
        }
        let r = try Self.run(c)
        for m in r.hard { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        } else {
            for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        }
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        var diverged: [String: Int] = [:]
        for c in cases {
            if c.name == "literals" {
                if Self.literals(c.expected).isEmpty { passed += 1 }
                continue
            }
            let r = try Self.run(c)
            if let d = r.divergence, !r.knownPython.isEmpty { diverged[d, default: 0] += 1 }
            if r.hard.isEmpty && (r.divergence == nil) == r.knownPython.isEmpty { passed += 1 }
        }
        let summary = diverged.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }
        print("\(Self.suite): \(passed)/\(cases.count)"
              + (summary.isEmpty ? "" : " (known divergences: \(summary.joined(separator: ", ")))"))
        #expect(passed == cases.count)
    }

    static func run(_ c: GoldenCase) throws -> PersonaGolden.Report {
        let files = c.input.object("files_before")?.keys ?? []
        return try PersonaGolden.run(c, files: files) { op, args, now, env in
            let store = env.store
            typealias Body = () throws(StateShapeError) -> JSONValue
            func attempt(_ body: Body) -> PersonaGolden.Outcome { PersonaGolden.attempt(body) }
            func json(_ body: () throws(StateShapeError) -> JSONObject) -> PersonaGolden.Outcome {
                do { return .json(.object(try body())) } catch { return .threw(error) }
            }
            let none: JSONValue = .null
            switch op {
            case "load":
                return .init(json { () throws(StateShapeError) in try ProfileLogic.load(store.load(.profile)) })
            case "remember":
                return .init(attempt { () throws(StateShapeError) in
                    try ProfileLogic.remember(key: args.string("key") ?? "", value: args.string("value") ?? "",
                                              store: store, now: now)
                    return none
                })
            case "forget":
                return .init(attempt { () throws(StateShapeError) in
                    try ProfileLogic.forget(matching: args.string("match"), store: store)
                    return none
                })
            case "context":
                return .init(attempt { () throws(StateShapeError) in .string(try ProfileLogic.context(store: store)) })
            case "maybe_learn":
                let text = args.string("text") ?? ""
                let action: JSONValue = switch ProfileLogic.action(for: text) {
                case .forgetAll?: Self.object(["action": "forget_all"])
                case .forget(let m)?: Self.object(["action": "forget", "match": m])
                case .remember(let k, let v)?: Self.object(["action": "remember", "key": k, "value": v])
                case nil: .null
                }
                let outcome = attempt { () throws(StateShapeError) in
                    try ProfileLogic.maybeLearn(text, store: store, now: now)
                    return none
                }
                return .init(outcome, action: action)
            case "kb_load":
                return .init(json { () throws(StateShapeError) in try KnowledgeLogic.load(store.load(.knowledge)) })
            case "kb_remember":
                return .init(attempt { () throws(StateShapeError) in
                    try KnowledgeLogic.remember(topic: args.string("topic") ?? "", summary: args.string("summary") ?? "",
                                                store: store, now: now)
                    return none
                })
            case "kb_lookup":
                return .init(attempt { () throws(StateShapeError) in
                    try KnowledgeLogic.lookup(args.string("query") ?? "", store: store).map { .string($0) } ?? none
                })
            case "kb_note_topic":
                return .init(attempt { () throws(StateShapeError) in
                    try KnowledgeLogic.noteTopic(args.string("text") ?? "", store: store)
                    return none
                })
            case "kb_context":
                let n = args.int("n").map(Int.init) ?? 3
                return .init(attempt { () throws(StateShapeError) in
                    .string(try KnowledgeLogic.context(store: store, n: n))
                })
            default:
                return .init(.value(.string("<unknown op \(op)>")))
            }
        }
    }

    /// Key order as written (a dictionary literal would not keep it).
    static func object(_ pairs: KeyValuePairs<String, String>) -> JSONValue {
        .object(JSONObject(pairs.map { JSONObject.Member(key: $0.key, value: .string($0.value)) }))
    }

    /// `_PROFILE_PATTERNS` (pattern text, re.I, key), both forget REs and `_KB_STOP`.
    static func literals(_ e: JSONObject) -> [String] {
        var out: [String] = []
        let rows = e.array("profile_patterns") ?? []
        if rows.count != ProfileLogic.patterns.count {
            out.append("_PROFILE_PATTERNS has \(rows.count) rows, native \(ProfileLogic.patterns.count)")
        }
        for (k, (row, p)) in zip(rows, ProfileLogic.patterns).enumerated() {
            let o = row.objectValue
            if o?.string("pattern") != p.regex.pattern { out.append("profile row \(k): pattern differs") }
            if o?["ignorecase"] != .bool(p.regex.ignoreCase) { out.append("profile row \(k): flags differ") }
            if o?["key"] != (p.key.map { JSONValue.string($0) } ?? .null) { out.append("profile row \(k): key differs") }
        }
        for (name, re) in [("forget_all_re", ProfileLogic.forgetAllPattern), ("forget_one_re", ProfileLogic.forgetOnePattern)] {
            let f = e.object(name)
            if f?.string("pattern") != re.pattern || f?["ignorecase"] != .bool(re.ignoreCase) {
                out.append("\(name) differs")
            }
        }
        let stop = (e.array("kb_stop") ?? []).compactMap(\.stringValue)
        if Set(stop.map(PyKey.init)) != KnowledgeLogic.stopWords || stop.count != KnowledgeLogic.stopWords.count {
            out.append("_KB_STOP differs")
        }
        return out
    }
}
