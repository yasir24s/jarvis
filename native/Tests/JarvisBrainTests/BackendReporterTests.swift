import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// m3_backend_report.golden.json: `_backend_report()` from the REAL function with `MODEL`
/// patched per case, on the import-time `LAST_BACKEND` and after the REAL `_set_backend(name)`
/// (tools/golden_brain.py). Each case runs on a fresh reporter: `set` (unless the case is the
/// initial state), then `report` and `last`.
@Suite("M3 backend report golden (jarvis.py _backend_report)")
struct BackendReportGoldenTests {
    static let suite = "m3_backend_report"

    @Test(arguments: try Golden.cases(suite))
    func matchesPython(_ c: GoldenCase) async throws {
        for m in await Self.check(c) { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
    }

    @Test func allCasesAsserted() async throws {
        let cases = try Golden.cases(Self.suite)
        var passed = 0
        for c in cases where await Self.check(c).isEmpty { passed += 1 }
        print("\(Self.suite): \(passed)/\(cases.count)")
        #expect(passed == cases.count)
        #expect(cases.count >= 60)
        // Python was run with the native display name as MODEL.
        #expect(cases.contains { $0.input.string("local_model") == BackendReporter.localDisplayName })
        // Both of Python's strings occur.
        let reports = Set(cases.compactMap { $0.expected.string("report") })
        #expect(reports.contains { $0.contains("Claude") } && reports.contains { $0.contains("local model") })
    }

    static func check(_ c: GoldenCase) async -> [String] {
        guard let model = c.input.string("local_model"), let want = c.expected.string("report"),
              let wantName = c.expected.string("last_name"), let wantAt = c.expected.double("last_at"),
              let epoch = c.clock.double("epoch") else { return ["malformed case"] }
        let reporter = BackendReporter(research: BumpRecorder(), clock: ManualClock(epoch), log: { _ in })
        if let name = c.input.string("name") {
            await reporter.set(name)
        } else if c.input["name"] != .null {
            return ["malformed name"]
        }
        var out: [String] = []
        let got = await reporter.report(localModelName: model)
        if !Py.eq(got, want) { out.append("report \(got.debugDescription) != \(want.debugDescription)") }
        let last = await reporter.last
        if !Py.eq(last.name, wantName) { out.append("last.name \(last.name.debugDescription) != \(wantName.debugDescription)") }
        if last.at.timeIntervalSince1970 != wantAt { out.append("last.at \(last.at.timeIntervalSince1970) != \(wantAt)") }
        return out
    }
}

@Suite("M3 backend reporter (plan 3.10)")
struct BackendReporterTests {
    /// `_set_backend`: the name and time first, then the log line, then the counter.
    @Test func setLogsThenBumps() async {
        let events = EventLog()
        let reporter = BackendReporter(research: EventCounter(events), clock: ManualClock(1234.5),
                                       log: { events.add("log \($0)") })
        await reporter.set("claude (partial)")
        #expect(events.events == ["log Backend: claude (partial)",
                                "bump \(BackendReporter.counterKey("claude (partial)"))+1"])
        let last = await reporter.last
        #expect(last.name == "claude (partial)")
        #expect(last.at == Date(timeIntervalSince1970: 1234.5))
    }

    /// The driver reports through `BackendReporting`; the reporter is that protocol.
    @Test func isTheDriversBackendReporting() async {
        let bumps = BumpRecorder()
        let reporting: any BackendReporting = BackendReporter(research: bumps, log: { _ in })
        await reporting.set(ClaudeDriver.successBackend(model: ClaudeConfig.defaultModel))
        #expect(bumps.bumps == ["\(BackendReporter.counterKey("claude"))+1"])
    }
}
