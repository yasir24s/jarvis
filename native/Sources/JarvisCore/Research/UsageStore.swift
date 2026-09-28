import Foundation
import Synchronization

// research/usage.json: per-day event counters (plan: M01b §2.1, §2.2, §3.2, §3.4).
// Python, jarvis.py research_bump (2443–2456):
//     day = time.strftime("%Y-%m-%d")
//     with _research_lock:
//         os.makedirs(RESEARCH_DIR, exist_ok=True)
//         try: u = json.load(open(RESEARCH_USAGE))
//         except Exception: u = {}
//         u.setdefault(day, {})[key] = u.get(day, {}).get(key, 0) + n
//         json.dump(u, open(RESEARCH_USAGE, "w"), indent=1)
//     any exception → log("Research bump: …"), no write
// Native writes the same bytes (PyJSON indent=1, ensure_ascii, no trailing newline; day and
// key order are insertion order) with two deliberate differences:
//   D1  an unparseable NON-EMPTY file is first copied to usage.json.corrupt-<int(now)>
//       (never overwritten), then the Python-identical result (today only) is written.
//       Extension: a file that exists but cannot be read at all cannot be copied, so native
//       refuses to write rather than replace it (Python would, if it were writable).
//   D3  temp file in research/ + rename(2) (M0's AtomicFile), not truncate-in-place.
// Golden suite: m1b_bump (every step's bytes, from the real research_bump).

public enum UsageError: Error, Sendable, Equatable, CustomStringConvertible {
    case rootNotObject                  // Python: AttributeError, '<type>' object has no attribute 'get'
    case dayNotObject(String)           // same, on the day's value
    case counterNotNumeric(String)      // TypeError: unsupported operand / can only concatenate
    case intTooLarge(String)            // Python's int→str limit (4300 digits) would raise in dump
    case unreadable(String)             // the file exists but its bytes cannot be read (D1 ext.)
    case quarantine(String)             // D1 copy failed: nothing is written
    case io(String)                     // makedirs / temp write / rename failed

    public var description: String {
        switch self {
        case .rootNotObject: "usage.json root is not an object"
        case let .dayNotObject(day): "usage.json day \(day) is not an object"
        case let .counterNotNumeric(key): "counter \(key) is not a number"
        case let .intTooLarge(key): "counter \(key) exceeds 4300 digits"
        case let .unreadable(why): "usage.json exists but is unreadable: \(why)"
        case let .quarantine(why): "could not keep the unparseable usage.json: \(why)"
        case let .io(why): why
        }
    }
}

public final class UsageStore: ResearchCounting, Sendable {
    public let url: URL
    public let clock: ResearchClock
    private let lock = Mutex(())                  // the analogue of _research_lock

    public init(url: URL, clock: ResearchClock = ResearchClock()) {
        self.url = url
        self.clock = clock
    }

    public convenience init(paths: ResearchPaths, clock: ResearchClock = ResearchClock()) {
        self.init(url: paths.usage, clock: clock)
    }

    /// `ResearchCounting`: today's counter from the clock, synchronously, in call order.
    /// Never throws: a failure is logged as Python logs it and nothing is written.
    public func bump(_ key: String, by n: Int) {
        let now = clock.now()
        do {
            try bump(key, by: n, day: clock.localDate(now), now: now)
        } catch {
            JarvisLog.log("Research bump: \(error)", category: .research)
        }
    }

    /// `usage[day][key] += n`. `now` names a D1 quarantine file.
    public func bump(_ key: String, by n: Int, day: String, now: Double) throws(UsageError) {
        try lock.withLock { _ throws(UsageError) in
            try locked(key, by: n, day: day, now: now)
        }
    }

    /// research_snapshot's `json.load(open(RESEARCH_USAGE)).get(day, {})`, `{}` on any
    /// failure. A JSONValue, not an object: Python returns whatever the day holds.
    public func day(_ day: String) -> JSONValue {
        lock.withLock { _ in
            guard let data = AtomicFile.read(path),
                  case .object(let root)? = try? PyJSON.loads(data) else {
                return .object(JSONObject())
            }
            return root[day] ?? .object(JSONObject())
        }
    }

    private var path: String { url.path(percentEncoded: false) }

