import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_personality.golden.json (M01 §2.2, §3.7, §6 T7): every step of every scenario runs the
/// native PersonalityLogic against a Sandbox seeded with the case's starting bytes, then must
/// equal what the real jarvis.py functions did — the returned value (or that Python raised),
/// the research_bump sequence, and personality.json's bytes on disk afterwards. maybe_learn
/// steps also compare `styleAction(for:)` with the personality_learn / personality_forget call
/// Python made. The "literals" case compares the seed and pattern tables with jarvis.py's.
@Suite("M1 personality golden (jarvis.py personality_*)")
struct M1PersonalityTests {
    static let suite = "m1_personality"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        for m in try Self.check(c) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        for c in cases where try Self.check(c).isEmpty { passed += 1 }
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
    }

    static func check(_ c: GoldenCase) throws -> [String] {
        if c.name == "literals" { return literals(c.expected) }
        return try PersonaGolden.run(c, files: ["personality.json"]) { op, args, now, env in
            let store = env.store
            switch op {
            case "load":
                return .init(.json(.object(PersonalityLogic.load(store.load(.personality)))))
            case "learn":
                return .init(PersonaGolden.attempt { () throws(StateShapeError) -> JSONValue in
                    try PersonalityLogic.learn(args.string("note") ?? "", store: store, now: now)
                    return .null
                })
            case "forget":
                PersonalityLogic.forget(store: store)
                return .init(.value(.null))
            case "note_tool":
                return .init(PersonaGolden.attempt { () throws(StateShapeError) -> JSONValue in
                    .string(try PersonalityLogic.noteTool(args.string("note") ?? "", store: store, now: now))
                })
            case "rewrite_tool":
                return .init(.value(.string(PersonalityLogic.rewriteTool(args.string("core") ?? "", store: store))))
            case "context":
                return .init(PersonaGolden.attempt { () throws(StateShapeError) -> JSONValue in
                    .string(try PersonalityLogic.context(store: store))
                })
            case "maybe_learn":
                let text = args.string("text") ?? ""
                let action: JSONValue = switch PersonalityLogic.styleAction(for: text) {
                case .factoryReset?: .object(JSONObject([.init(key: "action", value: .string("factory_reset"))]))
                case .learn(let note)?: .object(JSONObject([.init(key: "action", value: .string("learn")),
                                                            .init(key: "note", value: .string(note))]))
                case nil: .null
                }
                let outcome = PersonaGolden.attempt { () throws(StateShapeError) -> JSONValue in
                    try PersonalityLogic.maybeLearn(text, store: store, now: now)
                    return .null
                }
                return .init(outcome, action: action)
            default:
                return .init(.value(.string("<unknown op \(op)>")))
            }
        }
    }

    /// The seed, `_PERSONALITY_FORGET_RE` and `_STYLE_PATTERNS` (pattern text, re.I, template).
    static func literals(_ e: JSONObject) -> [String] {
        var out: [String] = []
        if PyJSON.dumps(.object(PersonalityLogic.seed()), indent: 1) != e.string("seed_json") {
            out.append("seed differs from _PERSONALITY_SEED")
        }
        let f = e.object("forget_re")
        if f?.string("pattern") != PersonalityLogic.forgetPattern.pattern
            || f?["ignorecase"] != .bool(PersonalityLogic.forgetPattern.ignoreCase) {
            out.append("_PERSONALITY_FORGET_RE differs")
        }
        let rows = e.array("style_patterns") ?? []
        if rows.count != PersonalityLogic.stylePatterns.count {
            out.append("_STYLE_PATTERNS has \(rows.count) rows, native \(PersonalityLogic.stylePatterns.count)")
        }
        for (k, (row, sp)) in zip(rows, PersonalityLogic.stylePatterns).enumerated() {
            let o = row.objectValue
            if o?.string("pattern") != sp.regex.pattern { out.append("style row \(k): pattern differs") }
            if o?["ignorecase"] != .bool(sp.regex.ignoreCase) { out.append("style row \(k): flags differ") }
            if o?.string("template") != sp.template { out.append("style row \(k): template differs") }
        }
        return out
    }
}

/// The scenario runner shared by the persona golden suites (m1_personality,
/// m1_emotions_tone). A case is `input.files_before` + `input.steps [{op, args, now}]`;
/// `expected.steps [{result, bumps, files_after, action?}]` (tools/golden_m1_persona.py).
enum PersonaGolden {
    enum Outcome {
        case value(JSONValue)           // {"value": …}; Python's None is .null
        case json(JSONValue)            // {"json": json.dumps(obj, indent=1)}
        case threw(StateShapeError)     // {"raises": "<Python exception name>"}
    }

