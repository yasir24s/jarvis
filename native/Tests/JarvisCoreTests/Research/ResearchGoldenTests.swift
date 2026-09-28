import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// Golden fixtures written by native/tools/golden_research.py from the REAL, unpatched
// jarvis.py (plan: M01b §4). Every file a test writes lives in a Sandbox; `ResearchSandbox`
// asserts no URL resolves under the real repo's research/ directory.

enum ResearchFixture {
    static func data(_ o: JSONObject, _ key: String) -> Data? {
        guard let s = o.string(key) else { return nil }
        return Data(base64Encoded: s)
    }

    /// The fixture's `${JARVIS_HOME}` token (the Python sandbox) → a native path.
    static func detokenize(_ s: String, home: String) -> String {
        s.replacingOccurrences(of: "${JARVIS_HOME}", with: home)
    }

    /// Scalars of the inclusive [lo, hi] ranges, minus `drop` — the m1b_keys corpus.
    static func corpus(_ ranges: [JSONValue], drop: String = "") -> String {
        let dropped = Set(drop.unicodeScalars.map(\.value))
        var out = String.UnicodeScalarView()
        for r in ranges {
            guard let pair = r.arrayValue, pair.count == 2,
                  case .int(let lo) = pair[0], case .int(let hi) = pair[1] else { continue }
            for v in UInt32(lo)...UInt32(hi) where !dropped.contains(v) {
                if let u = Unicode.Scalar(v) { out.append(u) }
            }
        }
        return String(out)
    }

    /// First scalar index where two strings differ (for readable corpus failures).
    static func firstDifference(_ a: String, _ b: String) -> String {
        let x = Array(a.unicodeScalars), y = Array(b.unicodeScalars)
        for i in 0..<min(x.count, y.count) where x[i] != y[i] {
            let lo = max(0, i - 3)
            let ctx = { (s: [Unicode.Scalar]) in
                s[lo..<min(s.count, i + 4)].map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            }
            return "scalar \(i): native [\(ctx(x))] python [\(ctx(y))]"
        }
        return "lengths \(x.count) vs \(y.count)"
    }
}

/// A Sandbox whose every URL is checked against the real dataset directory.
struct ResearchSandbox {
    let box: Sandbox
    let paths: ResearchPaths

    init() throws {
        box = try Sandbox()
        paths = ResearchPaths(box.paths)
        for url in [paths.dir, paths.usage, paths.metrics, paths.jarvisPy] {
            try Self.assertNotReal(url)
        }
    }

    static func assertNotReal(_ url: URL) throws {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "jarvis/research", directoryHint: .isDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let mine = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        try #require(!mine.hasPrefix(real), "test path resolves into the real dataset: \(mine)")
    }

    func remove() { box.remove() }
}

// MARK: - m1b_keys

@Suite("Research golden: counter keys (m1b_keys)")
struct ResearchKeysGoldenTests {
    @Test(arguments: try Golden.cases("m1b_keys"))
    func matchesPython(_ c: GoldenCase) throws {
        let kind = try #require(c.input.string("kind"))
        switch kind {
        case "backend":
            let label = try #require(c.input.string("in"))
            let out = try #require(c.expected.string("out"))
            let got = ResearchKey.backend(label)
            let same = PyStrEqual(got, out)
            #expect(same, "\(ResearchFixture.firstDifference(got, out))")
        case "tone":
            let desc = try #require(c.input.string("in"))
            let native = ResearchKey.tone(desc)
            if let out = c.expected.string("out") {
                let got = try #require(native, "tone(\(desc.debugDescription)) is nil")
                let same = PyStrEqual(got, out)
                #expect(same, "\(ResearchFixture.firstDifference(got, out))")
            } else {
                #expect(native == nil)
            }
        case "emotion":
            let name = try #require(c.input.string("in"))
            if let out = c.expected.string("out") {
                #expect(ResearchKey.emotion(name) == out)
                // task_ok is in _EMO_DELTAS (Python counts it) but never emitted by a call site.
                #expect(ResearchKey.emittedEmotionEvents.contains(name) == (name != "task_ok"))
            } else {
                #expect(c.input["in_emo_deltas"] == .bool(false))
                #expect(!ResearchKey.emittedEmotionEvents.contains(name))
            }
        case "backend_corpus":
            let s = ResearchFixture.corpus(try #require(c.input.array("ranges")))
            let out = try #require(c.expected.string("out"))
            let got = ResearchKey.backend(s)
            let same = PyStrEqual(got, out)
            #expect(same, "\(ResearchFixture.firstDifference(got, out))")
        case "tone_corpus":
            let s = ResearchFixture.corpus(try #require(c.input.array("ranges")),
                                           drop: c.input.string("drop") ?? "")
            let out = try #require(c.expected.string("out"))
            let got = try #require(ResearchKey.tone(s))
            let same = PyStrEqual(got, out)
            #expect(same, "\(ResearchFixture.firstDifference(got, out))")
        default:
            Issue.record("unknown kind \(kind)")
        }
    }
}

/// Code point equality (Swift `==` on String is canonical equivalence; Python's is not).
func PyStrEqual(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.elementsEqual(b.unicodeScalars)
}

// MARK: - m1b_line_count

@Suite("Research golden: line counts (m1b_line_count)")
struct ResearchLineCountGoldenTests {
    @Test(arguments: try Golden.cases("m1b_line_count").filter { $0.name != "code_native_tree" })
    func blobMatchesPython(_ c: GoldenCase) throws {
        let blob = try #require(ResearchFixture.data(c.input, "b64"))
        let native = PyLineCount.lines(blob)
        // lines(_:) is the errors="replace" count; research_snapshot's strict count equals it
        // whenever the bytes are valid UTF-8 (else Python raises and writes no row).
        #expect(Int64(native) == c.expected.int("lines_replace"))
        if let strict = c.expected.int("lines") {
            #expect(Int64(native) == strict)
            #expect(c.expected.int("lines_expr") == strict)
            #expect(c.expected.int("bytes") == Int64(blob.count))
        } else {
            #expect(c.expected["snapshot_row"] == .bool(false))
            #expect(String(validating: blob, as: UTF8.self) == nil,
                    "Python's strict read failed only on invalid UTF-8")
        }
    }

