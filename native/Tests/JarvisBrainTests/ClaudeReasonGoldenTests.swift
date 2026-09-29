import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_claude_reason.golden.json: `_claude_reason(Exception(message))` from the REAL function
/// (tools/golden_brain.py), for every keyword, group collisions, empty and long unknown text.
@Suite("M3 Claude failure reason golden (jarvis.py _claude_reason)")
struct ClaudeReasonGoldenTests {
    static let suite = "m3_claude_reason"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        let message = try #require(c.input.string("message"))
        let got = ClaudeReason.reason(message)
        #expect(JSONValue.string(got) == c.expected["reason"], "\(c.name): \(got.debugDescription)")
    }

    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        let passed = cases.filter { c in
            c.input.string("message").map { JSONValue.string(ClaudeReason.reason($0)) } == c.expected["reason"]
        }.count
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
    }
}
