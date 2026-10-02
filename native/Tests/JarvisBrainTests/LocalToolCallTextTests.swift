import Foundation
@testable import JarvisBrain
import JarvisTools
import Testing

/// A tool call the on-device model writes into its reply as text ("run_command: read_file ...",
/// a JSON object that names a tool) is taken out of what is shown, spoken and kept. A normal
/// reply is not touched. The filter, however the text arrives; LocalBrainTests has it end to end.
@Suite("M3 local model: tool-call text in a reply")
struct LocalToolCallTextTests {
    /// The reply through a fresh filter in pieces of `size` scalars (nil: all at once).
    static func filtered(_ reply: String, size: Int? = nil) -> (text: String, filter: ToolCallTextFilter) {
        var filter = ToolCallTextFilter()
        var text = ""
        let scalars = Array(reply.unicodeScalars)
        let step = size ?? max(scalars.count, 1)
        var start = 0
        while start < scalars.count {
            let end = min(start + step, scalars.count)
            text += filter.push(String(String.UnicodeScalarView(scalars[start..<end])))
            start = end
        }
        text += filter.finish()
        return (text, filter)
    }

    @Test("a line that starts with run_command and a colon is removed, and the rest of the reply stays")
    func runCommandLine() {
        let reply = "Let me check.\nrun_command: read_file notes.txt\nDone, sir."
        let (text, filter) = Self.filtered(reply)
        #expect(text == "Let me check.\nDone, sir.")
        #expect(filter.lines == 1)
        #expect(filter.objects == 0)
        #expect(filter.characters == "run_command: read_file notes.txt\n".unicodeScalars.count)
        #expect(filter.removed)
    }

    @Test("so is a line that starts with any other known tool name and a colon")
    func otherToolNames() {
        #expect(ToolCallTextFilter.knownToolNames.count == 50)
        for name in ToolCallTextFilter.knownToolNames.sorted() {
            let (text, filter) = Self.filtered("\(name): old sport origin\nIt is from Gatsby, sir.")
            #expect(text == "It is from Gatsby, sir.", "\(name)")
            #expect(filter.lines == 1, "\(name)")
        }
        let (text, _) = Self.filtered("web_search: old sport origin")
        #expect(text.isEmpty)
    }

    @Test("indentation, a space before the colon and a CRLF line end do not hide one")
    func lineShapes() {
        #expect(Self.filtered("  run_command : ls -l\nDone.").text == "Done.")
        #expect(Self.filtered("\tget_time:\nDone.").text == "Done.")
        #expect(Self.filtered("run_command: ls\r\nDone.").text == "Done.")
        // Two in a row, and one in the middle of a reply.
        #expect(Self.filtered("a.\nrun_command: x\nget_time: y\nb.").text == "a.\nb.")
    }

    @Test("a JSON object that names a known tool is removed, whatever its shape")
    func jsonObjects() {
        let call = #"{"name": "run_command", "arguments": {"command": "ls"}}"#
        let (text, filter) = Self.filtered(call)
        #expect(text.isEmpty)
        #expect(filter.objects == 1)
        #expect(filter.lines == 0)
        #expect(filter.characters == call.unicodeScalars.count)
        // Mid-line, with text each side.
        #expect(Self.filtered(#"Sure. {"tool": "web_search", "query": "x"} Done."#).text == "Sure.  Done.")
        // A tool name as the value in a list of calls, and as a key.
        #expect(Self.filtered(#"{"tool_calls": [{"function": {"name": "get_battery", "arguments": "{}"}}]}"#)
            .text.isEmpty)
        #expect(Self.filtered(#"{"get_time": {}}"#).text.isEmpty)
        // Spread over lines, with a brace and an escaped quote inside a string.
        let pretty = "{\n  \"name\": \"web_search\",\n  \"arguments\": {\"query\": \"a } b { c \\\" }\"}\n}\nOkay."
        #expect(Self.filtered(pretty).text == "\nOkay.")
        #expect(Self.filtered(pretty).filter.objects == 1)
    }

    @Test("a JSON object cut off at the end of the reply is removed if it already names a tool")
    func truncatedObject() {
        let (text, filter) = Self.filtered(#"{"name": "web_search", "argu"#)
        #expect(text.isEmpty)
        #expect(filter.objects == 1)
        // One that names none is shown, since nothing says it was a call.
        let kept = #"Here is {"foo": "ba"#
        #expect(Self.filtered(kept).text == kept)
        #expect(!Self.filtered(kept).filter.removed)
    }

    @Test("a normal reply is left untouched, including text that only looks like a call")
    func normalRepliesUntouched() {
        let replies = [
            "It is noon, sir. Anything else?",
            "  Indented, sir.\n\nTwo paragraphs.",
            "set the table, sir, and I will bring the tea.",
            "notify me when it is done? Certainly, sir.",
            "get_time is a tool I have, sir.",
            "I would use run_command: but that is not needed.",
            "Checking. run_command: ls\nDone.",
            "Note: the meeting is at three.",
            "search results: three",
            "web_searching: nothing",
            "run_command",
            #"{"a": 1} is JSON, sir."#,
            "Use {braces} sparingly, sir.",
            "}{ odd braces",
            "Run_command: capital letters are not a tool name.",
            "",
        ]
        for reply in replies {
            for size in [nil, 1, 2, 3, 7] {
                let (text, filter) = Self.filtered(reply, size: size)
                #expect(text == reply, "\(reply) in pieces of \(String(describing: size))")
                #expect(!filter.removed, "\(reply)")
                #expect(filter.characters == 0, "\(reply)")
            }
        }
    }

    @Test("the pieces the text arrives in change nothing")
    func pieces() {
        let reply = "Checking.\nrun_command: read_file x\nSure. {\"name\": \"get_time\"} Done, sir.\nset it, sir."
        let whole = Self.filtered(reply)
        #expect(whole.text == "Checking.\nSure.  Done, sir.\nset it, sir.")
        for size in [1, 2, 3, 4, 5, 7, 11, 13] {
            let cut = Self.filtered(reply, size: size)
            #expect(cut.text == whole.text, "pieces of \(size)")
            #expect(cut.filter.lines == 1 && cut.filter.objects == 1, "pieces of \(size)")
            #expect(cut.filter.characters == whole.filter.characters, "pieces of \(size)")
        }
    }

    @Test("text that might still become a call is held, then handed back at the end if it did not")
    func held() {
        var filter = ToolCallTextFilter()
        #expect(filter.push("get_ti") == "")
        #expect(filter.finish() == "get_ti")
        var named = ToolCallTextFilter()
        #expect(named.push("Fine.\nrun_command") == "Fine.\n")
        #expect(named.finish() == "run_command")
        var other = ToolCallTextFilter()
        #expect(other.push("Fine.\nrun_comma") == "Fine.\n")
        #expect(other.push("x is not one") == "run_commax is not one")
        #expect(other.finish().isEmpty)
        #expect(!other.removed)
    }
}