    /// Schema 2 code_native (native-specified: the expectation is the plan's reference
    /// `_research_code_native`, run by the generator; it is not in jarvis.py).
    @Test func codeNativeTreeMatchesReference() throws {
        let c = try #require(try Golden.cases("m1b_line_count").first { $0.name == "code_native_tree" })
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let root = sb.box.root.appending(path: "native/Sources", directoryHint: .isDirectory)
        let fm = FileManager.default
        for m in try #require(c.input.object("files")).members {
            let url = root.appending(path: m.key, directoryHint: .notDirectory)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let b64 = try #require(m.value.stringValue)
            try #require(Data(base64Encoded: b64)).write(to: url)
        }
        for m in try #require(c.input.object("symlinks")).members {
            let url = root.appending(path: m.key, directoryHint: .notDirectory)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let target = try #require(m.value.stringValue)
            try fm.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: target)
        }
        #expect(sb.paths.nativeSources.standardizedFileURL == root.standardizedFileURL)
        let got = PyLineCount.codeNative(sb.paths.nativeSources)
        #expect(Int64(got.bytes) == c.expected.int("bytes"))
        #expect(Int64(got.lines) == c.expected.int("lines"))
        #expect(Int64(got.files) == c.expected.int("files"))
    }
}

// MARK: - m1b_tz

@Suite("Research golden: local day and %z (m1b_tz)")
struct ResearchClockGoldenTests {
    @Test(arguments: try Golden.cases("m1b_tz"))
    func matchesPython(_ c: GoldenCase) throws {
        let zone = try #require(c.input.string("tz"))
        let tz = try #require(TimeZone(identifier: zone))
        let ts = try #require(c.input.double("ts"))
        let clock = ResearchClock(ManualClock(ts), timeZone: tz)
        #expect(clock.localDate(ts) == c.expected.string("date"))
        #expect(clock.today() == c.expected.string("date"))
        #expect(clock.utcOffset(ts) == c.expected.string("z"))
    }
}

// MARK: - m1b_git

@Suite("Research golden: git probe (m1b_git)")
struct ResearchGitGoldenTests {
    /// Replays jarvis's subprocess results through GitProbe's runner seam: same argv, same
    /// timeout, same strip and exception mapping.
    @Test(arguments: try Golden.cases("m1b_git").filter { $0.input.string("kind") == "runner" })
    func runnerMatchesPython(_ c: GoldenCase) throws {
        let plan = try #require(c.input.array("plan")).compactMap(\.objectValue)
        let repo = URL(fileURLWithPath: "/nonexistent/jarvis-root", isDirectory: true)
        let calls = RecordedCalls()
        let got = GitProbe.headAndCommits(repo: repo, timeout: 5) { args, timeout in
            let k = calls.append(args, timeout)
            guard k < plan.count, plan[k]["raise"] == nil else { return nil }
            return plan[k].string("stdout")
        }
        let head = try #require(c.expected.string("git_head"))
        let commits = try #require(c.expected.string("git_commits"))
        #expect(PyStrEqual(got.head, head))
        #expect(PyStrEqual(got.commits, commits))
        let expected = try #require(c.expected.array("calls")).compactMap(\.objectValue)
        let seen = calls.all
        #expect(seen.count == expected.count)
        for (s, e) in zip(seen, expected) {
            let argv = try #require(e.array("args")).compactMap(\.stringValue)
                .map { ResearchFixture.detokenize($0, home: "/nonexistent/jarvis-root") }
            #expect(s.args == argv)
            #expect(e.object("kwargs")?.double("timeout") == s.timeout)
        }
    }

