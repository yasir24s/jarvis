import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_pop_sentences.golden.json (tools/golden_brain.py). "pure/..." cases are one
/// `pop_sentences(buf, force)` call. "chunked/..." cases are the chunk lists the REAL
/// `_claude_stream` loop was fed: per non-empty chunk `buf += chunk; pop(buf)`, then one
/// `pop(buf, force=True)`; the loop skips empty chunks (`if block.text`). "constants" holds
/// `_SENT_BOUNDARY.pattern` and `_SENT_MAX_CHARS`. Strings compare code point by code point.
@Suite("M3 sentence splitter golden (jarvis.py pop_sentences)")
struct SentenceSplitterGoldenTests {
    static let suite = "m3_pop_sentences"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        for m in Self.check(c) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
    }

    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        let passed = cases.filter { Self.check($0).isEmpty }.count
        let pure = cases.filter { $0.name.hasPrefix("pure/") }.count
        let chunked = cases.filter { $0.name.hasPrefix("chunked/") }.count
        print("\(Self.suite): \(passed)/\(cases.count) (pure \(pure), chunked \(chunked))")
        #expect(passed == cases.count)
        #expect(pure >= 300)
        #expect(chunked > 0)
    }

    static func check(_ c: GoldenCase) -> [String] {
        if c.name == "constants" {
            var out: [String] = []
            if c.expected.string("boundary") != SentenceSplitter.boundaryPattern { out.append("boundary pattern") }
            if c.expected.int("max_chars") != Int64(SentenceSplitter.maxChars) { out.append("max chars") }
            return out
        }
        if let buf = c.input.string("buf"), case .bool(let force)? = c.input["force"] {
            let (sentences, rest) = SentenceSplitter.pop(buf, force: force)
            var out: [String] = []
            if json(sentences) != c.expected["sentences"] { out.append("sentences \(sentences.debugDescription)") }
            if .string(rest) != c.expected["rest"] { out.append("rest \(rest.debugDescription)") }
            return out
        }
        guard let chunks = c.input.array("chunks")?.compactMap(\.stringValue) else { return ["malformed case"] }
        let (steps, final, text) = feed(chunks)
        var out: [String] = []
        if JSONValue.array(steps.map(json)) != c.expected["steps"] { out.append("steps \(steps.debugDescription)") }
        if json(final) != c.expected["final"] { out.append("final \(final.debugDescription)") }
        if .string(text) != c.expected["text"] { out.append("text \(text.debugDescription)") }
        return out
    }

    /// `_claude_stream`'s feed: sentences spoken after each chunk, the force flush, and the
    /// return value `" ".join(spoken).strip()`.
    static func feed(_ chunks: [String]) -> (steps: [[String]], final: [String], text: String) {
        var buf = "", steps: [[String]] = [], spoken: [String] = []
        for chunk in chunks {
            var got: [String] = []
            if !chunk.isEmpty {
                buf += chunk
                (got, buf) = SentenceSplitter.pop(buf, force: false)
            }
            steps.append(got)
            spoken += got
        }
        let final = SentenceSplitter.pop(buf, force: true).sentences
        spoken += final
        return (steps, final, Py.strip(spoken.joined(separator: " ")))
    }

    static func json(_ a: [String]) -> JSONValue {
        .array(a.map { .string($0) })
    }
}
