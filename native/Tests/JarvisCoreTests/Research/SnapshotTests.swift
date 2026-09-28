import Darwin
import Foundation
import Synchronization
import JarvisCore
import JarvisTestSupport
import Testing

/// m1b_snapshot.golden.json (M01b §2.1, §2.2, §3.3, §3.4, §4 `snapshot.json`, §6 T5), in
/// "strip-schema-2 mode": jarvis.py is unpatched, so Python's rows are schema 1. Each case
/// seeds a Sandbox with the files the real research_snapshot read, runs SnapshotBuilder with
/// the same clock, git stdout and history length, then requires:
/// - Python wrote a row: native `.written`, metrics.jsonl = the bytes before + one line +
///   "\n", the line's keys are the 8 schema-1 keys then emotions_at, schema, runtime,
///   code_native, and with those four removed the line is BYTE-IDENTICAL to Python's.
/// - Python wrote nothing: native `.failed`, metrics.jsonl untouched.
/// - git: the same argv and timeout Python passed to subprocess.run, in order.
/// Registered deviation D5 (`native` block): jarvis.py missing / not UTF-8 / a directory.
/// Python raises (no row); native writes the row with code.bytes and code.lines null, and it
/// must equal Python's `reference` case line with those two values null. Python's "no row"
/// is the known issue.
@Suite("M1b snapshot golden (jarvis.py research_snapshot, schema-1 bytes)")
struct SnapshotGoldenTests {
    static let suite = "m1b_snapshot"

    struct Literals {
        let seed: JSONValue
        let baselines: [(name: String, baseline: Double)]
    }

