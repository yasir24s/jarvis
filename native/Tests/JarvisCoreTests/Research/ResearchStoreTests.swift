import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// Unit tests for the native deviations D1–D4 (plan: M01b §3.4) beyond what the m1b_bump /
// m1b_last_date fixtures pin, and for UsageStore's ResearchCounting contract. Sandbox only.

private func london() -> TimeZone { TimeZone(identifier: "Europe/London")! }

private func contents(_ url: URL) -> Data? {
    FileManager.default.contents(atPath: url.path(percentEncoded: false))
}

private func names(_ dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? []).sorted()
}

@Suite("UsageStore: D1 quarantine, D3 atomic write, ResearchCounting")
struct UsageStoreTests {
    let ts = 1786527000.75                               // 2026-08-12 10:30:00.75 BST

    private func store(_ sb: ResearchSandbox, _ clock: ManualClock) -> UsageStore {
        UsageStore(paths: sb.paths, clock: ResearchClock(clock, timeZone: london()))
    }

    @Test func d1QuarantineIsNeverOverwritten() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let s = store(sb, ManualClock(ts))
        let taken = sb.paths.usageQuarantine(unix: 1786527000)
        try Data("an older quarantine".utf8).write(to: taken)
        try Data("{\"2026-08-11\": {\"x\": 1".utf8).write(to: sb.paths.usage)

        s.bump("interactions", by: 1)
        #expect(contents(taken) == Data("an older quarantine".utf8), "existing quarantine untouched")
        let second = sb.paths.dir.appending(path: "usage.json.corrupt-1786527000-1", directoryHint: .notDirectory)
        #expect(contents(second) == Data("{\"2026-08-11\": {\"x\": 1".utf8))
        #expect(contents(sb.paths.usage) == Data("{\n \"2026-08-12\": {\n  \"interactions\": 1\n }\n}".utf8))

        // The same unparseable bytes again in the same second: kept once, not twice.
        try Data("{\"2026-08-11\": {\"x\": 1".utf8).write(to: sb.paths.usage)
        s.bump("interactions", by: 1)
        #expect(names(sb.paths.dir) == ["usage.json", "usage.json.corrupt-1786527000",
                                        "usage.json.corrupt-1786527000-1"])
    }

    @Test func d1EmptyFileIsNotQuarantined() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        try Data().write(to: sb.paths.usage)
        store(sb, ManualClock(ts)).bump("interactions", by: 1)
        #expect(names(sb.paths.dir) == ["usage.json"])
    }

    @Test func d1QuarantineFailureWritesNothing() throws {
        let sb = try ResearchSandbox()
        defer {
            chmod(sb.paths.dir.path(percentEncoded: false), 0o755)
            sb.remove()
        }
        let corrupt = Data("{\"2026-08-11\": {\"x\": 1".utf8)
        try corrupt.write(to: sb.paths.usage)
        chmod(sb.paths.dir.path(percentEncoded: false), 0o555)   // no new files in research/
        let s = store(sb, ManualClock(ts))
        #expect(throws: UsageError.self) {
            try s.bump("interactions", by: 1, day: "2026-08-12", now: ts)
        }
        #expect(contents(sb.paths.usage) == corrupt, "history is not replaced when it cannot be kept")
    }

    @Test func d1UnreadableFileIsNeverReplaced() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let original = Data("{\n \"2026-08-11\": {\n  \"x\": 1\n }\n}".utf8)
        try original.write(to: sb.paths.usage)
        chmod(sb.paths.usage.path(percentEncoded: false), 0o200)  // writable, not readable
        let s = store(sb, ManualClock(ts))
        #expect(throws: UsageError.unreadable("read failed")) {
            try s.bump("interactions", by: 1, day: "2026-08-12", now: ts)
        }
        chmod(sb.paths.usage.path(percentEncoded: false), 0o644)
        #expect(contents(sb.paths.usage) == original)
        #expect(names(sb.paths.dir) == ["usage.json"])
    }

    @Test func d3WritesByRenameWithPythonModes() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let path = sb.paths.usage.path(percentEncoded: false)
        let s = store(sb, ManualClock(ts))
        s.bump("interactions", by: 1)
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o7777 == 0o644, "a new file is 0644")
        let firstInode = st.st_ino

        chmod(path, 0o600)
        s.bump("interactions", by: 1)
        #expect(stat(path, &st) == 0)
        #expect(st.st_ino != firstInode, "replaced by rename(2), not rewritten in place")
        #expect(st.st_mode & 0o7777 == 0o600, "an existing file keeps its mode")
        #expect(names(sb.paths.dir) == ["usage.json"], "no temp file left behind")
        #expect(contents(sb.paths.usage) == Data("{\n \"2026-08-12\": {\n  \"interactions\": 2\n }\n}".utf8))
    }

    @Test func typedErrorsMirrorPythonsExceptions() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let s = store(sb, ManualClock(ts))
        try Data("[]".utf8).write(to: sb.paths.usage)
        #expect(throws: UsageError.rootNotObject) { try s.bump("a", by: 1, day: "d", now: ts) }
        try Data("{\"d\": 3}".utf8).write(to: sb.paths.usage)
        #expect(throws: UsageError.dayNotObject("d")) { try s.bump("a", by: 1, day: "d", now: ts) }
        try Data("{\"d\": {\"a\": \"1\"}}".utf8).write(to: sb.paths.usage)
        #expect(throws: UsageError.counterNotNumeric("a")) { try s.bump("a", by: 1, day: "d", now: ts) }
        #expect(contents(sb.paths.usage) == Data("{\"d\": {\"a\": \"1\"}}".utf8))
    }

    @Test func dayReturnsWhateverTheDayHolds() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let s = store(sb, ManualClock(ts))
        #expect(s.day("2026-08-12") == .object(JSONObject()))            // missing file
        try Data("{\"a\": [1], \"b\": {\"x\": 2}}".utf8).write(to: sb.paths.usage)
        #expect(s.day("a") == .array([.int(1)]))
        #expect(PyJSON.dumps(s.day("b")) == "{\"x\": 2}")
        #expect(s.day("c") == .object(JSONObject()))
        try Data("[1]".utf8).write(to: sb.paths.usage)
        #expect(s.day("a") == .object(JSONObject()))                     // AttributeError → {}
    }

    @Test func researchCountingIsOrderedAndExactUnderConcurrency() async throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let counter: any ResearchCounting = store(sb, ManualClock(ts))
        counter.bump("second_key_first", by: 1)
        counter.bump("alpha", by: 1)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for _ in 0..<50 { counter.bump(t % 2 == 0 ? "alpha" : "second_key_first", by: 1) }
                }
            }
        }
        let text = String(decoding: try #require(contents(sb.paths.usage)), as: UTF8.self)
        #expect(text == "{\n \"2026-08-12\": {\n  \"second_key_first\": 201,\n  \"alpha\": 201\n }\n}")
    }
}

