import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_history_preamble.golden.json: `_claude_history_preamble()` from the REAL function with
/// `_history` set per case (tools/golden_brain.py): 0 to 13 turns, both roles, empty, null and
/// missing contents. The log is built the way the app builds it: `HistoryLog.load` for up to 12
/// turns, and a 13th only by `appendAssistant` (the one untrimmed append).
@Suite("M3 Claude history preamble golden (jarvis.py _claude_history_preamble)")
struct HistoryPreambleGoldenTests {
    static let suite = "m3_history_preamble"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        for m in Self.check(c) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
    }

    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        let passed = cases.filter { Self.check($0).isEmpty }.count
        let lengths = Set(cases.compactMap { $0.input.array("history")?.count })
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
        #expect(lengths == Set(0...13))
    }

    static func check(_ c: GoldenCase) -> [String] {
        guard let turns = c.input.array("history") else { return ["malformed case"] }
        var log = HistoryLog.load(.array(Array(turns.prefix(HistoryLog.cap))))
        if turns.count == HistoryLog.cap + 1 {
            guard let content = turns.last?.objectValue?["content"]?.stringValue else {
                return ["13th turn is not an assistant string"]
            }
            log.appendAssistant(content)
        }
        guard log.turns.map(JSONValue.object) == turns else { return ["HistoryLog does not hold the case's turns"] }
        do {
            let got = try HistoryPreamble.text(for: log)
            return JSONValue.string(got) == c.expected["preamble"] ? [] : ["preamble \(got.debugDescription)"]
        } catch {
            return ["threw \(error)"]
        }
    }
}