    /// Builds the deterministic repo with the script stored in the fixture and runs the real
    /// git through GitProbe; the expected HEAD was hashed by the generator from git's object
    /// format.
    @Test func fixtureRepoMatchesHashedHead() throws {
        let c = try #require(try Golden.cases("m1b_git").first { $0.input.string("kind") == "repo" })
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let repo = sb.box.root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let script = sb.box.root.appending(path: "git_fixture.sh", directoryHint: .notDirectory)
        try Data(try #require(c.input.string("script")).utf8).write(to: script)
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = [script.path(percentEncoded: false), repo.path(percentEncoded: false)]
        try sh.run()
        sh.waitUntilExit()
        try #require(sh.terminationStatus == 0, "git_fixture.sh failed")
        let got = GitProbe.headAndCommits(repo: repo)
        #expect(got.head == c.expected.string("git_head"))
        #expect(got.commits == c.expected.string("git_commits"))
    }

    /// Observed with the real git (2.54, 2026-09-28): a non-repo and an empty repo both print
    /// nothing on stdout (exit 128), so Python's `.stdout.strip()` gives "" for both fields.
    @Test func nonRepoAndEmptyRepoGiveEmptyFields() throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let plain = sb.box.root.appending(path: "plain", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let none = GitProbe.headAndCommits(repo: plain)
        #expect(none.head == "" && none.commits == "")

        let empty = sb.box.root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-c", "init.defaultBranch=main", "init", "-q", empty.path(percentEncoded: false)]
        git.environment = ["PATH": "/usr/bin:/bin", "HOME": sb.box.root.path(percentEncoded: false),
                           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let fresh = GitProbe.headAndCommits(repo: empty)
        #expect(fresh.head == "" && fresh.commits == "")
    }

    /// A command that outlives the timeout is killed and blanks both fields.
    @Test func timeoutBlanksBothFields() {
        let started = Date()
        let out = GitProbe.run(["sleep", "5"], 0.3)
        #expect(out == nil)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(GitProbe.run(["printf", "abc\\n"], 5) == "abc\n")
        #expect(GitProbe.run(["jarvis-no-such-command-x4"], 5) == "")    // env: exit 127, empty stdout
    }
}

final class RecordedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(args: [String], timeout: Double)] = []

    func append(_ args: [String], _ timeout: Double) -> Int {
        lock.withLock {
            calls.append((args, timeout))
            return calls.count - 1
        }
    }

    var all: [(args: [String], timeout: Double)] { lock.withLock { calls } }
}

// MARK: - m1b_bump

@Suite("Research golden: usage.json bumps (m1b_bump)")
struct ResearchBumpGoldenTests {
    @Test(arguments: try Golden.cases("m1b_bump"))
    func matchesPython(_ c: GoldenCase) throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        let fm = FileManager.default
        let usage = sb.paths.usage
        let usagePath = usage.path(percentEncoded: false)
        if c.input["research_dir_missing"] == .bool(true) {
            try fm.removeItem(at: sb.paths.dir)
        }
        if c.input["usage_is_directory"] == .bool(true) {
            try fm.createDirectory(at: usage, withIntermediateDirectories: false)
        }
        if let initial = ResearchFixture.data(c.input, "initial_b64") {
            try initial.write(to: usage)
        }
        let clock = ManualClock(0)
        let london = try #require(TimeZone(identifier: "Europe/London"))
        let rclock = ResearchClock(clock, timeZone: london)
        let store: any ResearchCounting = UsageStore(paths: sb.paths, clock: rclock)

