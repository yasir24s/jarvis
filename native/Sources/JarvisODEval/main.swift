import Foundation
import JarvisEval

// OD-EVAL runner. Two modes, both on the real on-device path with recording fake tools:
//
//   JarvisODEval --od-eval <fixture.json> [--out <cases.jsonl>] [--summary <summary.json>]
//                [--only <id-prefix>[,…]] [--limit <n>] [--timeout <seconds>] [--verbose] [--no-guided]
//   JarvisODEval --od-replay <archive> --out <report.json> [--include-text] [--limit <n>]
//                [--timeout <seconds>]
//   JarvisODEval --od-rank <fixture.json> [--top <n>[,<n>…]] [--only <id-prefix>[,…]]
//
// --od-rank runs the tool ranker alone, no model: recall at each --top (default 8,10,12) and
// the cases it misses at the first.
// --od-eval prints the scorecard table and writes one JSON line per case to --out.
// --od-replay writes aggregate counts only to --out (0600); request and reply text are written
// only with --include-text. It prints counts only, never text.

let usage = """
    usage: JarvisODEval --od-eval <fixture.json> [--out <cases.jsonl>] [--summary <summary.json>]
                        [--only <id-prefix>[,…]] [--limit <n>] [--timeout <seconds>] [--verbose] [--no-guided]
           JarvisODEval --od-replay <archive> --out <report.json> [--include-text] [--limit <n>]
                        [--timeout <seconds>]
           JarvisODEval --od-rank <fixture.json> [--top <n>[,<n>…]] [--only <id-prefix>[,…]]

    """

func fail(_ message: String, _ status: Int32) -> Never {
    FileHandle.standardError.write(Data("JarvisODEval: \(message)\n".utf8))
    exit(status)
}

func note(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

struct Options {
    var mode = ""
    var input = ""
    var out: String?
    var summary: String?
    var only: String?
    var limit: Int?
    var timeout = 90.0
    var includeText = false
    var top = [8, 10, 12]
    var verbose = false
    var guided = true
}

func parse(_ args: [String]) -> Options? {
    var o = Options()
    var i = 0
    func value() -> String? {
        i += 1
        return i < args.count ? args[i] : nil
    }
    while i < args.count {
        switch args[i] {
        case "--od-eval", "--od-replay", "--od-rank":
            guard o.mode.isEmpty, let v = value() else { return nil }
            o.mode = args[i - 1]
            o.input = v
        case "--out": guard let v = value() else { return nil }; o.out = v
        case "--summary": guard let v = value() else { return nil }; o.summary = v
        case "--only": guard let v = value() else { return nil }; o.only = v
        case "--limit": guard let v = value().flatMap(Int.init), v > 0 else { return nil }; o.limit = v
        case "--timeout": guard let v = value().flatMap(Double.init), v > 0 else { return nil }; o.timeout = v
        case "--include-text": o.includeText = true
        case "--verbose": o.verbose = true
        case "--no-guided": o.guided = false
        case "--top":
            guard let v = value() else { return nil }
            let ks = v.split(separator: ",").compactMap { Int($0) }.filter { $0 > 0 }
            guard !ks.isEmpty else { return nil }
            o.top = ks
        default: return nil
        }
        i += 1
    }
    if o.mode.isEmpty { return nil }
    if o.mode == "--od-replay" && o.out == nil { return nil }
    return o
}

/// Creates (or truncates) `path` readable by the owner only.
func privateFile(_ path: String) -> FileHandle {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
          let handle = try? FileHandle(forWritingTo: url) else {
        fail("cannot write \(path)", 73)
    }
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return handle
}

guard let options = parse(Array(CommandLine.arguments.dropFirst())) else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}

/// `--only a,b`: cases whose id starts with any of the comma-separated prefixes.
func onlyFilter(_ cases: [EvalCase]) -> [EvalCase] {
    guard let only = options.only else { return cases }
    let prefixes = only.split(separator: ",").map(String.init)
    return cases.filter { c in prefixes.contains { c.id.hasPrefix($0) } }
}

