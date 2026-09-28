import Foundation

// research/metrics.jsonl: one snapshot row per day, append-only (plan: M01b §2.1, §3.2, §3.4).
// Python, jarvis.py _research_last_date (2516–2523):
//     f.seek(max(0, size - 8192)); lines = f.read().decode(errors="ignore").strip().splitlines()
//     return json.loads(lines[-1]).get("date", "")        # any failure → ""
// and research_snapshot appends `json.dumps(snap) + "\n"` in "a" mode.
//   D2  Python sees only the last 8 KB, so a last row longer than that parses as a fragment
//       and reads "" (a duplicate row every hour). Native applies the same decode / strip /
//       splitlines rule to the COMPLETE last line, reading backwards in 8 KB chunks until the
//       line's start is inside what it has read (no limit).
//   D4  Python appends straight after a dangling partial line, merging two rows. Native
//       writes "\n" first when the file is non-empty and does not end in "\n"; the fragment
//       stays a skippable malformed line.
// Golden suite: m1b_last_date (rows from the real research_snapshot).

public struct MetricsLog: Sendable {
    public let url: URL
    static let chunk = 8192

    public init(url: URL) {
        self.url = url
    }

    public init(paths: ResearchPaths) {
        self.init(url: paths.metrics)
    }

    private var path: String { url.path(percentEncoded: false) }

    /// The "date" of the complete last line; "" on any failure (missing file, no line,
    /// malformed JSON, not an object, no "date", or a non-string date — Python returns that
    /// value, which is never equal to today either).
    public func lastDate() -> String {
        guard let line = lastLine(),
              case .object(let row)? = try? PyJSON.loads(Data(line.utf8)),
              case .string(let date)? = row["date"] else { return "" }
        return date
    }

    /// Python's `decode(errors="ignore").strip().splitlines()[-1]` over the whole file.
    func lastLine() -> String? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        var start = Int(st.st_size)
        var tail: [UInt8] = []
        while true {
            let from = max(0, start - Self.chunk)
            var buf = [UInt8](repeating: 0, count: start - from)
            var got = 0
            while got < buf.count {
                let r = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, $0.count - got, off_t(from + got)) }
                if r < 0 { if errno == EINTR { continue }; return nil }
                if r == 0 { break }
                got += r
            }
            guard got == buf.count else { return nil }            // the file shrank under us
            tail = buf + tail
            start = from
            let text = Self.strippedScalars(tail)
            if let cut = text.lastIndex(where: PyStr.isLineBreak) {
                var out = String.UnicodeScalarView()
                out.append(contentsOf: text[(cut + 1)...])
                return String(out)
            }
            if start == 0 {
                if text.isEmpty { return nil }                     // splitlines() == []: IndexError
                var out = String.UnicodeScalarView()
                out.append(contentsOf: text)
                return String(out)
            }
        }
    }

    /// `bytes.decode("utf-8", errors="ignore").strip()` as scalars. Every splitlines()
    /// boundary is also str.isspace(), so after strip the text never ends in one.
    static func strippedScalars(_ bytes: [UInt8]) -> [Unicode.Scalar] {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(bytes.count)
        var it = bytes.makeIterator()
        var utf8 = UTF8()
        loop: while true {
            switch utf8.decode(&it) {
            case .scalarValue(let u): scalars.append(u)
            case .emptyInput: break loop
            case .error: continue                                 // errors="ignore"
            }
        }
        var lo = 0, hi = scalars.count
        while lo < hi && PyStr.isSpace(scalars[lo]) { lo += 1 }
        while hi > lo && PyStr.isSpace(scalars[hi - 1]) { hi -= 1 }
        return Array(scalars[lo..<hi])
    }

    /// Appends `line + "\n"` in one O_APPEND write (after `os.makedirs(RESEARCH_DIR)`), with
    /// a leading "\n" if the file is non-empty and does not already end in one (D4).
    public func append(_ line: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var prefix = ""
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd >= 0 {
            var st = stat()
            var last: UInt8 = 0x0A
            if fstat(fd, &st) == 0, st.st_size > 0, pread(fd, &last, 1, st.st_size - 1) == 1, last != 0x0A {
                prefix = "\n"
            }
            close(fd)
        }
        try AtomicFile.appendLine(prefix + line, to: path)
    }
}
