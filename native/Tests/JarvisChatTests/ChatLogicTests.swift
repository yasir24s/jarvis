import Foundation
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import Testing

@Suite("M4 delta coalescing (plan 3.12)")
struct DeltaCoalescerTests {
    @Test("the first delta shows at once; the rest of its gap is held, then shown together")
    func holdsWithinTheGap() {
        let gap = DeltaCoalescer.interval
        #expect(gap == .seconds(1) / 30)
        var coalescer = DeltaCoalescer()
        let t0 = ContinuousClock.now
        #expect(coalescer.append("It ", at: t0) == .publish)
        #expect(coalescer.publish(at: t0) == "It ")
        #expect(coalescer.append("is ", at: t0 + .milliseconds(10)) == .hold(until: t0 + gap))
        #expect(coalescer.append("three.", at: t0 + .milliseconds(20)) == .hold(until: t0 + gap))
        #expect(coalescer.shown == "It ")
        #expect(coalescer.text == "It is three.")
        #expect(coalescer.publish(at: t0 + gap) == "It is three.")
        #expect(coalescer.pending.isEmpty)
        #expect(coalescer.append(" Sir.", at: t0 + gap + .milliseconds(40)) == .publish)
    }

    @Test("a delta every millisecond for a second: updates stay 1/30 s apart and nothing is lost")
    func neverFasterThanThirtyHertz() {
        var coalescer = DeltaCoalescer()
        let t0 = ContinuousClock.now
        var updates: [ContinuousClock.Instant] = []
        var due: ContinuousClock.Instant?
        for ms in 0..<1000 {
            let now = t0 + .milliseconds(ms)
            if let deadline = due, now >= deadline {   // the held update fires at its deadline
                _ = coalescer.publish(at: deadline)
                updates.append(deadline)
                due = nil
            }
            switch coalescer.append("x", at: now) {
            case .publish:
                _ = coalescer.publish(at: now)
                updates.append(now)
            case .hold(let until):
                due = until
            }
        }
        if let deadline = due {
            _ = coalescer.publish(at: deadline)
            updates.append(deadline)
        }
        #expect(coalescer.shown.count == 1000)
        #expect(updates.count > 1)
        for (earlier, later) in zip(updates, updates.dropFirst()) {
            #expect(later - earlier >= DeltaCoalescer.interval)
        }
    }

    @Test("a zero gap shows every delta at once")
    func zeroGap() {
        var coalescer = DeltaCoalescer(minimumGap: .zero)
        let t0 = ContinuousClock.now
        #expect(coalescer.append("a", at: t0) == .publish)
        _ = coalescer.publish(at: t0)
        #expect(coalescer.append("b", at: t0) == .publish)
    }
}

@Suite("M4 markdown rows (plan 3.12)")
struct ChatMarkdownTests {
    @Test("finished rows parse inline-only markdown and keep whitespace")
    func options() {
        #expect(ChatMarkdown.options.interpretedSyntax == .inlineOnlyPreservingWhitespace)
    }

    @Test("emphasis and code are styled, and line breaks survive")
    func inlineStyling() throws {
        let text = ChatMarkdown.attributed("Two options:\n- **first**\n- `second`")
        #expect(String(text.characters) == "Two options:\n- first\n- second")
        let bold = try #require(text.range(of: "first"))
        #expect(text[bold].inlinePresentationIntent == .stronglyEmphasized)
        let code = try #require(text.range(of: "second"))
        #expect(text[code].inlinePresentationIntent == .code)
    }

    @Test("a link keeps its URL")
    func links() throws {
        let text = ChatMarkdown.attributed("See [the docs](https://example.com/docs).")
        #expect(String(text.characters) == "See the docs.")
        let range = try #require(text.range(of: "the docs"))
        #expect(text[range].link == URL(string: "https://example.com/docs"))
    }
}

@Suite("M4 finished reply text")
struct ReplyTextTests {
    /// What the Claude driver returns for `streamed`: its sentences joined with spaces.
    static func driverReply(_ streamed: String) -> String {
        Py.strip(SentenceSplitter.pop(streamed, force: true).sentences.joined(separator: " "))
    }

    @Test("the streamed text is kept when it has the reply's words, for its line breaks")
    func keepsTheStreamedLayout() {
        let streamed = "Two options, sir:\n1. The first.\n2. The second.\n"
        let reply = Self.driverReply(streamed)
        #expect(reply != Py.strip(streamed))
        #expect(ReplyText.finished(reply: reply, shown: streamed) == Py.strip(streamed))
    }

    @Test("the reply wins when the streamed text says something else")
    func replyWins() {
        #expect(ReplyText.finished(reply: LocalBrain.errorReply, shown: "The time is")
                == LocalBrain.errorReply)
    }

    @Test("an empty reply keeps what was shown; nothing at all means no row")
    func emptyReply() {
        #expect(ReplyText.finished(reply: "", shown: " Done, sir. ") == "Done, sir.")
        #expect(ReplyText.finished(reply: " ", shown: "") == "")
    }
}

@Suite("M4 composer draft and paste flag (X-8)")
struct ComposerDraftTests {
    @Test("typed text is a text-channel input that is not pasted")
    func typed() {
        let draft = ComposerDraft(text: "what time is it")
        #expect(draft.input == UserInput(text: "what time is it", channel: .text, pasted: false))
    }

    @Test("a paste or a drop marks the input pasted")
    func pasted() {
        var draft = ComposerDraft(text: "a note from Sam")
        draft.notePaste()
        #expect(draft.pasted)
        #expect(draft.input == UserInput(text: "a note from Sam", channel: .text, pasted: true))
    }

    @Test("blank text is no input, by Python's strip()", arguments: ["", " ", "\n", "\t\u{0B}\u{0C}\r "])
    func blank(text: String) {
        #expect(ComposerDraft(text: text).input == nil)
    }

    @Test("Return sends; Shift+Return adds a newline")
    func returnKey() {
        #expect(ComposerReturn.action(shift: false) == .send)
        #expect(ComposerReturn.action(shift: true) == .newline)
    }
}
