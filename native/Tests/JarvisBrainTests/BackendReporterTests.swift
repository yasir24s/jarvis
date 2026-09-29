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

    /// Native must equal the case's `native` block when it has one (DEV-M3-04: the Claude
    /// sentence names Claude Code, not the Agent SDK), and Python's value otherwise. Python's
    /// value for a deviating case stays recorded as a known issue.
    @Test(arguments: try Golden.cases(suite))
    func matchesPythonOrRegisteredDeviation(_ c: GoldenCase) async throws {
        let r = await Self.check(c)
        #expect(r.native.isEmpty, "\(c.name): \(r.native)")
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        }
    }

    @Test func allCasesAsserted() async throws {
        let cases = try Golden.cases(Self.suite)
        var results: [ReportCheck] = []
        for c in cases { results.append(await Self.check(c)) }
        let passed = results.filter { $0.native.isEmpty }.count
        let deviations = results.compactMap(\.divergence)
        print("\(Self.suite): \(passed)/\(cases.count); DEV-M3-04 \(deviations.filter { $0 == "DEV-M3-04" }.count)")
        #expect(passed == cases.count)
        #expect(cases.count >= 60)
        #expect(!deviations.isEmpty && deviations.allSatisfy { $0 == "DEV-M3-04" })
        // A deviating case really differs from Python; every other case is Python's value.
        #expect(results.allSatisfy { ($0.divergence == nil) == $0.python.isEmpty })
        // Python was run with the native display name as MODEL.
        #expect(cases.contains { $0.input.string("local_model") == BackendReporter.localDisplayName })
    }

    struct ReportCheck { var native: [String]; var python: [String]; var divergence: String? }

    static func check(_ c: GoldenCase) async -> ReportCheck {
        guard let model = c.input.string("local_model"), let pythonReport = c.expected.string("report"),
              let wantName = c.expected.string("last_name"), let wantAt = c.expected.double("last_at"),
              let epoch = c.clock.double("epoch") else {
            return ReportCheck(native: ["malformed case"], python: [], divergence: nil)
        }
        let reporter = BackendReporter(research: BumpRecorder(), clock: ManualClock(epoch), log: { _ in })
        if let name = c.input.string("name") {
            await reporter.set(name)
        } else if c.input["name"] != .null {
            return ReportCheck(native: ["malformed name"], python: [], divergence: nil)
        }
        let got = await reporter.report(localModelName: model)
        let last = await reporter.last
        var always: [String] = []
        if !Py.eq(last.name, wantName) { always.append("last.name \(last.name.debugDescription) != \(wantName.debugDescription)") }
        if last.at.timeIntervalSince1970 != wantAt { always.append("last.at \(last.at.timeIntervalSince1970) != \(wantAt)") }
        func mismatch(_ want: String) -> [String] {
            Py.eq(got, want) ? [] : ["report \(got.debugDescription) != \(want.debugDescription)"]
        }
        guard let native = c.expected.object("native") else {
            return ReportCheck(native: always + mismatch(pythonReport), python: [], divergence: nil)
        }
        let divergence = native.string("divergence") ?? "unnamed divergence"
        guard let nativeText = native.string("text") else {
            return ReportCheck(native: always + ["native block without text"], python: mismatch(pythonReport),
                               divergence: divergence)
        }
        return ReportCheck(native: always + mismatch(nativeText), python: mismatch(pythonReport), divergence: divergence)
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
