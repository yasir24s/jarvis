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

/// F5 is given numbers in words (a native addition; DEVIATIONS row proposed in the M8 report).
@Suite("M8 TextClean.spokenNumbers (F5 only)")
struct SpokenNumbersTests {
    @Test(arguments: [
        ("Your battery is at 64%.", "Your battery is at sixty-four percent."),
        ("It's 3:45 PM.", "It's three forty-five PM."),
        ("That costs £20.", "That costs twenty pounds."),
        ("It's 9:05 now.", "It's nine oh five now."),
        ("Meet at 15:00.", "Meet at fifteen."),
        ("The 3:45pm train.", "The three forty-five pm train."),
        ("Only £1 left.", "Only one pound left."),
        ("It was $3.99, or €2.50.", "It was three dollars ninety-nine, or two euros fifty."),
        ("Pi is 3.14.", "Pi is three point one four."),
        ("1,500 people came.", "one thousand five hundred people came."),
        ("Up 12 % today.", "Up twelve percent today."),
        ("In 2026, at 0.", "In two thousand twenty-six, at zero."),
        ("Lists: 1, 2, 3.", "Lists: one, two, three."),
        ("An MP3 on the 1st, in 4K.", "An MP3 on the 1st, in 4K."),
        ("No digits here.", "No digits here."),
        ("", ""),
    ])
    func spellsOut(_ input: String, _ want: String) {
        #expect(TextClean.spokenNumbers(input) == want)
    }

    @Test func otherScriptsDigitsAreLeftAlone() {
        #expect(TextClean.spokenNumbers("Arabic ٦٤ stays") == "Arabic ٦٤ stays")
    }
}
