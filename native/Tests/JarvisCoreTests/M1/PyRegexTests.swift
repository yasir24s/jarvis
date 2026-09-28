import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_regex.golden.json: Python `re` on NSRegularExpression (M01 §3.3) — every regex the M1
/// subsystems use from jarvis.py (search, plus the op each inline site uses: sub / findall /
/// match), the `\b{re.escape(heard)}\b` pattern of _apply_corrections, re.escape, the §3.3
/// translation rules, and whole-Unicode tables of the single-character classes in scope.
///
/// Every divergence is a `native` block in the fixture, computed by the generator:
/// - `R5-case-folding` (M01 §8 R5): ICU folds case-insensitive literals fully (ß ~ ss, ﬀ ~ ff)
///   and gives İ/ı no case tie to i/I; the block holds the result of the generator's model of
///   that, which native must equal.
/// - `sub-literal-repl`: Python processes backslashes in a str repl; `sub(_:literal:)` does not.
///   The block holds Python's literal-replacement result.
/// - `unsupported-construct`: a pattern M01 §3.3 has native refuse; PyRegex must throw.
/// - `unicode-version`: the runtime's Unicode is newer than Python's unicodedata; differing
///   scalars must all be ones Python leaves unassigned.
/// Native behaviour is asserted positively; only the Python expectation is a known issue.
@Suite("M1 PyRegex golden (Python re)")
struct M1PyRegexTests {
    static let suite = "m1_regex"
    typealias Outcome = M1PyStringTests.Outcome

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        let o = try Self.check(c)
        for m in o.native { Issue.record(Comment(rawValue: "\(c.name): native: \(m)")) }
        if let d = o.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in o.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        } else {
            for m in o.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        }
    }

    /// M01 §5 A5: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        var diverged: [String: Int] = [:]
        for c in cases {
            let o = try Self.check(c)
            if let d = o.divergence, !o.python.isEmpty { diverged[d, default: 0] += 1 }
            // A divergence case passes when native holds and the Python difference shows
            // (withKnownIssue fails when it does not).
            if o.native.isEmpty && (o.divergence == nil) == o.python.isEmpty { passed += 1 }
        }
        let summary = diverged.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }
        print("\(Self.suite): \(passed)/\(cases.count)"
              + (summary.isEmpty ? "" : " (known divergences: \(summary.joined(separator: ", ")))"))
        #expect(passed == cases.count)
    }

    // MARK: - Case checks

    static func check(_ c: GoldenCase) throws -> Outcome {
        let i = c.input, e = c.expected
        let op = try #require(i.string("op"))
        let block = e.object("native")
        var o = Outcome(divergence: block?.string("divergence"))
        let ignoreCase = i["ignorecase"] == .bool(true)

        switch op {
        case "compile":
            // Python rejects the pattern; native must reject it too.
            if (try? PyRegex(try #require(i.string("pattern")), ignoreCase: ignoreCase)) != nil {
                o.python.append("native compiled a pattern Python rejects (\(e["error"] ?? .null))")
            }
        case "table_unassigned":
            let version = try #require(e.string("unidata_version"))
            let (major, minor) = try M1PyStringTests.parse(version)
            let pyUnassigned = try M1PyStringTests.scalarSet(#require(e.array("unassigned")))
            let all = M1PyStringTests.allScalars
            let nativeAssigned = all.filter {
                guard $0.properties.generalCategory != .unassigned, let age = $0.properties.age else { return false }
                return (age.major, age.minor) <= (major, minor)
            }.map(\.value)
            let d = Set(nativeAssigned).symmetricDifference(Set(all.map(\.value)).subtracting(pyUnassigned))
            if !d.isEmpty { o.python.append("assigned by \(version) differs at \(M1PyStringTests.hexList(d.sorted()))") }
        case "table":
            let rx = try PyRegex(try #require(i.string("pattern")), ignoreCase: ignoreCase)
            var got = Set<UInt32>()
            for m in rx.findall(allScalarsString) {
                let u = Array(m.unicodeScalars)
                try #require(u.count == 1, "a one-character class matched \(u.count) scalars")
                got.insert(u[0].value)
            }
            let want = try M1PyStringTests.scalarSet(#require(e.array("ranges")))
            o.record(want.symmetricDifference(got), try M1PyStringTests.versionBound(e, fixture: suite),
                     exceptions: [], what: "class")
        default:
            let key = e.has("out") || op == "findall" || op.hasSuffix("sub") ? "out" : "match"
            let got: JSONValue
            do {
                got = try nativeResult(c)
            } catch {
                if o.divergence == "unsupported-construct" {
                    // M01 §3.3: native refuses this construct, so Python's result is the known issue.
                    o.python.append("native refuses it (\(error)); Python: \(e[key] ?? .null)")
                } else {
                    o.python.append("native threw \(error)")
                }
                return o
            }
            switch o.divergence {
            case nil:
                if got != e[key] { o.python.append("\(key): native \(got) python \(e[key] ?? e["error"] ?? .null)") }
            case "R5-case-folding", "sub-literal-repl":
                let want = try #require(block?[key], "native.\(key)")
                if got != want { o.native.append("\(key): native \(got), native block \(want)") }
                if got != e[key] { o.python.append("\(key): native \(got) python \(e[key] ?? e["error"] ?? .null)") }
            case "unsupported-construct":
                o.native.append("PyRegex compiled a construct M01 §3.3 refuses: \(got)")
            default:
                o.native.append("unknown divergence \(o.divergence ?? "")")
            }
        }
        return o
    }

    /// Native's result for a search / match / findall / sub / escape / dyn_* case, in the
    /// fixture's JSON shape. Throws when PyRegex refuses the pattern.
    static func nativeResult(_ c: GoldenCase) throws -> JSONValue {
        let i = c.input
        let op = try #require(i.string("op")), text = try #require(i.string("s"))
        let ignoreCase = i["ignorecase"] == .bool(true)
        let pattern: String
        switch op {
        case "dyn_search", "dyn_sub":
            // M01 §3.3: the escape happens before translation; only the two \b are rewritten.
            pattern = "\\b" + PyRegex.escape(try #require(i.string("heard"))) + "\\b"
        case "escape":
            pattern = PyRegex.escape(try #require(i.string("x")))
        default:
            pattern = try #require(i.string("pattern"))
        }
        let rx = try PyRegex(pattern, ignoreCase: ignoreCase)
        switch op {
        case "search", "dyn_search", "escape": return json(rx.search(text))
        case "match": return json(rx.match(text))
        case "findall": return .array(rx.findall(text).map { .string($0) })
        case "sub", "dyn_sub": return .string(rx.sub(text, literal: try #require(i.string("repl"))))
        default: throw GoldenError.malformed(Golden.url(suite), "unknown op \(op)")
        }
    }

    // MARK: - Helpers

    static func json(_ m: PyMatch?) -> JSONValue {
        guard let m else { return .null }
        return .object(JSONObject([
            .init(key: "span", value: .array([.int(Int64(m.span.lowerBound)), .int(Int64(m.span.upperBound))])),
            .init(key: "groups", value: .array(m.groups.map { $0.map(JSONValue.string) ?? .null })),
        ]))
    }

    /// Every scalar in order, as one string: a one-character class's matches in it are its table.
    static let allScalarsString = String(String.UnicodeScalarView(M1PyStringTests.allScalars))
}