    static func literals(_ cases: [GoldenCase]) throws -> Literals {
        let e = try #require(cases.first { $0.name == "literals" }?.expected)
        let seed = try PyJSON.loads(Data(try #require(e.string("personality_seed_json")).utf8))
        var baselines: [(name: String, baseline: Double)] = []
        for row in e.array("emotion_baselines") ?? [] {
            let a = row.arrayValue ?? []
            let name = try #require(a.first?.stringValue)
            let b = try #require(PersonaGolden.double(a.last))
            baselines.append((name, b))
        }
        return Literals(seed: seed, baselines: baselines)
    }

    /// The runtime block the golden runs inject: its values are not compared with Python.
    static let fixedRuntime = RuntimeInfo(build: .dev, version: "0.0.0-test", sourceCommit: "0000000",
                                          sourceDirty: false, processStarted: 1790500000.5, voice: false,
                                          claudeEnabled: true, localModel: "synthetic-local")
    static let fixedHost = HostSample(os: "0.0", osBuild: "0A0", hwModel: "Test1,1", ramBytes: 1 << 33,
                                      footprint: 1 << 20, peakFootprint: 1 << 21)

    @Test func literalsMatchM1() throws {
        let lit = try Self.literals(try Golden.cases(Self.suite))
        #expect(PyJSON.dumps(lit.seed) == PyJSON.dumps(.object(PersonalityLogic.seed())),
                "_PERSONALITY_SEED differs from PersonalityLogic.seed()")
        #expect(lit.baselines.map(\.name) == EmotionLogic.dims.map(\.name))
        #expect(lit.baselines.map(\.baseline) == EmotionLogic.dims.map(\.baseline))
    }

    @Test(arguments: try Golden.cases(suite).filter { $0.name != "literals" })
    func matchesPython(_ c: GoldenCase) throws {
        let all = try Golden.cases(Self.suite)
        let r = try Self.run(c, all: all)
        for m in r.hard { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        } else {
            for m in r.knownPython { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
        }
    }

    /// M01 §5 A5 style: the number of golden cases asserted, printed per suite.
    @Test func allCasesAsserted() throws {
        let all = try Golden.cases(Self.suite)
        var passed = 1                                      // literals: literalsMatchM1
        var diverged: [String: Int] = [:]
        for c in all where c.name != "literals" {
            let r = try Self.run(c, all: all)
            if let d = r.divergence, !r.knownPython.isEmpty { diverged[d, default: 0] += 1 }
            if r.hard.isEmpty && (r.divergence == nil) == r.knownPython.isEmpty { passed += 1 }
        }
        let summary = diverged.sorted { $0.key < $1.key }.map { "\($0.key) × \($0.value)" }
        print("\(Self.suite): \(passed)/\(all.count)"
              + (summary.isEmpty ? "" : " (known divergences: \(summary.joined(separator: ", ")))"))
        #expect(passed == all.count)
    }

    struct Report {
        var hard: [String] = []
        var knownPython: [String] = []
        var divergence: String?
        var nativeLine: String?
    }

    /// One recorded git call, as research_snapshot passed it to subprocess.run.
    final class GitRecorder: Sendable {
        let plan: [JSONObject]
        let calls = Mutex<[(args: [String], timeout: Double)]>([])
        init(plan: [JSONObject]) { self.plan = plan }

        var runner: GitProbe.Runner {
            { [self] args, timeout in
                let k = calls.withLock { $0.append((args, timeout)); return $0.count - 1 }
                guard k < plan.count else { return nil }
                if plan[k].string("raise") != nil { return nil }
                return plan[k].string("stdout")
            }
        }
    }

    static func run(_ c: GoldenCase, all: [GoldenCase]) throws -> Report {
        let lit = try literals(all)
        guard let files = c.input.object("files"), let plan = c.input.array("git"),
              let ts = PersonaGolden.double(c.input["ts"]), let turns = c.input.int("history_turns"),
              let calls = c.expected.array("git_calls"), let tz = c.clock.string("tz"),
              let zone = TimeZone(identifier: tz) else {
            return Report(hard: ["malformed case"])
        }
        let native = c.expected.object("native")
        var report = Report(divergence: native?.string("divergence"))
        let sb = try Sandbox()
        defer { sb.remove() }
        var root = sb.root.path(percentEncoded: false)
        while root.hasSuffix("/") { root.removeLast() }
        let fm = FileManager.default
        for m in files.members {
            let url = sb.root.appending(path: m.key, directoryHint: .notDirectory)
            try? fm.removeItem(at: url)
            switch m.value {
            case .string("DIR"): try fm.createDirectory(at: url, withIntermediateDirectories: true)
            case .string(let b64):
                guard let data = Data(base64Encoded: b64) else { return Report(hard: ["\(m.key) is not base64"]) }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            default: break                                  // null: absent
            }
        }
        let before = files.string("research/metrics.jsonl").flatMap { Data(base64Encoded: $0) } ?? Data()
        let git = GitRecorder(plan: plan.compactMap(\.objectValue))
        let n = Int(turns)
        let sources = FileSnapshotSources(here: sb.root, personalitySeed: lit.seed, emotionBaselines: lit.baselines,
                                          historyTurns: { n })
        let builder = SnapshotBuilder(paths: ResearchPaths(here: sb.root),
                                      clock: ResearchClock(ManualClock(ts), timeZone: zone),
                                      sources: sources, runtime: { fixedRuntime }, git: git.runner,
                                      host: { fixedHost })
        if !builder.paths.metrics.path(percentEncoded: false).hasPrefix(root + "/") {
            return Report(hard: ["metrics path escapes the sandbox"])
        }
        let outcome = builder.snapshot()
        let after = (try? Data(contentsOf: builder.paths.metrics)) ?? Data()

        // git: same argv (HERE = the sandbox) and timeout, in order.
        let want = calls.map { call -> String in
            let o = call.objectValue
            let args = (o?.array("args") ?? []).compactMap(\.stringValue)
                .map { $0.replacingOccurrences(of: PersonaGolden.homeToken, with: root, options: .literal) }
            return "\(args) timeout=\(o?.object("kwargs")?.double("timeout") ?? -1)"
        }
        let have = git.calls.withLock { $0.map { "\($0.args) timeout=\($0.timeout)" } }
        if have != want { report.hard.append("git calls \(have) != Python \(want)") }

        // Native's appended line (nil when nothing was appended).
        var line: String?
        if after != before {
            guard after.starts(with: before), after.last == 0x0A else {
                report.hard.append("metrics.jsonl was not appended to (native rewrote it)")
                return report
            }
            let tail = after.dropFirst(before.count).dropLast()
            if tail.contains(0x0A) { report.hard.append("native appended more than one line") }
            line = String(decoding: tail, as: UTF8.self)
        }
        report.nativeLine = line
        let pythonLine = c.expected.string("line_b64").flatMap { Data(base64Encoded: $0) }

        if let native, native["native_row"] == .bool(true) {
            // D5: native writes a row; Python's reference line with code.bytes/lines null.
            guard case .written? = Optional(outcome), let line else {
                report.hard.append("D5: native did not write a row (\(outcome))")
                return report
            }
            guard let refName = native.string("reference"),
                  let ref = all.first(where: { $0.name == refName })?.expected.string("line_b64"),
                  let refData = Data(base64Encoded: ref),
                  case .object(var refRow) = try PyJSON.loads(refData),
                  case .object(var code)? = refRow["code"] else {
                report.hard.append("D5: reference case missing")
                return report
            }
            for k in native.array("code_null")?.compactMap(\.stringValue) ?? [] { code[k] = .null }
            refRow["code"] = .object(code)
            report.hard += compareRow(line, PyJSON.dumps(.object(refRow)), ts: ts)
            if pythonLine == nil {
                report.knownPython.append("Python wrote no row (it raised: \(c.expected.array("log") ?? []))")
            } else {
                report.knownPython.append("Python wrote a row")
            }
            return report
        }

        guard let pythonLine else {
            if case .failed = outcome {} else { report.hard.append("Python wrote no row; native \(outcome)") }
            if line != nil { report.hard.append("Python wrote no row; native appended one") }
            return report
        }
        guard case .written(let date) = outcome, let line else {
            report.hard.append("Python wrote a row; native \(outcome)")
            return report
        }
        if date != ResearchClock(ManualClock(ts), timeZone: zone).localDate(ts) {
            report.hard.append("outcome date \(date)")
        }
        report.hard += compareRow(line, String(decoding: pythonLine, as: UTF8.self), ts: ts)
        return report
    }

    /// Key order, then the byte comparison of the schema-1 part.
    static func compareRow(_ nativeLine: String, _ python: String, ts: Double) -> [String] {
        var out: [String] = []
        guard case .object(var row)? = try? PyJSON.loads(Data(nativeLine.utf8)) else {
            return ["native line is not a JSON object: \(nativeLine.prefix(200))"]
        }
        if PyJSON.dumps(.object(row)) != nativeLine { out.append("native line does not round-trip") }
        if row.keys != SnapshotBuilder.schema1Keys + SnapshotBuilder.schema2Keys {
            out.append("key order \(row.keys)")
        }
        if row["schema"] != .int(2) { out.append("schema \(String(describing: row["schema"]))") }
        for k in SnapshotBuilder.schema2Keys { row.removeValue(forKey: k) }
        let stripped = PyJSON.dumps(.object(row))
        if stripped != python {
            let p = Array(python.utf8), n = Array(stripped.utf8)
            let i = (0..<min(p.count, n.count)).first { p[$0] != n[$0] } ?? min(p.count, n.count)
            out.append("schema-1 bytes differ at \(i): native …\(String(decoding: n[max(0, i - 40)..<min(n.count, i + 80)], as: UTF8.self))… Python …\(String(decoding: p[max(0, i - 40)..<min(p.count, i + 80)], as: UTF8.self))…")
        }
        return out
    }
}

// MARK: - Schema-2 blocks (native-specified, M01b §3.3 / §3.6; no Python oracle)

@Suite("M1b snapshot schema-2 blocks (native-specified)")
struct SnapshotSchema2Tests {
    static let london = TimeZone(identifier: "Europe/London")!

    /// A real_shaped-like sandbox row built with the given emotions file.
    static func row(emotions: String?, ts: Double = 1790582400.25,
                    runtime: RuntimeInfo = SnapshotGoldenTests.fixedRuntime,
                    host: HostSample = SnapshotGoldenTests.fixedHost,
                    extra: (Sandbox) throws -> Void = { _ in }) throws -> (row: JSONObject, outcome: SnapshotOutcome) {
        let sb = try Sandbox()
        defer { sb.remove() }
        try sb.write("jarvis.py", "a\nb\n")
        if let emotions { try sb.write("emotions.json", emotions) }
        try extra(sb)
        let builder = SnapshotBuilder(paths: ResearchPaths(here: sb.root),
                                      clock: ResearchClock(ManualClock(ts), timeZone: london),
                                      sources: FileSnapshotSources(here: sb.root, historyTurns: { 0 }),
                                      runtime: { runtime }, git: { _, _ in "" }, host: { host })
        let outcome = builder.snapshot()
        let data = try Data(contentsOf: builder.paths.metrics)
        guard case .object(let o) = try PyJSON.loads(data.dropLast()) else { throw GoldenError.malformed(builder.paths.metrics, "row") }
        return (o, outcome)
    }

    @Test func keyOrderAndSchema() throws {
        let (row, outcome) = try Self.row(emotions: nil)
        #expect(outcome == .written(date: "2026-09-28"))
        #expect(row.keys == ["ts", "date", "code", "personality", "emotions", "counts", "voiceprint_enrolled",
                             "usage_today", "emotions_at", "schema", "runtime", "code_native"])
        #expect(row["schema"] == .int(2))
        #expect(row.object("code")?.keys == ["bytes", "lines", "git_head", "git_commits"])
        #expect(row.object("counts")?.keys == ["profile_facts", "corrections", "kb_topics", "history_turns"])
    }

