import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_backend_key.golden.json: the research counter the REAL `_set_backend(name)` bumped
/// (tools/golden_brain.py), for the five backend names plus case and Unicode variants.
@Suite("M3 backend counter key golden (jarvis.py _set_backend)")
struct BackendKeyGoldenTests {
    static let suite = "m3_backend_key"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) throws {
        let name = try #require(c.input.string("name"))
        #expect(BackendReporter.counterKey(name) == c.expected.string("key"), "\(c.name)")
    }

    @Test func allCasesAsserted() throws {
        let cases = try Golden.cases(Self.suite)
        let passed = cases.filter { c in
            c.input.string("name").map(BackendReporter.counterKey) == c.expected.string("key")
        }.count
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
        #expect(cases.count >= 5)
    }
}
