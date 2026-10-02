import JarvisCore
import JarvisTestSupport
import Testing

/// M11: the wake word in text, against jarvis.py's own functions (golden suite m11_phrases):
/// contains_wake_word, extract_command, _is_enroll and _INCOMPLETE_TAIL_RE.search.
@Suite("M11 wake phrases (golden)")
struct WakePhrasesGoldenTests {
    static func flag(_ value: JSONValue?) -> Bool? {
        if case .bool(let b)? = value { b } else { nil }
    }

    @Test("WAKE_WORDS is jarvis.py's list")
    func wakeWords() throws {
        let c = try #require(try Golden.cases("m11_phrases").first { $0.name == "wake_words" })
        #expect(c.expected.array("WAKE_WORDS")?.compactMap(\.stringValue) == WakePhrases.wakeWords)
    }

    @Test(arguments: try Golden.cases("m11_phrases").filter { $0.name != "wake_words" })
    func phrase(_ c: GoldenCase) {
        // A JSON null is Python's None.
        let text = c.input.string("text")
        #expect(WakePhrases.containsWakeWord(text) == Self.flag(c.expected["contains_wake_word"]), "contains_wake_word")
        let command = WakePhrases.extractCommand(text)
        let want = c.expected.string("extract_command")
        #expect(want.map { command.unicodeScalars.elementsEqual($0.unicodeScalars) } == true,
                "extract_command gave \(command.debugDescription), Python \(String(describing: want).debugDescription)")
        #expect(WakePhrases.isEnroll(text) == Self.flag(c.expected["is_enroll"]), "_is_enroll")
        if let text {
            #expect(WakePhrases.endsMidSentence(text) == Self.flag(c.expected["incomplete_tail"]), "_INCOMPLETE_TAIL_RE")
        }
    }
}
