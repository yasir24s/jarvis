import Foundation
import JarvisCore
import Testing

/// P4, DEV-P4-03: a kept note ends on a sentence, else a whole word, instead of Python's
/// `note[:200]`. Python's verdict for the golden cases it changes is a known issue in
/// M1PersonalityTests; these assert native's side.
@Suite("P4 personality notes end on a sentence")
struct NoteCutTests {
    static func text(_ n: Int, _ fill: Character = "x") -> String { String(repeating: fill, count: n) }

    @Test func aNoteThatFitsIsKeptWhole() {
        #expect(PersonalityLogic.noteLimit == 200)
        let exact = "The user " + Self.text(191)                     // 200 code points
        #expect(PersonalityLogic.noteCut(exact) == exact)
        #expect(PersonalityLogic.noteCut("Short note.") == "Short note.")
    }

    @Test func theLongestPrefixThatEndsASentenceIsKept() {
        let first = "The user likes a dry joke. "                      // 27
        let second = "The user wants replies short (one line!) when busy. "
        let long = first + second + Self.text(150)
        #expect(PersonalityLogic.noteCut(long) == first + "The user wants replies short (one line!) when busy.")
        // A closing quote or bracket after the full stop belongs to the sentence.
        let quoted = "The user says \"cheers.\" " + Self.text(190)
        #expect(PersonalityLogic.noteCut(quoted) == "The user says \"cheers.\"")
        // A full stop inside a number or a word is not a sentence end.
        let number = "The user runs 3.5 km and likes v1.2 builds " + Self.text(170, "y")
        #expect(PersonalityLogic.noteCut(number) == "The user runs 3.5 km and likes v1.2 builds")
    }

    @Test func aSentenceEndingExactlyAtTheLimitIsKept() {
        let sentence = "The user " + Self.text(190) + "."             // 200 code points
        #expect(PersonalityLogic.noteCut(sentence + " More words follow here.") == sentence)
    }

    @Test func withNoSentenceEndTheLastWholeWordIsKept() {
        // 150 L's, then words; the 200th code point falls inside the last word.
        let note = Self.text(150, "L") + " synthetic long note tail A " + Self.text(80, "a")
        #expect(Py.len(note) == 258)
        #expect(PersonalityLogic.noteCut(note) == Self.text(150, "L") + " synthetic long note tail A")
        // Trailing commas, semicolons, colons and dashes go with the cut.
        let comma = Self.text(190, "w") + " sir, " + Self.text(30, "z")
        #expect(PersonalityLogic.noteCut(comma) == Self.text(190, "w") + " sir")
        let dash = Self.text(195, "w") + " — " + Self.text(30, "z")
        #expect(PersonalityLogic.noteCut(dash) == Self.text(195, "w"))
        // A space exactly after the 200th code point keeps all 200.
        let atLimit = Self.text(200, "w") + " tail"
        #expect(PersonalityLogic.noteCut(atLimit) == Self.text(200, "w"))
    }

    /// One run with no word boundary inside the limit is cut at 200 code points, as Python
    /// does: the golden consolidate_reply_long_and_dash_only case stays Python's.
    @Test func withNoWordBoundaryTheCutIsPythons() {
        for note in [Self.text(250, "L"), String(repeating: "é", count: 205), String(repeating: "😀", count: 300),
                     "😀" + Self.text(260, "q")] {
            #expect(PersonalityLogic.noteCut(note) == Py.prefix(note, 200))
        }
    }

    /// The limit counts code points, as Python's len does, not grapheme clusters: a letter with
    /// a combining accent is two. 123 graphemes, but 222 code points, and "ab" ends at the 201st.
    @Test func theLimitCountsCodePoints() {
        let accented = String(repeating: "e\u{301}", count: 99) + " ab " + Self.text(20, "c")   // 198 + 4 + 20
        #expect(accented.count == 123 && Py.len(accented) == 222)
        #expect(PersonalityLogic.noteCut(accented) == String(repeating: "e\u{301}", count: 99))
    }

    /// learn_over_200's steps, native's side: each 258-character note is cut after "tail A".
    /// The dedupe key is still the whole note's, as in Python, so all three are kept.
    @Test func learnOver200KeepsWholeWords() throws {
        let a = Self.text(150, "L") + " synthetic long note tail A " + Self.text(80, "a")
        let b = Self.text(150, "L") + " synthetic long note tail A " + Self.text(80, "b")
        var p = PersonalityLogic.seed()
        for (i, note) in [a, b, a].enumerated() {
            #expect(try PersonalityLogic.learn(note, in: &p, now: 1_790_582_400 + Double(i)))
        }
        let notes = (p["learned"]?.arrayValue ?? []).compactMap { $0.objectValue?["note"]?.stringValue }
        #expect(notes == Array(repeating: Self.text(150, "L") + " synthetic long note tail A", count: 3))
    }

    @Test func consolidationLinesAreCutTheSameWay() {
        let reply = "- The user likes a dry joke. " + Self.text(190) + "\n• Short synthetic note here"
        #expect(PersonaDistill.consolidationCandidates(fromReply: reply)
                == ["The user likes a dry joke.", "Short synthetic note here"])
    }

    /// Both writers are asked for notes under 180 characters, after Python's own messages.
    @Test func theWritersAreAskedForShortNotes() {
        #expect(PersonaDistill.noteLengthRequest == " Keep each note under 180 characters.")
        #expect(PersonaDistill.consolidateSystem == PersonaDistill.pythonConsolidateSystem + PersonaDistill.noteLengthRequest)
        #expect(PersonaDistill.distillSystem == PersonaDistill.pythonDistillSystem + PersonaDistill.noteLengthRequest)
        #expect(PersonaDistill.pythonDistillSystem.hasSuffix("starting 'The user ', or exactly NONE."))
    }
}