    /// emotions = the RAW persisted values (no decay, "at" removed); emotions_at = the raw "at".
    @Test func emotionsRawAndEmotionsAt() throws {
        let file = #"{"mood": 0.1234567, "energy": 1, "warmth": 0.7, "patience": 0.8, "at": 1790000000.5}"#
        let (row, _) = try Self.row(emotions: file, ts: 1790582400.25)
        #expect(PyJSON.dumps(row["emotions"] ?? .null) == #"{"mood": 0.123, "energy": 1, "warmth": 0.7, "patience": 0.8}"#)
        #expect(row["emotions_at"] == .double(1790000000.5))
        let noAt = try Self.row(emotions: #"{"mood": 0.5, "energy": 0.5, "warmth": 0.5, "patience": 0.5}"#).row
        #expect(noAt["emotions_at"] == .null)
        let textAt = try Self.row(emotions: #"{"mood": 0.5, "energy": 0.5, "warmth": 0.5, "patience": 0.5, "at": "x"}"#).row
        #expect(textAt["emotions_at"] == .string("x"))
        let seeded = try Self.row(emotions: nil, ts: 1790582400.25).row      // baselines + at = now
        #expect(seeded["emotions_at"] == .double(1790582400.25))
        #expect(PyJSON.dumps(seeded["emotions"] ?? .null) == #"{"mood": 0.6, "energy": 0.6, "warmth": 0.7, "patience": 0.8}"#)
    }

    @Test func runtimeBlockOrderAndTypes() throws {
        let (row, _) = try Self.row(emotions: nil)
        let rt = try #require(row.object("runtime"))
        #expect(rt.keys == ["impl", "build", "version", "source_commit", "source_dirty", "process_started",
                            "os", "os_build", "hw_model", "ram_bytes", "mem_footprint_bytes",
                            "mem_footprint_peak_bytes", "voice", "backends", "utc_offset"])
        #expect(PyJSON.dumps(.object(rt)) == #"{"impl": "swift", "build": "dev", "version": "0.0.0-test", "source_commit": "0000000", "source_dirty": false, "process_started": 1790500000.5, "os": "0.0", "os_build": "0A0", "hw_model": "Test1,1", "ram_bytes": 8589934592, "mem_footprint_bytes": 1048576, "mem_footprint_peak_bytes": 2097152, "voice": false, "backends": {"claude": true, "local": "synthetic-local"}, "utc_offset": "+0100"}"#)
        let bare = RuntimeInfo(infoDictionary: nil, processStarted: 5)
        let empty = HostSample(os: "", osBuild: "", hwModel: "", ramBytes: nil, footprint: nil, peakFootprint: nil)
        #expect(PyJSON.dumps(.object(bare.json(utcOffset: "+0000", host: empty))) == #"{"impl": "swift", "build": "dev", "version": null, "source_commit": "", "source_dirty": null, "process_started": 5.0, "os": "", "os_build": "", "hw_model": "", "ram_bytes": null, "mem_footprint_bytes": null, "mem_footprint_peak_bytes": null, "voice": false, "backends": {"claude": false, "local": null}, "utc_offset": "+0000"}"#)
    }