@Suite("MetricsLog: D2 full last line, D4 newline repair")
struct MetricsLogTests {
    private func row(_ date: String, pad: Int) -> String {
        "{\"ts\": 1786527000.5, \"date\": \"\(date)\", \"pad\": \"\(String(repeating: "p", count: pad))\"}"
    }

    @Test(arguments: [0, 100, 8100, 8150, 8192, 8193, 16_384, 100_000])
    func d2ReadsTheCompleteLastLine(_ pad: Int) throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let text = row("2026-08-01", pad: 20_000) + "\n" + row("2026-08-02", pad: pad) + "\r\n\n  \n"
        try Data(text.utf8).write(to: sb.paths.metrics)
        #expect(MetricsLog(paths: sb.paths).lastDate() == "2026-08-02")
    }

    @Test func d2OnlyTheLastLineCounts() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let log = MetricsLog(paths: sb.paths)
        try Data((row("2026-08-01", pad: 9000) + "\n" + String(repeating: "x", count: 9000)).utf8)
            .write(to: sb.paths.metrics)
        #expect(log.lastDate() == "", "a malformed last line never falls back to an earlier row")
        try Data((row("2026-08-01", pad: 10) + "\u{2028}" + row("2026-08-03", pad: 9000)).utf8)
            .write(to: sb.paths.metrics)
        #expect(log.lastDate() == "2026-08-03", "U+2028 is a splitlines() boundary")
        try Data("{\"date\": 5}\n".utf8).write(to: sb.paths.metrics)
        #expect(log.lastDate() == "")
    }

    @Test func d4AppendRepairsOnlyAMissingNewline() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let log = MetricsLog(paths: sb.paths)
        try FileManager.default.removeItem(at: sb.paths.dir)            // makedirs, like Python
        try log.append("{\"date\": \"2026-08-01\"}")
        #expect(contents(sb.paths.metrics) == Data("{\"date\": \"2026-08-01\"}\n".utf8))
        try log.append("{\"date\": \"2026-08-02\"}")
        #expect(contents(sb.paths.metrics) == Data("{\"date\": \"2026-08-01\"}\n{\"date\": \"2026-08-02\"}\n".utf8))

        try Data("{\"date\": \"2026-08-01\"}\n{\"da".utf8).write(to: sb.paths.metrics)
        try log.append("{\"date\": \"2026-08-03\"}")
        #expect(contents(sb.paths.metrics)
                == Data("{\"date\": \"2026-08-01\"}\n{\"da\n{\"date\": \"2026-08-03\"}\n".utf8))
        #expect(log.lastDate() == "2026-08-03")
    }
}
