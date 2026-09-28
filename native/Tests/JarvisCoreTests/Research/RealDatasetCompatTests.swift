import CryptoKit
import Foundation
import JarvisCore
import Testing

// Schema-compat over the user's REAL research dataset (plan: M01b T7 (b), acceptance A4):
// native reads and re-serialises metrics.jsonl and usage.json without changing a single byte.
// Runs ONLY with JARVIS_REAL_DATASET=1 — a plain `swift test` never opens the real files.
// The dataset is private and read-only: files are only ever read, and failures report row
// indexes, key paths, value kinds and byte offsets, never content. Size, mtime_ns and sha256
// of both files are recorded before and after and must be unchanged.
//
// The real dataset lives only in the main tree (`$HOME/jarvis/research`), never in a
// worktree, so it is resolved from HOME, not from #filePath. Skipped cleanly if absent.

private let realDatasetRequested = ProcessInfo.processInfo.environment["JARVIS_REAL_DATASET"] == "1"
private let compatPython = "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"

private func realResearchDir() -> URL? {
    guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty else { return nil }
    return URL(filePath: home, directoryHint: .isDirectory)
        .appending(path: "jarvis/research", directoryHint: .isDirectory)
}

private func realDatasetPresent() -> Bool {
    guard let dir = realResearchDir() else { return false }
    let fm = FileManager.default
    return fm.fileExists(atPath: dir.appending(path: "metrics.jsonl").path(percentEncoded: false))
        && fm.fileExists(atPath: dir.appending(path: "usage.json").path(percentEncoded: false))
}

/// native/tools/research_schema_check.py, from this file's location in the tree.
private func schemaCheckScript(_ file: String = #filePath) -> URL {
    URL(filePath: file).deletingLastPathComponent()   // Research
        .deletingLastPathComponent()                   // JarvisCoreTests
        .deletingLastPathComponent()                   // Tests
        .deletingLastPathComponent()                   // native
        .appending(path: "tools/research_schema_check.py")
}

private struct Fingerprint: Equatable {
    let size: Int64
    let mtimeNs: Int64
    let sha256: String
}

/// stat + a read-only read (`Data(contentsOf:)` opens O_RDONLY).
private func fingerprint(_ url: URL) throws -> (Fingerprint, Data) {
    var st = stat()
    try #require(stat(url.path(percentEncoded: false), &st) == 0, "cannot stat \(url.lastPathComponent)")
    let data = try Data(contentsOf: url)
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let mtime = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    return (Fingerprint(size: Int64(st.st_size), mtimeNs: mtime, sha256: hash), data)
}

private func kind(_ v: JSONValue) -> String {
    switch v {
    case .null: "null"
    case .bool: "bool"
    case .int: "int"
    case .bigInt: "bigInt"
    case .double: "double"
    case .string: "string"
    case .array: "array"
    case .object: "object"
    }
}

/// Key path (and value kind) of the member whose compact `dumps` contains byte `off` of
/// `PyJSON.dumps(v)`. Everything before the first differing byte is identical in both
/// outputs, so this names where native starts to reformat (a difference right after a
/// value — one side's number is longer — is charged to that value). Names only, never values.
private func path(at off: Int, in v: JSONValue) -> String {
    switch v {
    case .object(let o):
        var pos = 1                                                    // "{"
        for m in o.members {
            let keyLen = PyJSON.dumps(.string(m.key)).utf8.count + 2   // "key":
            let valLen = PyJSON.dumps(m.value).utf8.count
            if off < pos + keyLen { return "\(m.key) (key)" }
            if off <= pos + keyLen + valLen {                          // end inclusive: a value cut short
                let sub = path(at: off - pos - keyLen, in: m.value)
                return sub.hasPrefix("(") ? "\(m.key) \(sub)" : "\(m.key).\(sub)"
            }
            pos += keyLen + valLen + 2                                 // ", "
        }
        return "(object end)"
    case .array(let a):
        var pos = 1                                                    // "["
        for (i, e) in a.enumerated() {
            let len = PyJSON.dumps(e).utf8.count
            if off <= pos + len {
                let sub = path(at: off - pos, in: e)
                return sub.hasPrefix("(") ? "[\(i)] \(sub)" : "[\(i)].\(sub)"
            }
            pos += len + 2
        }
        return "(array end)"
    default:
        return "(\(kind(v)))"
    }
}

