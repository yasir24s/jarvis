import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// m1_strings.golden.json: Python `str` semantics (M01 §3.2) — lower/strip/split/splitlines,
/// s[:n], len, ==, `in`, startswith, a[-n:], min/max, set(); plus whole-Unicode tables for
/// isspace, re `\w`, lower() and the Final_Sigma context.
///
/// Known divergence `unicode-version`: `Py.isWord`/`Py.lower` read Swift's
/// `Unicode.Scalar.Properties`, whose Unicode is newer than Python 3.14's unicodedata. The
/// tables carrying that `native` block assert positively that every differing scalar is one
/// Python's Unicode leaves unassigned and the runtime dates later, or one of the named
/// `sigmaExceptions`; only the exact equality with Python is a known issue.
@Suite("M1 PyString golden (Python str)")
struct M1PyStringTests {
    static let suite = "m1_strings"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        let o = try Self.check(c)
        for m in o.native { Issue.record(Comment(rawValue: "\(c.name): native: \(m)")) }
        if let d = o.divergence {
            withKnownIssue("\(d): Swift Unicode.Scalar.Properties vs Python unicodedata") {
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
        var diverged: [String] = []
        for c in cases {
            let o = try Self.check(c)
            if let d = o.divergence, !o.python.isEmpty { diverged.append("\(c.name) [\(d)]") }
            if o.native.isEmpty && (o.divergence != nil || o.python.isEmpty) { passed += 1 }
        }
        print("\(Self.suite): \(passed)/\(cases.count)"
              + (diverged.isEmpty ? "" : " (known divergences: \(diverged.joined(separator: "; ")))"))
        #expect(passed == cases.count)
    }

    // MARK: - Case checks

    struct Outcome {
        var python: [String] = []       // where native differs from the Python expectation
        var native: [String] = []       // where native breaks the positive assertion of a divergence
        var divergence: String?         // the fixture's `native.divergence`, if any
    }

    static func check(_ c: GoldenCase) throws -> Outcome {
        let i = c.input, e = c.expected
        let op = try #require(i.string("op"))
        var o = Outcome(divergence: e.object("native")?.string("divergence"))
        func s(_ k: String) throws -> String { try #require(i.string(k), "input.\(k)") }
        func out(_ got: JSONValue) {
            if got != e["out"] { o.python.append("\(op): native \(got) python \(e["out"].map { "\($0)" } ?? "nil")") }
        }
        func strs(_ a: [String]) -> JSONValue { .array(a.map { .string($0) }) }

        switch op {
        case "lower": out(.string(Py.lower(try s("s"))))
        case "strip": out(.string(Py.strip(try s("s"))))
        case "split": out(strs(Py.split(try s("s"))))
        case "splitlines": out(strs(Py.splitlines(try s("s"))))
        case "len": out(.int(Int64(Py.len(try s("s")))))
        case "strip_chars": out(.string(Py.strip(try s("s"), try s("chars"))))
        case "lstrip_chars": out(.string(Py.lstrip(try s("s"), try s("chars"))))
        case "rstrip_chars": out(.string(Py.rstrip(try s("s"), try s("chars"))))
        case "prefix":
            let n = try #require(i.int("n"))
            out(.string(Py.prefix(try s("s"), Int(n))))
        case "eq": out(.bool(Py.eq(try s("a"), try s("b"))))
        case "contains": out(.bool(Py.contains(try s("hay"), try s("needle"))))
        case "startswith": out(.bool(Py.startsWith(try s("s"), try s("p"))))
        case "tail":
            let a = try #require(i.array("a"))
            let n = try #require(i.int("n"))
            out(.array(Py.tail(a, Int(n))))
        case "pymin", "pymax":
            let a = try bits(s("a")), b = try bits(s("b"))
            out(.string(hex(op == "pymin" ? Py.pyMin(a, b) : Py.pyMax(a, b))))
        case "clamp01":
            out(.string(hex(Py.pyMin(1.0, Py.pyMax(0.0, try bits(s("x")))))))
        case "pykey_set":
            let xs = try #require(i.array("xs")).compactMap(\.stringValue)
            var seen = Set<PyKey>(), distinct: [String] = []
            for x in xs where seen.insert(PyKey(x)).inserted { distinct.append(x) }
            if strs(distinct) != e["distinct"] { o.python.append("distinct: native \(distinct)") }
            if .int(Int64(Set(xs.map(PyKey.init)).count)) != e["count"] { o.python.append("count differs") }

        case "table_isspace":
            let want = try #require(e.array("isspace")).compactMap(\.intValue).map(UInt32.init)
            let got = allScalars.filter(Py.isSpace).map(\.value)
            if got != want { o.python.append("isspace: native \(hexList(got)) python \(hexList(want))") }
        case "table_unassigned":
            // Both sides agree on which scalars existed in Python's Unicode version.
            let version = try #require(e.string("unidata_version"))
            let (major, minor) = try parse(version)
            let pyUnassigned = try scalarSet(#require(e.array("unassigned")))
            let nativeAssigned = allScalars.filter {
                guard $0.properties.generalCategory != .unassigned, let age = $0.properties.age else { return false }
                return (age.major, age.minor) <= (major, minor)
            }.map(\.value)
            let assigned = Set(allScalars.map(\.value)).subtracting(pyUnassigned)
            let d = Set(nativeAssigned).symmetricDifference(assigned)
            if !d.isEmpty { o.python.append("assigned by \(version) differs at \(hexList(d.sorted()))") }
        case "table_word":
            let want = try scalarSet(#require(e.array("word_ranges")))
            let got = Set(allScalars.filter(Py.isWord).map(\.value))
            o.record(want.symmetricDifference(got), try versionBound(e), exceptions: [], what: "word")
        case "table_lower":
            var want: [UInt32: String] = [:]
            for pair in try #require(e.array("lower")) {
                let p = try #require(pair.arrayValue)
                let mapped: String = try #require(p[1].stringValue)
                want[try #require(p[0].intValue).u32] = mapped
            }
            var d = Set<UInt32>()
            for u in allScalars where !Py.eq(Py.lower(String(u)), want[u.value] ?? String(u)) { d.insert(u.value) }
            o.record(d, try versionBound(e), exceptions: [], what: "lower")
        case "table_sigma":
            let sigma: Unicode.Scalar = "\u{03C2}"
            let probes: [(String, (Unicode.Scalar) -> Bool)] = [
                ("after_cased_c", { Py.lower("A\(String($0))\u{03A3}").unicodeScalars.last == sigma }),
                ("after_c", { Py.lower("\(String($0))\u{03A3}").unicodeScalars.last == sigma }),
                ("before_c", { Array(Py.lower("\u{0391}\u{03A3}\(String($0))").unicodeScalars)[1] == sigma }),
            ]
            let bound = try versionBound(e)
            for (key, probe) in probes {
                let want = try scalarSet(#require(e.array(key)))
                let got = Set(allScalars.filter(probe).map(\.value))
                o.record(want.symmetricDifference(got), bound, exceptions: sigmaExceptions, what: key)
            }
        default:
            o.python.append("unknown op \(op)")
        }
        return o
    }

    /// Named known divergences in the runtime's cased / case-ignorable data that are NOT newly
    /// assigned scalars, each with the input that shows it (M01 §3.3: listed, never patched).
    static let sigmaExceptions: [(name: String, applies: @Sendable (Unicode.Scalar) -> Bool)] = [
        ("U+0295 LATIN LETTER PHARYNGEAL VOICED FRICATIVE: the runtime has it as Lo (not Cased); "
         + "Python 3.14 has Ll, so 'A\\u0295\\u03a3'.lower() ends in ς in Python, σ in native",
         { $0.value == 0x0295 && $0.properties.generalCategory == .otherLetter && !$0.properties.isCased }),
        ("Apple private-use U+F870–U+F8B8: the runtime reports some as Case_Ignorable; Python does not, "
         + "so 'A\\uf870\\u03a3'.lower() ends in σ in Python, ς in native",
         { (0xF870...0xF8B8).contains($0.value) && $0.properties.generalCategory == .privateUse
             && $0.properties.isCaseIgnorable }),
    ]

    /// The positive native assertion for `unicode-version`: a differing scalar is one Python's
    /// Unicode leaves unassigned and the runtime assigns in a later version.
    struct VersionBound {
        let pyUnassigned: Set<UInt32>
        let major: Int, minor: Int

        func explains(_ v: UInt32) -> Bool {
            guard pyUnassigned.contains(v), let u = Unicode.Scalar(v), let age = u.properties.age else { return false }
            return (age.major, age.minor) > (major, minor)
        }
    }

    static func versionBound(_ e: JSONObject) throws -> VersionBound? {
        guard let native = e.object("native") else { return nil }
        #expect(native.string("divergence") == "unicode-version")
        let (major, minor) = try parse(#require(native.string("python_unidata")))
        let table = try #require(Golden.cases(suite).first { $0.input.string("op") == "table_unassigned" })
        return VersionBound(pyUnassigned: try scalarSet(#require(table.expected.array("unassigned"))),
                            major: major, minor: minor)
    }

    // MARK: - Helpers

    /// Every Unicode scalar, in order (the surrogate gap cannot be represented).
    static let allScalars: [Unicode.Scalar] = (0..<UInt32(0x110000)).compactMap(Unicode.Scalar.init)

    static func scalarSet(_ ranges: [JSONValue]) throws -> Set<UInt32> {
        var out = Set<UInt32>()
        for r in ranges {
            let p = try #require(r.arrayValue)
            let lo = try #require(p[0].intValue).u32, hi = try #require(p[1].intValue).u32
            for v in lo...hi { out.insert(v) }
        }
        return out
    }

    static func parse(_ version: String) throws -> (Int, Int) {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        try #require(parts.count >= 2, "version \(version)")
        return (parts[0], parts[1])
    }

    static func hexList(_ vs: [UInt32]) -> String {
        let shown = vs.prefix(12).map { "U+" + String($0, radix: 16, uppercase: true) }
        return "[\(shown.joined(separator: " "))\(vs.count > 12 ? " … \(vs.count) total" : "")]"
    }

    static func bits(_ h: String) throws -> Double {
        Double(bitPattern: try #require(UInt64(h, radix: 16), "bits \(h)"))
    }

    static func hex(_ x: Double) -> String {
        let h = String(x.bitPattern, radix: 16)
        return String(repeating: "0", count: 16 - h.count) + h
    }
}

extension M1PyStringTests.Outcome {
    /// Sorts a table's differing scalars: with a version bound (a `native` block), each must be
    /// explained by it or by a named exception, and the difference itself is the Python-side
    /// known issue; without one, any difference is a plain mismatch.
    mutating func record(_ d: Set<UInt32>, _ bound: M1PyStringTests.VersionBound?,
                         exceptions: [(name: String, applies: @Sendable (Unicode.Scalar) -> Bool)],
                         what: String) {
        guard !d.isEmpty else { return }
        let sorted = d.sorted()
        python.append("\(what): native and Python differ at \(sorted.count) scalars \(M1PyStringTests.hexList(sorted))")
        guard let bound else { return }
        var unexplained: [UInt32] = []
        var named: [String: Int] = [:]
        for v in sorted {
            if bound.explains(v) { continue }
            if let u = Unicode.Scalar(v), let x = exceptions.first(where: { $0.applies(u) }) {
                named[x.name, default: 0] += 1
            } else {
                unexplained.append(v)
            }
        }
        let newer = sorted.count - unexplained.count - named.values.reduce(0, +)
        python.append("\(what): \(newer) newly assigned after Python's Unicode"
                      + named.map { "; \($0.value) × \($0.key)" }.sorted().joined())
        if !unexplained.isEmpty {
            native.append("\(what): \(unexplained.count) differences not explained by the Unicode version "
                          + "or a named exception \(M1PyStringTests.hexList(unexplained))")
        }
    }
}

private extension JSONValue {
    var intValue: Int64? { if case .int(let i) = self { i } else { nil } }
}

private extension Int64 {
    var u32: UInt32 { UInt32(self) }
}