if options.mode == "--od-rank" {
    let fixture: EvalFixture
    do {
        fixture = try EvalFixture.load(URL(fileURLWithPath: options.input))
    } catch {
        fail("cannot read the fixture \(options.input): \(error)", 66)
    }
    let reports = RankerRecall.run(onlyFilter(fixture.cases), top: options.top)
    for r in reports {
        print(String(format: "ranker recall @%-3d %5.1f%%  (%d/%d)", r.top, r.recall * 100, r.found, r.cases))
    }
    let fast = RankerRecall.fastPath(onlyFilter(fixture.cases))
    print("fast path: \(fast.python) by Python's branches, \(fast.native.count) by native ones")
    for n in fast.native { print("  native: \(n.id) \(n.branch)") }
    for t in fast.tools { print("  fastpath-tool: \(t.id) \(t.tool)") }
    if let first = reports.first {
        for m in first.misses { print("  miss @\(first.top): \(m.id) \(m.expected) rank \(m.rank.map(String.init) ?? "-")") }
    }
    exit(0)
}

if let reason = OnDeviceBrain.unavailableReason() {
    fail("Apple Intelligence's on-device model is unavailable (\(reason)). "
         + "Turn on Apple Intelligence in System Settings and wait for the model to download, then run again.", 69)
}

// --verbose: the brain's own log lines to stderr (fixture runs only; the replay never logs text).
let brain = options.verbose && options.mode == "--od-eval"
    ? OnDeviceBrain(timeout: .milliseconds(Int(options.timeout * 1000)), log: { note("  log: " + $0) },
                    guided: options.guided)
    : OnDeviceBrain(timeout: .milliseconds(Int(options.timeout * 1000)), guided: options.guided)

switch options.mode {
case "--od-eval":
    let fixture: EvalFixture
    do {
        fixture = try EvalFixture.load(URL(fileURLWithPath: options.input))
    } catch {
        fail("cannot read the fixture \(options.input): \(error)", 66)
    }
    var cases = fixture.cases
    cases = onlyFilter(cases)
    if let limit = options.limit { cases = Array(cases.prefix(limit)) }
    let out = options.out.map(privateFile)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var done = 0
    let results = await EvalScorer.run(cases, brain: brain) { r in
        done += 1
        note(String(format: "[%3d/%d] %@ %@ %.0f ms", done, cases.count, r.id,
                    r.failure?.rawValue ?? "pass", r.latencyMs))
        if let out, let line = try? encoder.encode(r) {
            out.write(line)
            out.write(Data("\n".utf8))
        }
    }
    try? out?.close()
    let summary = EvalSummary(results, cases: cases)
    print(summary.table(), terminator: "")
    if let path = options.summary {
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        let handle = privateFile(path)
        handle.write((try? pretty.encode(summary)) ?? Data())
        try? handle.close()
    }
    exit(0)

default:   // --od-replay
    var requests: [String]
    do {
        requests = try Replay.requests(fromArchive: URL(fileURLWithPath: options.input))
    } catch {
        fail("cannot read the archive: \(error)", 66)
    }
    if let limit = options.limit { requests = Array(requests.suffix(limit)) }
    note("replaying \(requests.count) requests\(options.includeText ? " (text included in the report)" : "")")
    let total = requests.count
    let report = await Replay.run(requests, brain: brain, includeText: options.includeText) { n in
        if n % 10 == 0 || n == total { note("  \(n)/\(total)") }
    }
    let handle = privateFile(options.out!)
    do {
        handle.write(try Replay.encode(report))
        try handle.close()
    } catch {
        fail("cannot write the report: \(error)", 73)
    }
    note("wrote \(options.out!): \(report.requests) requests, claimed-no-tool \(report.claimedActionNoTool), "
         + "timeouts \(report.timeouts), empty \(report.emptyReplies), keyword misses \(report.keywordMisses)")
    exit(0)
}
