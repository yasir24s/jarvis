import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// M5 gate 1: X-1 (chained/substituted commands) and X-4 (Keychain secret reads). The gateway's
/// run_command pre-guard uses `ShellPolicy.strictVerdict`, which is at least as strict as Python
/// on every input and stricter on the segmentation gaps `_shell_risk` cannot see. The golden
/// `m5_shell_chain` fixture records Python's verdict (from `_shell_risk`) and the hand-specified
/// native strict tier; where they differ the case is tagged X-1 or X-4.
@Suite("M5 gate: X-1 and X-4 strict shell verdicts")
struct M5GateTests {
    @Test(arguments: try Golden.cases("m5_shell_chain"))
    func strictVerdictMatchesNativeAndPythonParity(_ c: GoldenCase) throws {
        let cmd = c.input.string("cmd")
        let python = try #require(c.expected.string("python"))
        let native = try #require(c.expected.string("native"))
        let strict = ShellPolicy.strictVerdict(cmd ?? "").tier.rawValue

        // The Python-exact classifier stays exact (m2_shell golden-tests it; re-assert here).
        #expect(PyShellRisk.classify(cmd).rawValue == python, "\(c.name): \(cmd ?? "nil")")
        // The gateway uses the strict verdict; it must equal the fixture's native tier.
        #expect(strict == native, "\(c.name): \(cmd ?? "nil")")

        if c.expected.string("deviation") != nil {
            // Deviation convention: assert the native verdict, keep Python's in withKnownIssue.
            withKnownIssue("\(c.name): native strict verdict is stricter than Python (\(python))") {
                #expect(strict == python)
            }
        } else {
            #expect(strict == python, "\(c.name): \(cmd ?? "nil")")
        }
    }

    /// Monotonicity (plan §2.3 A-2): strict is never weaker than the Python classifier.
    @Test(arguments: try Golden.cases("m5_shell_chain"))
    func strictIsNeverWeakerThanPython(_ c: GoldenCase) throws {
        let cmd = c.input.string("cmd")
        #expect(ShellPolicy.strictVerdict(cmd ?? "").tier >= PyShellRisk.classify(cmd),
                "\(c.name): \(cmd ?? "nil")")
    }
}
