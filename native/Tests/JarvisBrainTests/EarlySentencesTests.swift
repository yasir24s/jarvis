import JarvisBrain
import Testing

/// V8: the voice's sentences from a reply that is still streaming (`EarlySentences`).
@Suite("V8 early sentences from a streaming reply")
struct EarlySentencesTests {
    /// Feeds `text` in chunks of `size` characters; returns what each push gave, then `finish`.
    static func feed(_ text: String, size: Int) -> (pushes: [[String]], finished: [String]) {
        var s = EarlySentences()
        var pushes: [[String]] = []
        var chunk = ""
        for c in text {
            chunk.append(c)
            if chunk.count == size {
                pushes.append(s.push(chunk))
                chunk = ""
            }
        }
        if !chunk.isEmpty { pushes.append(s.push(chunk)) }
        return (pushes, s.finish())
    }

    static func all(_ text: String, size: Int) -> [String] {
        let (pushes, finished) = feed(text, size: size)
        return pushes.flatMap { $0 } + finished
    }

    @Test func aSentenceIsHandedOverOnceTheWhitespaceAfterItsEndHasCome() {
        var s = EarlySentences()
        #expect(s.push("The weather in London is mild today.").isEmpty)   // could be "today.5"
        #expect(s.push(" Rain") == ["The weather in London is mild today."])
        #expect(s.push(" later.").isEmpty)
        #expect(s.finish() == ["Rain later."])
        #expect(s.handed == ["The weather in London is mild today.", "Rain later."])
    }

    @Test(arguments: [1, 2, 3, 7, 50])
    func abbreviationsInitialsAndDecimalsDoNotSplit(size: Int) {
        let reply = "Dr. Smith said the dose is 3.5 mg, e.g. twice a day. J. Watson agreed at 9 a.m. today. "
            + "Call 020 7946 0018 or see www.example.co.uk/page.html for more. Done!"
        #expect(Self.all(reply, size: size) == [
            "Dr. Smith said the dose is 3.5 mg, e.g. twice a day.",
            "J. Watson agreed at 9 a.m. today.",
            "Call 020 7946 0018 or see www.example.co.uk/page.html for more.",
            "Done!",
        ])
    }

    @Test func aListNumberStaysWithItsItem() {
        #expect(Self.all("Here are two. 1. Eggs. 2. Milk.", size: 4) == ["Here are two.", "1. Eggs.", "2. Milk."])
    }

    @Test func theLengthCutIsNotASentenceEnd() {
        let long = String(repeating: "word ", count: 40) + "end. Next one."
        let out = Self.all(long, size: 5)
        #expect(out == [Self.collapse(String(repeating: "word ", count: 40) + "end."), "Next one."])
    }

    static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @Test func theFirstSentenceComesBeforeTheReplyEnds() {
        let (pushes, finished) = Self.feed("Certainly. The meeting is at three o'clock on Friday. Bring the notes", size: 6)
        let firstAt = pushes.firstIndex { !$0.isEmpty }
        #expect(firstAt != nil && firstAt! < pushes.count - 1)
        #expect(finished == ["Bring the notes"])
    }

    @Test func theRestOfAFinalReplyAfterWhatWasSpoken() {
        let spoken = ["The meeting is at three.", "Bring the notes."]
        #expect(EarlySentences.rest(of: "The meeting is at three.\n\nBring the notes. And a pen.", after: spoken)
                == "And a pen.")
        #expect(EarlySentences.rest(of: "The meeting is at three. Bring the notes.", after: spoken) == "")
        #expect(EarlySentences.rest(of: "The meeting is at four. Bring the notes.", after: spoken) == nil)
        #expect(EarlySentences.rest(of: "The meeting is at three.", after: spoken) == nil)
    }
}
