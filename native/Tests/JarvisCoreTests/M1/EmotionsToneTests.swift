import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_emotions_tone.golden.json (M01 §2.3, §2.6, §3.7, §6 T8): EmotionLogic, ToneLogic and
/// LastTone against the real _emotions_load / _emotions_decay / emotion_event / emotion_react /
/// _emo_word / emotion_context / set_tone / tone_context. Per step: the result (or that Python
/// raised), the research_bump sequence (RecordingCounter), and emotions.json's bytes. React
/// steps also compare `classify` with the event emotion_react fired. The "literals" case
/// compares the dimension, delta, band and pattern tables with jarvis.py's.
///
/// Registered divergence (a `native` block in the fixture, M01 §3.7 / §8 R8):
/// - `R8-str-float`: a dimension stored as a numeric *string* ("0.5"). Python's `float()`
///   parses it; native reads JSON numbers only (`pyFloat`), so it throws StateShapeError,
///   bumps nothing and writes nothing. Native is asserted positively; Python's result is
///   the known issue.
@Suite("M1 emotions + tone golden (jarvis.py emotion_* / tone_context)")
struct M1EmotionsToneTests {
    static let suite = "m1_emotions_tone"

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
        try PersonaGolden.run(c, files: ["emotions.json"]) { op, args, now, env in
            let store = env.store, counter = env.counter
            typealias Body = () throws(StateShapeError) -> JSONValue
            func attempt(_ body: Body) -> PersonaGolden.Outcome { PersonaGolden.attempt(body) }
            switch op {
            case "load":
                do throws(StateShapeError) { return .init(.json(.object(try EmotionLogic.load(store.load(.emotions), now: now)))) }
                catch { return .init(.threw(error)) }
            case "decay":
                do throws(StateShapeError) {
                    var e = try EmotionLogic.load(store.load(.emotions), now: now)
                    try EmotionLogic.decay(&e, now: now)
                    return .init(.json(.object(e)))
                } catch { return .init(.threw(error)) }
            case "event":
                let mag = args["mag"].map { PersonaGolden.double($0) ?? .nan } ?? 1.0
                return .init(attempt { () throws(StateShapeError) -> JSONValue in
                    try EmotionLogic.event(args.string("name") ?? "", magnitude: mag, store: store,
                                           now: now, research: counter)
                    return .null
                })
            case "react":
                let text = args.string("text") ?? ""
                let action: JSONValue = EmotionLogic.classify(text).map { .string($0) } ?? .null
                return .init(attempt { () throws(StateShapeError) -> JSONValue in
                    try EmotionLogic.react(text, store: store, now: now, research: counter)
                    return .null
                }, action: action)
            case "word":
                let v = PersonaGolden.double(args["v"]) ?? .nan
                return .init(attempt { () throws(StateShapeError) -> JSONValue in
                    .string(try EmotionLogic.word(args.string("dim") ?? "", v))
                })
            case "context":
                return .init(attempt { () throws(StateShapeError) -> JSONValue in
                    .string(try EmotionLogic.context(store: store, now: now))
                })
            case "set_tone":
                return .init(attempt { () throws(StateShapeError) -> JSONValue in
                    try env.tone.set(args.string("desc") ?? "", store: store, now: now, research: counter)
                    return .null
                })
            case "tone_context":
                return .init(.value(.string(env.tone.context(now: now))))
            case "set_last_tone":
                env.tone = LastTone(desc: args.string("desc") ?? "", at: PersonaGolden.double(args["at"]) ?? .nan)
                return .init(.value(.null))
            default:
                return .init(.value(.string("<unknown op \(op)>")))
            }
        }
    }

    /// _EMO_DIMS, _EMO_DELTAS (order, bit-exact values), _EMO_BANDS and the three classifier
    /// patterns (text and re.I).
    static func literals(_ e: JSONObject) -> [String] {
        var out: [String] = []
        let dims = e.array("dims") ?? []
        if dims.count != EmotionLogic.dims.count { out.append("dims: \(dims.count) vs \(EmotionLogic.dims.count)") }
        for (row, d) in zip(dims, EmotionLogic.dims) {
            let o = row.objectValue
            if o?.string("name") != d.name || PersonaGolden.double(o?["baseline"]) != d.baseline
                || PersonaGolden.double(o?["half"]) != d.halfLifeMinutes {
                out.append("dim \(d.name) differs")
            }
        }
        let deltas = e.array("deltas") ?? []
        if deltas.count != EmotionLogic.deltas.count { out.append("deltas: \(deltas.count) vs \(EmotionLogic.deltas.count)") }
        for (row, d) in zip(deltas, EmotionLogic.deltas) {
            let o = row.objectValue
            let py = (o?.array("changes") ?? []).map { ch -> String in
                let c = ch.objectValue
                return "\(c?.string("dim") ?? "?")=\(PersonaGolden.double(c?["delta"]).map { PyFloat.repr($0) } ?? "?")"
            }
            let native = d.changes.map { "\($0.dim)=\(PyFloat.repr($0.delta))" }
            if o?.string("event") != d.event || py != native { out.append("delta \(d.event): \(native) vs Python \(py)") }
        }
        let bands = e.array("bands") ?? []
        if bands.count != EmotionLogic.bands.count { out.append("bands count differs") }
        for (row, b) in zip(bands, EmotionLogic.bands) {
            let words = (row.objectValue?.array("words") ?? []).compactMap(\.stringValue)
            if row.objectValue?.string("dim") != b.dim || words != b.words { out.append("band \(b.dim) differs") }
        }
        let pats = e.object("patterns")
        for (name, re) in [("_EMO_PRAISE_RE", EmotionLogic.praisePattern), ("_EMO_THANKS_RE", EmotionLogic.thanksPattern),
                           ("_EMO_INSULT_RE", EmotionLogic.insultPattern)] {
            let o = pats?.object(name)
            if o?.string("pattern") != re.pattern || o?["ignorecase"] != .bool(re.ignoreCase) {
                out.append("\(name) differs")
            }
        }
        return out
    }
}
