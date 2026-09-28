import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_difflib.golden.json: Python 3.14 `difflib.SequenceMatcher(None, a, b)` (M01 §3.4) —
/// `ratio()` compared by bit pattern (and repr), `get_matching_blocks()` exactly, the length in
/// code points, and the result of each jarvis.py threshold comparison, over edge cases,
/// unicode, the autojunk boundary (len(b) 199/200/201/300, count == ntest), pathological
/// repeats, the _apply_corrections and track_feedback input shapes around their thresholds,
/// and 540 seeded small-alphabet pairs. No divergences: every case must match Python.
@Suite("M1 PyDifflib golden (Python difflib)")
struct M1PyDifflibTests {
    static let suite = "m1_difflib"

    /// The threshold comparisons the M1 ports make, as Swift operators (M01 §3.4). The
    /// fixture's `sites` case holds the ones jarvis.py's source makes; they must be these.
    static let sites: [(function: String, op: String, value: Double)] = [
        ("_apply_corrections", ">=", 0.82),
        ("track_feedback", ">", 0.65),
    ]

    static func compare(_ function: String, _ r: Double) -> Bool? {
        switch function {
        case "_apply_corrections": r >= 0.82
        case "track_feedback": r > 0.65
        default: nil
        }
    }

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

    // MARK: - Case checks

    static func check(_ c: GoldenCase) throws -> [String] {
        let i = c.input, e = c.expected
        var out: [String] = []
        if i.string("group") == "sites" {
            let got = try #require(e.array("sites")).map { s -> (String, String, Double) in
                let o = s.objectValue
                return (o?.string("function") ?? "?", o?.string("op") ?? "?", o?.double("value") ?? .nan)
            }
            if got.count != sites.count || !zip(got, sites).allSatisfy({ $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2 }) {
                out.append("jarvis.py thresholds \(got) != native \(sites)")
            }
            return out
        }
        let a = try #require(i.string("a")), b = try #require(i.string("b"))
        let sa = Array(a.unicodeScalars), sb = Array(b.unicodeScalars)

        let len = try #require(e.array("len")).map(int)
        if len != [sa.count, sb.count] { out.append("len \([sa.count, sb.count]) != \(len)") }

        let blocks = PyDifflib.matchingBlocks(sa, sb).map { [$0.a, $0.b, $0.size] }
        let want = try #require(e.array("blocks")).map { ($0.arrayValue ?? []).map(int) }
        if blocks != want { out.append("blocks \(blocks) != \(want)") }

        let r = PyDifflib.ratio(a, b)
        let ratio = try #require(e.object("ratio"))
        let hex = try #require(ratio.string("bits"))
        let bits = try #require(UInt64(hex, radix: 16))
        if r.bitPattern != bits {
            out.append("ratio bits \(String(r.bitPattern, radix: 16)) != \(String(bits, radix: 16))")
        }
        if PyFloat.repr(r) != ratio.string("repr") {
            out.append("ratio repr \(PyFloat.repr(r)) != \(ratio.string("repr") ?? "nil")")
        }

        let results = try #require(e.object("sites"))
        for (function, _, _) in sites {
            let py: Bool? = if case .bool(let x)? = results[function] { x } else { nil }
            if compare(function, r) != py {
                out.append("\(function) comparison \(compare(function, r).map(String.init) ?? "nil") != \(py.map(String.init) ?? "nil")")
            }
        }
        return out
    }

    static func int(_ v: JSONValue) -> Int {
        if case .int(let n) = v { Int(n) } else { -1 }
    }
}