    @Test func runtimeWithRealHost() throws {
        let (row, _) = try Self.row(emotions: nil, host: .current())
        let rt = try #require(row.object("runtime"))
        guard case .string(let os)? = rt["os"], case .string(let build)? = rt["os_build"],
              case .string(let hw)? = rt["hw_model"], case .int(let ram)? = rt["ram_bytes"],
              case .int(let fp)? = rt["mem_footprint_bytes"], case .int(let peak)? = rt["mem_footprint_peak_bytes"] else {
            Issue.record("runtime types: \(PyJSON.dumps(.object(rt)))")
            return
        }
        #expect(!os.isEmpty && !build.isEmpty && !hw.isEmpty)
        #expect(ram > 0 && fp > 0 && peak >= fp)
    }

    /// dev unless Info.plist JARVISBuildChannel is exactly "release" (§3.3, §3.6).
    @Test func devReleaseRule() {
        func build(_ info: [String: Any]?) -> BuildChannel { RuntimeInfo(infoDictionary: info, processStarted: 0).build }
        #expect(build(nil) == .dev)
        #expect(build([:]) == .dev)
        #expect(build(["JARVISBuildChannel": "release"]) == .release)
        #expect(build(["JARVISBuildChannel": "Release"]) == .dev)
        #expect(build(["JARVISBuildChannel": "dev"]) == .dev)
        #expect(build(["JARVISBuildChannel": true]) == .dev)
        let r = RuntimeInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.0", "JARVISGitCommit": "abc1234",
                                             "JARVISGitDirty": "true"], processStarted: 1)
        #expect(r.version == "0.1.0" && r.sourceCommit == "abc1234" && r.sourceDirty == true)
        #expect(RuntimeInfo(infoDictionary: ["JARVISGitDirty": false], processStarted: 1).sourceDirty == false)
        #expect(RuntimeInfo(infoDictionary: ["JARVISGitDirty": "maybe"], processStarted: 1).sourceDirty == nil)
        #expect(RuntimeInfo(infoDictionary: [:], processStarted: 1).sourceCommit == "")
        // `swift test` does not run from an .app: no Info.plist facts, so dev.
        let cur = RuntimeInfo.current(processStarted: 1)
        #expect(cur.build == .dev && cur.version == nil && cur.sourceDirty == nil && cur.impl == "swift")
    }

    @Test func utcOffsetFollowsTheRowsClock() throws {
        #expect(try Self.row(emotions: nil, ts: 1790582400).row.object("runtime")?["utc_offset"] == .string("+0100"))
        #expect(try Self.row(emotions: nil, ts: 1796083200).row.object("runtime")?["utc_offset"] == .string("+0000"))
    }

    @Test func codeNativeCountsSwiftSources() throws {
        let (row, _) = try Self.row(emotions: nil) { sb in
            try sb.write("native/Sources/A/One.swift", "let a = 1\nlet b = 2\n")
            try sb.write("native/Sources/B/Two.swift", "x\r\ny")
            try sb.write("native/Sources/B/notes.txt", "ignored\n")
        }
        #expect(PyJSON.dumps(row["code_native"] ?? .null) == #"{"bytes": 24, "lines": 4, "files": 2}"#)
        let none = try Self.row(emotions: nil).row
        #expect(PyJSON.dumps(none["code_native"] ?? .null) == #"{"bytes": 0, "lines": 0, "files": 0}"#)
    }

    /// D5, positively: no jarvis.py → the row is still written, code.bytes/lines null.
    @Test func d5MissingJarvisPyStillWritesRow() throws {
        let (row, outcome) = try Self.row(emotions: nil) { sb in
            try FileManager.default.removeItem(at: sb.root.appending(path: "jarvis.py"))
        }
        #expect(outcome == .written(date: "2026-09-28"))
        #expect(PyJSON.dumps(row["code"] ?? .null) == #"{"bytes": null, "lines": null, "git_head": "", "git_commits": ""}"#)
    }

    /// A failure case writes nothing and says so.
    @Test func failureWritesNoRow() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        try sb.write("profile.json", "[1, 2]")
        let builder = SnapshotBuilder(paths: ResearchPaths(here: sb.root),
                                      clock: ResearchClock(ManualClock(1790582400), timeZone: Self.london),
                                      sources: FileSnapshotSources(here: sb.root, historyTurns: { 0 }),
                                      runtime: { SnapshotGoldenTests.fixedRuntime }, git: { _, _ in "" },
                                      host: { SnapshotGoldenTests.fixedHost })
        guard case .failed = builder.snapshot() else { Issue.record("expected .failed"); return }
        #expect(!FileManager.default.fileExists(atPath: builder.paths.metrics.path(percentEncoded: false)))
    }
}

// MARK: - A6

@Suite("M1b MemoryFootprintTests (A6)")
struct MemoryFootprintTests {
    /// task_info(TASK_VM_INFO).phys_footprint, the reference A6 compares against.
    static func taskVMFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }

    @Test func footprintMatchesTaskInfo() throws {
        let m = try #require(MemoryFootprint.current())
        let ref = try #require(Self.taskVMFootprint())
        #expect(m.footprint > 0)
        #expect(m.peak >= m.footprint)
        let diff = Double(m.footprint > ref ? m.footprint - ref : ref - m.footprint)
        #expect(diff <= 0.10 * Double(ref), "proc_pid_rusage \(m.footprint) vs task_info \(ref)")
        print("A6 footprint=\(m.footprint) peak=\(m.peak) task_info=\(ref)")
    }
}
