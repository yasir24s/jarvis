import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// Batch C part 1: the boot log against jarvis.log, and its new exchanges through P6's import.
/// The logs are synthetic and every name is invented.
@Suite("Batch C boot log check", .timeLimit(.minutes(1)))
struct PythonBootLogTests {
    /// The fixture's second Python session again (its tea exchange is a duplicate), one new answered
    /// exchange and two heard lines jarvis.log never had (one unanswered).
    static let boot = """
        ===== JARVIS starting 2026-06-12 20:00:00 =====
        [Heard]   I prefer my tea without sugar these days
        [JARVIS]  As you wish, sir.
        [Heard]   I'm training for an invented marathon this autumn
        [JARVIS]  Then I shall pace myself, sir.
        [Heard]   is anyone there at all

        """

    @Test("the counts: heard lines, the extra ones, duplicates and new exchanges")
    func counts() {
        let check = PythonEraMemory.checkBootLog(boot: Self.boot, log: PythonEraFixture.log, timeZone: PythonImportTests.utc)
        #expect(check.bootHeard == 3)
        #expect(check.extraHeard == 2)
        #expect(check.bootExchanges == 2 && check.duplicates == 1 && check.newExchanges == 1)
        #expect(check.skipped == [.unpaired: 1])
        #expect(check.groups.flatMap(\.entries).map(\.text)
                == ["I'm training for an invented marathon this autumn", "Then I shall pace myself, sir."])
        #expect(check.summary.contains("2 only in the boot log"))
        #expect(!check.summary.contains("marathon"))   // counts only
    }

    @Test("an identical boot log has nothing new")
    func identical() {
        let check = PythonEraMemory.checkBootLog(boot: PythonEraFixture.log, log: PythonEraFixture.log,
                                                 timeZone: PythonImportTests.utc)
        #expect(check.extraHeard == 0 && check.newExchanges == 0 && check.groups.isEmpty)
        #expect(check.duplicates == check.bootExchanges && check.bootExchanges > 0)
    }

    @Test("the import compiles only the new exchange, records it, and a rerun skips it")
    func imports() async throws {
        let rig = try PythonImportTests.Rig()
        defer { rig.sb.remove() }
        try rig.sb.write(PythonEraMemory.bootLogFile, Self.boot)
        let (check, summary) = await rig.importer().importBootLog()
        #expect(check?.newExchanges == 1)
        #expect(summary.batches == 1 && summary.compiled == 1 && summary.failed == 0 && summary.added == 1)
        #expect(rig.facts.map(\.text) == ["The user is training for a marathon in October."])
        #expect(rig.facts.first?.source == "python:2026-06-12")
        #expect(rig.progress?["boot_log_exchanges"] == .int(1))
        #expect(rig.progress?["boot_log"] != nil)
        let again = await rig.importer().importBootLog().summary
        #expect(again.resumed == 1 && again.compiled == 0)
        #expect(rig.onDevice.calls.count == 1)
    }

    @Test("no boot log: nothing to compare, nothing written")
    func missing() async throws {
        let rig = try PythonImportTests.Rig()
        defer { rig.sb.remove() }
        let (check, summary) = await rig.importer().importBootLog()
        #expect(check == nil && summary.batches == 0)
        #expect(rig.progress == nil)
    }
}
