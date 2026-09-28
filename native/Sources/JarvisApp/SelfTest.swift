import Foundation
import JarvisCore

/// `JARVIS --selftest` (plan: M00 §3.5, §3.9, A8): a headless JSON report on stdout, exit 0
/// when every check passes, else 1. Read-only: it never configures the log sink, and it takes
/// the lock only to learn whether it is free (released again before returning). Each real
/// state file is decoded with PyJSON and re-encoded in the style Python writes it; the bytes
/// must come back identical.
enum SelfTest {
    /// How jarvis.py writes each file. `.lines` = one `json.dumps(obj)` + "\n" per line.
    private enum Style: String {
        case indent1 = "indent=1"
        case compact = "default"
        case lines = "jsonl"
    }

    private static func stateFiles(_ p: StatePaths) -> [(name: String, url: URL, style: Style)] { [
        ("knowledge.json", p.knowledge, .indent1),                // jarvis.py:2009
        ("history.json", p.history, .compact),                    // jarvis.py:4684
        ("corrections.json", p.corrections, .indent1),            // jarvis.py:839
        ("profile.json", p.profile, .indent1),                    // jarvis.py:2067
        ("personality.json", p.personality, .indent1),            // jarvis.py:2188
        ("emotions.json", p.emotions, .indent1),                  // jarvis.py:2326
        ("proactive.json", p.proactive, .compact),                // jarvis.py:2554
        ("alarms.json", p.alarms, .compact),                      // jarvis.py:4009
        ("research/usage.json", p.researchUsage, .indent1),       // jarvis.py:2462
        ("research/metrics.jsonl", p.researchMetrics, .lines),    // jarvis.py:2519
    ] }

    static func run() -> Int32 {
        var report = JSONObject()
        var ok = true
        let bundleID = Bundle.main.bundleIdentifier
        report["bundle_id"] = bundleID.map { .string($0) } ?? .null
        ok = ok && bundleID == "com.jarvis.assistant"
        report["version"] = .string("\(Entry.infoString("CFBundleShortVersionString")) (\(Entry.infoString("CFBundleVersion")))")

        let paths: StatePaths
        do {
            paths = try StatePaths.live()
        } catch {
            report["state_root_valid"] = .bool(false)
            report["state_root_error"] = .string(String(describing: error))
            report["ok"] = .bool(false)
            emit(report)
            return 1
        }
        report["state_root"] = .string(AppDelegate.abbreviate(paths.root))
        report["state_root_valid"] = .bool(true)

        switch InstanceLock.tryAcquire(at: paths.lockFile, repoRoot: paths.root) {
        case .acquired:
            report["lock_free"] = .bool(true)   // the InstanceLock is dropped here: released
        case .held(let holder):
            report["lock_free"] = .bool(false)
            report["lock_holder"] = .string(AppDelegate.describe(holder))
            ok = false
        case .foreignProcess(let pids):
            report["lock_free"] = .bool(false)
            report["lock_holder"] = .string("python \(pids[0]), pre-patch")
            ok = false
        }

        var files: [JSONValue] = []
        var absent: [JSONValue] = []
        for entry in stateFiles(paths) {
            guard let data = AtomicFile.read(entry.url.path(percentEncoded: false)) else {
                absent.append(.string(entry.name))
                continue
            }
            var row = JSONObject()
            row["file"] = .string(entry.name)
            row["style"] = .string(entry.style.rawValue)
            row["bytes"] = .int(Int64(data.count))
            switch reencode(data, style: entry.style) {
            case .success(let same):
                row["reencode_byte_identical"] = .bool(same)
                ok = ok && same
            case .failure(let error):
                row["reencode_byte_identical"] = .bool(false)
                row["error"] = .string(String(describing: error))
                ok = false
            }
            files.append(.object(row))
        }
        report["state_files"] = .array(files)
        report["state_files_absent"] = .array(absent)
        report["ok"] = .bool(ok)
        emit(report)
        return ok ? 0 : 1
    }

    private static func reencode(_ data: Data, style: Style) -> Result<Bool, PyJSONError> {
        do {
            switch style {
            case .indent1:
                return .success(Data(PyJSON.dumps(try PyJSON.loads(data), indent: 1).utf8) == data)
            case .compact:
                return .success(Data(PyJSON.dumps(try PyJSON.loads(data)).utf8) == data)
            case .lines:
                var out = Data()
                for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast() {
                    out.append(contentsOf: PyJSON.dumps(try PyJSON.loads(Data(line))).utf8)
                    out.append(UInt8(ascii: "\n"))
                }
                return .success(out == data)
            }
        } catch {
            return .failure(error)   // typed throws: the do block throws only PyJSONError
        }
    }

    private static func emit(_ report: JSONObject) {
        print(PyJSON.dumps(.object(report), indent: 2))
    }
}