    struct Step {
        let outcome: Outcome
        let action: JSONValue?          // maybe_learn only
        init(_ outcome: Outcome, action: JSONValue? = nil) {
            self.outcome = outcome
            self.action = action
        }
    }

    final class Env {
        let root: String
        let store: StateStore
        let counter = RecordingCounter()

        init(root: String, store: StateStore) {
            self.root = root
            self.store = store
        }
    }

    static let homeToken = "${JARVIS_HOME}"

    static func attempt(_ body: () throws(StateShapeError) -> JSONValue) -> Outcome {
        do { return .value(try body()) } catch { return .threw(error) }
    }

    /// {"repr", "bits"} → the exact double (the bits decide; the repr is cross-checked).
    static func double(_ v: JSONValue?) -> Double? {
        guard let o = v?.objectValue, let hex = o.string("bits"), let bits = UInt64(hex, radix: 16) else {
            return nil
        }
        let d = Double(bitPattern: bits)
        return o.string("repr") == PyFloat.repr(d) ? d : nil
    }

    static func run(_ c: GoldenCase, files: [String],
                    step: (String, JSONObject, Double, Env) throws -> Step) throws -> [String] {
        guard let before = c.input.object("files_before"), let steps = c.input.array("steps"),
              let expected = c.expected.array("steps"), steps.count == expected.count, !steps.isEmpty,
              let now0 = double(steps[0].objectValue?["now"]) else {
            return ["malformed scenario"]
        }
        let sb = try Sandbox()
        defer { sb.remove() }
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        for f in files {
            guard let b64 = before.string(f) else { continue }
            guard let data = Data(base64Encoded: b64) else { return ["files_before[\(f)] is not base64"] }
            try data.write(to: sb.root.appending(path: f, directoryHint: .notDirectory))
        }
        let env = Env(root: root, store: try StateStore(root: root, lease: nil, clock: ManualClock(now0)))
        var out: [String] = []
        for (k, (s, e)) in zip(steps, expected).enumerated() {
            guard let so = s.objectValue, let eo = e.objectValue, let op = so.string("op"),
                  let args = so.object("args"), let now = double(so["now"]),
                  let result = eo.object("result"), let bumps = eo.array("bumps"),
                  let filesAfter = eo.object("files_after") else {
                out.append("step \(k): malformed")
                continue
            }
            let tag = "step \(k) \(op)"
            env.counter.reset()
            let got = try step(op, args, now, env)
            if let m = compare(got.outcome, result, root: root) { out.append("\(tag): \(m)") }
            if eo.has("action"), got.action != eo["action"] {
                out.append("\(tag): action \(String(describing: got.action)) != Python \(String(describing: eo["action"]))")
            }
            let want = bumps.map { b -> String in
                let a = b.arrayValue ?? []
                let n: Int64 = if case .int(let i)? = a.last { i } else { -1 }
                return "\(a.first?.stringValue ?? "?")+\(n)"
            }
            let have = env.counter.bumps.map(\.description)
            if have != want { out.append("\(tag): bumps \(have) != Python \(want)") }
            for m in filesAfter.members {
                let data = try? Data(contentsOf: sb.root.appending(path: m.key, directoryHint: .notDirectory))
                let have = data?.base64EncodedString()
                if have != m.value.stringValue {
                    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? "<absent>"
                    out.append("\(tag): \(m.key) bytes differ; native wrote \(text.debugDescription.prefix(400))")
                }
            }
        }
        return out
    }

    static func compare(_ got: Outcome, _ want: JSONObject, root: String) -> String? {
        switch got {
        case .threw(let err):
            return want.has("raises") ? nil : "native threw \(err); Python returned \(want)"
        case .value(let v):
            if let r = want.string("raises") { return "Python raised \(r); native returned \(v)" }
            guard let w = want["value"] else { return "expected a json result, native gave a value" }
            let expected: JSONValue = if case .string(let s) = w {
                .string(s.replacingOccurrences(of: homeToken, with: root, options: .literal))
            } else { w }
            return v == expected ? nil : "value \(String(describing: v).debugDescription.prefix(600)) != Python \(String(describing: expected).debugDescription.prefix(600))"
        case .json(let v):
            if let r = want.string("raises") { return "Python raised \(r); native returned json" }
            let text = PyJSON.dumps(v, indent: 1)
            return text == want.string("json") ? nil : "json \(text.debugDescription.prefix(600)) != Python \((want.string("json") ?? "nil").debugDescription.prefix(600))"
        }
    }
}