        let steps = try #require(c.expected.array("steps")).compactMap(\.objectValue)
        for (k, step) in steps.enumerated() {
            let ts = try #require(step.double("ts"))
            let key = try #require(step.string("key"))
            let n = try #require(step.int("n"))
            #expect(rclock.localDate(ts) == step.string("day"), "step \(k) day")
            let before = Self.regularFile(usagePath)
            clock.set(ts)
            store.bump(key, by: Int(n))                     // the ResearchCounting path
            let after = Self.regularFile(usagePath)
            if step["python_wrote"] == .bool(true) {
                #expect(after == ResearchFixture.data(step, "after_b64"), "step \(k) bytes")
            } else {
                #expect(after == before, "step \(k): Python wrote nothing, native must not either")
                #expect(step.string("after_b64").flatMap { Data(base64Encoded: $0) } == before)
            }
            if let native = step.object("native") {
                // D1 (positive): the unparseable original is kept, byte for byte, once.
                #expect(native.string("deviation") == "D1")
                let name = try #require(native.string("quarantine_name"))
                let kept = sb.paths.dir.appending(path: name, directoryHint: .notDirectory)
                #expect(Self.regularFile(kept.path(percentEncoded: false))
                        == ResearchFixture.data(native, "quarantine_b64"))
                withKnownIssue("D1: Python keeps no copy of the unparseable usage.json") {
                    let names = try fm.contentsOfDirectory(atPath: sb.paths.dir.path(percentEncoded: false))
                    #expect(names == ["usage.json"])
                }
            }
        }
        #expect(Self.regularFile(usagePath) == ResearchFixture.data(c.expected, "final_b64"))
        let names = (try? fm.contentsOfDirectory(atPath: sb.paths.dir.path(percentEncoded: false))) ?? []
        #expect(!names.contains { $0.contains(".jarvis-tmp.") }, "no temp file left behind (D3)")
        let quarantined = names.filter { $0.hasPrefix("usage.json.corrupt-") }
        #expect(quarantined.count == (c.expected.string("deviation") == "D1" ? 1 : 0))

        // research_snapshot's usage_today for the last step's day.
        let lastDay = try #require(steps.last?.string("day"))
        let today = UsageStore(paths: sb.paths, clock: rclock).day(lastDay)
        #expect(PyJSON.dumps(today) == c.expected.string("usage_today_json"))
    }

    /// The bytes of a regular file; nil if missing or not a regular file (os.path.isfile).
    static func regularFile(_ path: String) -> Data? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return FileManager.default.contents(atPath: path)
    }
}

// MARK: - m1b_last_date

@Suite("Research golden: metrics.jsonl last date and append (m1b_last_date)")
struct ResearchLastDateGoldenTests {
    @Test(arguments: try Golden.cases("m1b_last_date").filter { !$0.expected.has("python_after_b64") })
    func lastDateMatchesPython(_ c: GoldenCase) throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        if let data = ResearchFixture.data(c.input, "b64") {
            try data.write(to: sb.paths.metrics)
        }
        let got = MetricsLog(paths: sb.paths).lastDate()
        let python = try #require(c.expected.string("python"))
        #expect(got == c.expected.string("native"))
        if c.expected.string("deviation") == "D2" {
            #expect(python == "" && got != "", "D2: the full last line is read")
            withKnownIssue("D2: Python reads only the last 8 KB, so this last row reads \"\"") {
                #expect(got == python)
            }
        } else {
            #expect(got == python)
        }
    }

    @Test(arguments: try Golden.cases("m1b_last_date").filter { $0.expected.has("python_after_b64") })
    func appendMatchesPython(_ c: GoldenCase) throws {
        let sb = try ResearchSandbox()
        defer { sb.remove() }
        if let data = ResearchFixture.data(c.input, "initial_b64") {
            try data.write(to: sb.paths.metrics)
        }
        let row = try #require(ResearchFixture.data(c.input, "append_line_b64"))
        let log = MetricsLog(paths: sb.paths)
        try log.append(String(decoding: row, as: UTF8.self))
        let after = FileManager.default.contents(atPath: sb.paths.metrics.path(percentEncoded: false))
        let native = try #require(c.expected.object("native"))
        let pythonAfter = ResearchFixture.data(c.expected, "python_after_b64")
        #expect(after == ResearchFixture.data(native, "after_b64"))
        #expect(log.lastDate() == native.string("last_date"))
        if native.string("deviation") == "D4" {
            #expect(c.expected.string("python") == "", "Python's merged line reads as no date")
            withKnownIssue("D4: Python appends straight after the dangling line and merges them") {
                #expect(after == pythonAfter)
            }
        } else {
            #expect(after == pythonAfter)
            #expect(log.lastDate() == c.expected.string("python"))
        }
    }
}
