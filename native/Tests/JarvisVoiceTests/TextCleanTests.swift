import Foundation
import JarvisCore
import JarvisTestSupport
import Testing
@testable import JarvisVoice

/// m8_textclean.golden.json: the REAL `speak()` (tools/golden_m8_textclean.py) over markdown,
/// bullets, whitespace, emoji, quotes, digits and inputs that clean to nothing.
@Suite("M8 TextClean golden (jarvis.py speak)")
struct TextCleanGoldenTests {
    static let suite = "m8_textclean"

    static func cases() throws -> [GoldenCase] {
        try Golden.cases(suite).filter { $0.name != "patterns" }
    }

    static func spoken(_ c: GoldenCase) -> JSONValue {
        TextClean.clean(c.input.string("text") ?? "").map { .string($0) } ?? .null
    }

    /// speak()'s two re.sub patterns, read from its AST, are the ones TextClean implements.
    @Test func patternsAreSpeaksOwn() throws {
        let patterns = try #require(try Golden.cases(Self.suite).first { $0.name == "patterns" })
        let got = patterns.expected["patterns"]?.arrayValue?.compactMap(\.stringValue)
        #expect(got == [#"[*_`#\[\]()|\\~>•]"#, #"\s+"#])
        // The character class, unescaped, is TextClean's set.
        var members = Set<Unicode.Scalar>()
        var escaped = false
        for u in #"*_`#\[\]()|\\~>•"#.unicodeScalars {
            if escaped || u != "\\" {
                members.insert(u)
                escaped = false
            } else {
                escaped = true
            }
        }
        #expect(members == TextClean.removed)
    }

    @Test(arguments: try TextCleanGoldenTests.cases())
    func matchesPython(_ c: GoldenCase) throws {
        let want = try #require(c.expected["spoken"])
        let got = Self.spoken(c)
        #expect(got == want, "\(c.name): \(String(describing: got))")
        if case .string(let s) = got, case .string(let w) = want {
            #expect(Array(s.unicodeScalars) == Array(w.unicodeScalars), "\(c.name): code points")
        }
    }

    @Test func allCasesAsserted() throws {
        let cases = try Self.cases()
        let passed = cases.filter { Self.spoken($0) == $0.expected["spoken"] }
        print("\(Self.suite): \(passed.count)/\(cases.count)")
        #expect(cases.count == 68)
        #expect(passed.count == cases.count)
    }
}