    private func locked(_ key: String, by n: Int, day: String, now: Double) throws(UsageError) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw .io("makedirs \(dir.lastPathComponent): \(error.localizedDescription)")
        }

        var u: JSONValue = .object(JSONObject())
        var st = stat()
        if stat(path, &st) == 0 {
            guard let data = AtomicFile.read(path) else {
                throw .unreadable(st.st_mode & S_IFMT == S_IFDIR ? "is a directory" : "read failed")
            }
            do {
                u = try PyJSON.loads(data)
            } catch {
                if !data.isEmpty { try quarantine(data, now: now, why: "\(error)") }
            }
        }

        guard case .object(var root) = u else { throw .rootNotObject }
        var counters: JSONObject
        switch root[day] {
        case nil: counters = JSONObject()
        case .object(let o)?: counters = o
        default: throw .dayNotObject(day)
        }
        counters[key] = try Self.add(counters[key] ?? .int(0), n, key: key)
        root[day] = .object(counters)

        let text = PyJSON.dumps(.object(root), indent: 1)
        do {
            try AtomicFile.write(Data(text.utf8), to: path)
        } catch {
            throw .io("\(error)")
        }
    }

    /// D1: keep the original bytes under a name no later event can overwrite.
    private func quarantine(_ data: Data, now: Double, why: String) throws(UsageError) {
        let base = url.deletingLastPathComponent()
            .appending(path: "\(url.lastPathComponent).corrupt-\(Int(now.rounded(.towardZero)))",
                       directoryHint: .notDirectory)
            .path(percentEncoded: false)
        for k in 0..<100 {
            let name = k == 0 ? base : "\(base)-\(k)"
            let fd = open(name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd < 0 {
                if errno == EEXIST {
                    if AtomicFile.read(name) == data { return }        // already kept
                    continue
                }
                throw .quarantine("\(name.split(separator: "/").last ?? ""): \(String(cString: strerror(errno)))")
            }
            let ok = data.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let w = write(fd, raw.baseAddress! + off, raw.count - off)
                    if w < 0 { if errno == EINTR { continue }; return false }
                    off += w
                }
                return fsync(fd) == 0
            }
            close(fd)
            guard ok else {
                unlink(name)
                throw .quarantine("write failed")
            }
            JarvisLog.log("Research: usage.json was unparseable (\(why)); original kept as "
                          + "\(name.split(separator: "/").last ?? "") before rewriting",
                          category: .research)
            return
        }
        throw .quarantine("100 quarantine names already taken")
    }

    /// Python `old + n` for the JSON types a counter can hold: int (arbitrary precision),
    /// float, bool (True + 1 == 2); anything else raises TypeError.
    static func add(_ old: JSONValue, _ n: Int, key: String) throws(UsageError) -> JSONValue {
        switch old {
        case .int(let i):
            let (sum, overflow) = i.addingReportingOverflow(Int64(n))
            return overflow ? try normalize(PyDecimal.add(String(i), Int64(n)), key: key) : .int(sum)
        case .bigInt(let digits):
            return try normalize(PyDecimal.add(digits, Int64(n)), key: key)
        case .double(let d):
            return .double(d + Double(n))
        case .bool(let b):
            return try add(.int(b ? 1 : 0), n, key: key)
        case .null, .string, .array, .object:
            throw .counterNotNumeric(key)
        }
    }

    private static func normalize(_ digits: String, key: String) throws(UsageError) -> JSONValue {
        if let v = Int64(digits) { return .int(v) }
        let count = digits.utf8.count - (digits.hasPrefix("-") ? 1 : 0)
        guard count <= PyJSON.maxIntDigits else { throw .intTooLarge(key) }
        return .bigInt(digits)
    }
}

/// Signed decimal-string addition for counters beyond Int64 (Python ints never overflow).
enum PyDecimal {
    static func add(_ literal: String, _ n: Int64) -> String {
        let aNeg = literal.hasPrefix("-")
        let a = digits(aNeg ? String(literal.dropFirst()) : literal)
        let bNeg = n < 0
        let b = digits(String(n.magnitude))
        var neg: Bool
        var mag: [UInt8]
        if aNeg == bNeg {
            mag = plus(a, b)
            neg = aNeg
        } else if compare(a, b) >= 0 {
            mag = minus(a, b)
            neg = aNeg
        } else {
            mag = minus(b, a)
            neg = bNeg
        }
        while mag.count > 1 && mag.last == 0 { mag.removeLast() }
        if mag == [0] { neg = false }
        return (neg ? "-" : "") + String(mag.reversed().map { Character(String($0)) })
    }

    /// Little-endian digit values.
    private static func digits(_ s: String) -> [UInt8] {
        s.utf8.reversed().map { $0 - UInt8(ascii: "0") }
    }

    private static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        for i in stride(from: a.count - 1, through: 0, by: -1) where a[i] != b[i] {
            return a[i] < b[i] ? -1 : 1
        }
        return 0
    }

    private static func plus(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var carry: UInt8 = 0
        for i in 0..<max(a.count, b.count) {
            let s = (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0) + carry
            out.append(s % 10)
            carry = s / 10
        }
        if carry > 0 { out.append(carry) }
        return out
    }

    /// a - b with a >= b.
    private static func minus(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var borrow: Int = 0
        for i in 0..<a.count {
            var d = Int(a[i]) - borrow - Int(i < b.count ? b[i] : 0)
            borrow = d < 0 ? 1 : 0
            if d < 0 { d += 10 }
            out.append(UInt8(d))
        }
        return out
    }
}