private func firstDifference(_ a: Data, _ b: Data) -> Int {
    let x = [UInt8](a), y = [UInt8](b)
    var i = 0
    while i < min(x.count, y.count) && x[i] == y[i] { i += 1 }
    return i
}

/// Runs the A3 check script on `dir`; returns its exit status and the fields of its
/// `rows N dates D first F last L violations V unchanged U` line.
private func runSchemaCheck(_ dir: URL) throws -> (status: Int32, fields: [String: String]) {
    let p = Process()
    p.executableURL = URL(filePath: compatPython)
    p.arguments = [schemaCheckScript().path(percentEncoded: false), dir.path(percentEncoded: false)]
    p.environment = ["PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out                   // aggregates only; merged so neither pipe can fill
    try p.run()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    p.waitUntilExit()
    var fields: [String: String] = [:]
    if let line = text.split(separator: "\n").last(where: { $0.hasPrefix("rows ") }) {
        let words = line.split(separator: " ").map(String.init)
        for i in stride(from: 0, to: words.count - 1, by: 2) { fields[words[i]] = words[i + 1] }
    }
    return (p.terminationStatus, fields)
}

@Suite("Real dataset compat (read-only, JARVIS_REAL_DATASET=1)")
struct RealDatasetCompatTests {
    @Test(.enabled(if: realDatasetRequested, "set JARVIS_REAL_DATASET=1 to read ~/jarvis/research read-only"),
          .enabled(if: !realDatasetRequested || realDatasetPresent(), "~/jarvis/research/{metrics.jsonl,usage.json} absent"))
    func realRowsAndUsageRoundTripByteForByte() throws {
        let dir = try #require(realResearchDir())
        let metricsURL = dir.appending(path: "metrics.jsonl")
        let usageURL = dir.appending(path: "usage.json")
        let (metricsBefore, metrics) = try fingerprint(metricsURL)
        let (usageBefore, usage) = try fingerprint(usageURL)

        // metrics.jsonl: every row is `json.dumps(snap) + "\n"`.
        #expect(metrics.last == UInt8(ascii: "\n"), "metrics.jsonl does not end in a newline")
        var lines = metrics.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        var identical = 0
        for (i, raw) in lines.enumerated() {
            let line = Data(raw)
            let value: JSONValue
            do { value = try PyJSON.loads(line) } catch {
                Issue.record("row \(i): PyJSON.loads failed: \(error)")
                continue
            }
            let native = Data(PyJSON.dumps(value).utf8)
            if native == line {
                identical += 1
            } else {
                let off = firstDifference(line, native)
                Issue.record("row \(i): not byte-identical from byte \(off) of \(line.count), at \(path(at: off, in: value))")
            }
        }

        // usage.json: `json.dump(u, f, indent=1)`, no trailing newline (§2.2).
        var usageIdentical = false
        do {
            let native = Data(PyJSON.dumps(try PyJSON.loads(usage), indent: 1).utf8)
            usageIdentical = native == usage
            if !usageIdentical {
                Issue.record("usage.json: not byte-identical from byte \(firstDifference(usage, native)) of \(usage.count)")
            }
        } catch {
            Issue.record("usage.json: PyJSON.loads failed: \(error)")
        }

        // The A3 script's view of the same files: its last date is MetricsLog's.
        try #require(FileManager.default.isExecutableFile(atPath: compatPython), "framework Python missing")
        let check = try runSchemaCheck(dir)
        #expect(check.status == 0)
        #expect(check.fields["violations"] == "0")
        #expect(check.fields["unchanged"] == "yes")
        #expect(check.fields["rows"] == String(lines.count))
        let last = MetricsLog(url: metricsURL).lastDate()
        #expect(!last.isEmpty)
        #expect(check.fields["last"] == last, "MetricsLog.lastDate() differs from the check script's last date")

        let (metricsAfter, _) = try fingerprint(metricsURL)
        let (usageAfter, _) = try fingerprint(usageURL)
        let unchanged = metricsBefore == metricsAfter && usageBefore == usageAfter
        #expect(identical == lines.count)
        #expect(usageIdentical)
        #expect(unchanged, "real dataset size/mtime_ns/sha256 changed during the test")
        print("roundtrip rows=\(identical)/\(lines.count) usage=\(usageIdentical ? "identical" : "differs") unchanged=\(unchanged ? "yes" : "no")")
    }
}
