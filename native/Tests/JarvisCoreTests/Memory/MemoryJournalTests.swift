import Foundation
import JarvisCore
import Testing

// P6b part 5: the task journal's lines (memory/journal.jsonl): the argument summary, the reply's
// start, the redaction before any cut, and the line format. Invented calls only.

private let epoch: Double = 1790582400                         // 2026-09-28 08:00:00 UTC
private let utc = TimeZone(identifier: "UTC")!

private func args(_ pairs: (String, JSONValue)...) -> JSONObject {
    JSONObject(pairs.map { JSONObject.Member(key: $0.0, value: $0.1) })
}

@Suite("P6b task journal lines")
struct MemoryJournalTests {
    /// Each argument as "key: value" in order, anything but a string as JSON, each on one line
    /// and cut to 80 characters, the whole cut to 160; what looks like a secret is masked first.
    @Test func theArgumentsAreSummarisedAndRedacted() {
        #expect(JournalEntry.summary(args(("command", .string("ls -la ~/Invented")), ("timeout", .int(5))))
                == "command: ls -la ~/Invented; timeout: 5")
        #expect(JournalEntry.summary(args(("ids", .array([.string("a"), .string("b")])))) == #"ids: ["a", "b"]"#)
        #expect(JournalEntry.summary(JSONObject()) == "")
        let long = JournalEntry.summary(args(("content", .string("line one\nline two " + String(repeating: "x", count: 200)))))
        #expect(long.hasPrefix("content: line one line two xxx") && long.hasSuffix("..."))
        #expect(long.count == "content: ".count + JournalEntry.valueLimit)
        #expect(JournalEntry.summary(args(("text", .string("the wifi password is hunter2"))))
                == "text: the wifi password is \(Redactor.mask)")
        let many = JournalEntry.summary(JSONObject((0..<10).map {
            JSONObject.Member(key: "k\($0)", value: .string(String(repeating: "v", count: 30)))
        }))
        #expect(many.count == JournalEntry.argsLimit && many.hasSuffix("..."))
    }

    /// The reply's start: redacted, on one line, cut to 200 characters.
    @Test func theReplyIsRedactedAndCut() {
        #expect(JournalEntry.excerpt("Done, sir.") == "Done, sir.")
        let long = JournalEntry.excerpt(String(repeating: "word ", count: 100))
        #expect(long.count == JournalEntry.replyLimit && long.hasSuffix("..."))
        #expect(JournalEntry.excerpt("token: abc123def456ghi789jkl0\nok") == "token: \(Redactor.mask) ok")
    }

    /// A line holds the time, the tool, the outcome, the summary and the reply (null when none was
    /// kept), and reads back; a torn or foreign line does not.
    @Test func aLineRoundTrips() {
        let ran = JournalEntry(timestamp: epoch + 840, timeZone: utc, tool: "run_command", outcome: .ran,
                               args: args(("command", .string("ls"))), reply: "Desktop\nDocuments")
        #expect(ran.line == #"{"timestamp": 1790583240.0, "date": "2026-09-28", "time": "08:14", "tool": "run_command", "#
                + #""outcome": "ran", "args": "command: ls", "reply": "Desktop Documents"}"#)
        #expect(JournalEntry(line: Data(ran.line.utf8)) == ran)
        let read = JournalEntry(timestamp: epoch, timeZone: utc, tool: "read_file", outcome: .ran,
                                args: args(("path", .string("~/notes.txt"))), reply: nil)
        #expect(read.line.hasSuffix(#""args": "path: ~/notes.txt", "reply": null}"#))
        #expect(JournalEntry(line: Data(read.line.utf8)) == read)
        #expect(JournalEntry(line: Data(#"{"timestamp": 1"#.utf8)) == nil)
        #expect(JournalEntry(line: Data((#"{"timestamp": 1.0, "date": "x", "time": "y", "tool": "t", "#
                                         + #""outcome": "exploded", "args": "", "reply": null}"#).utf8)) == nil)
        #expect(JournalEntry.Outcome.allCases.map(\.rawValue) == ["ran", "gated", "blocked", "failed"])
    }
}
