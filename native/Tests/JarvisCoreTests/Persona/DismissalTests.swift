import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// p1_dismiss.golden.json: the REAL nested `is_dismiss(t)` (tools/golden_p1_dismiss.py) over
/// every phrase it holds in ten forms, near misses, Unicode whitespace, None and "".
@Suite("P1 dismissal golden (jarvis.py is_dismiss)")
struct DismissalGoldenTests {
    static let suite = "p1_dismiss"

    static func cases() throws -> [GoldenCase] {
        try Golden.cases(suite).filter { $0.name != "literals" }
    }

    /// The phrases are Python's, in source order.
    @Test func literalsAreJarvisPys() throws {
        let literals = try #require(try Golden.cases(Self.suite).first { $0.name == "literals" })
        #expect(literals.expected["contained"]?.arrayValue?.compactMap(\.stringValue) == Dismissal.contained)
        #expect(literals.expected["exact"]?.arrayValue?.compactMap(\.stringValue) == Dismissal.exact)
    }

    @Test(arguments: try DismissalGoldenTests.cases())
    func matchesPython(_ c: GoldenCase) throws {
        let got = Dismissal.isDismiss(c.input.string("t"))
        #expect(JSONValue.bool(got) == c.expected["dismiss"], "\(c.name)")
    }

    @Test func allCasesAsserted() throws {
        let cases = try Self.cases()
        let passed = cases.filter { JSONValue.bool(Dismissal.isDismiss($0.input.string("t"))) == $0.expected["dismiss"] }
        print("\(Self.suite): \(passed.count)/\(cases.count)")
        #expect(cases.count == 160)
        #expect(passed.count == cases.count)
    }
}

/// The text channel's stricter rule (a deviation): the whole typed message must be a
/// dismissal, after lowercasing, dropping punctuation and one trailing "jarvis" or "sir".
@Suite("P1 dismissal: the text channel's whole-message rule")
struct TextDismissalTests {
    @Test(arguments: [
        "that's all", "That's all, JARVIS.", "thats all jarvis", "That will be all, sir.", "Thanks!",
        "thanks", "Thanks, JARVIS", "thanks jarvis", "Thank you.", "THANK YOU, SIR", "thank you jarvis",
        "Goodbye", "goodbye, jarvis!", "Goodbye JARVIS", "bye jarvis", "Bye, Jarvis.", "Dismissed.",
        "stand down", "Stand down, JARVIS.", "Go to sleep.", "go to sleep jarvis", "That is all.",
        "  that is all, sir  ", "that\u{2019}s all", "that’s all, Jarvis", "thanks jarvis, sir",
        "Thanks\u{00A0}JARVIS", "thanks... jarvis", "(thanks)", "good-bye",
    ])
    func wholeMessageDismissals(_ text: String) {
        #expect(Dismissal.isTextDismissal(text), "\(text)")
    }

    @Test(arguments: [
        "thanks, now open Safari", "thank you for the help", "Thanks JARVIS, what time is it?",
        "that's all for now", "is that all?", "don't go to sleep", "you are not dismissed", "undismissed",
        "goodbye for now", "thanks Robin", "jarvis", "sir", "jarvis thanks", "Jarvis, that's all",
        "thank you sir jarvis sir", "bye", "thankyou", "stand downstairs", "",
        "   ", "!!!", "thanks 🙏", "open Safari", "sir, that will be all",
    ])
    func everythingElseReachesTheBrain(_ text: String) {
        #expect(!Dismissal.isTextDismissal(text), "\(text)")
    }

    /// Stricter than the voice rule: Python's substring tests take these, the text rule does not.
    @Test func voiceTakesWhatTextDoesNot() {
        for text in ["thanks jarvis, now open Safari", "thank you for the help", "you are not dismissed"] {
            #expect(Dismissal.isDismiss(text), "\(text)")
            #expect(!Dismissal.isTextDismissal(text), "\(text)")
        }
    }
}
