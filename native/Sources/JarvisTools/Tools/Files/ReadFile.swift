import Darwin
import Foundation
import JarvisCore

/// `read_file` (plan: M05-M06 §2a, §3.5, A-FILE-2). Python's `_read_file` (jarvis.py 2823-2833):
/// `open(os.path.expanduser(path.strip()), "r", errors="ignore").read(4000)`, "(file is empty)"
/// for no text, and every failure, `.strip()` on a non-str included, as
/// `f"Could not read {path}: {e}"`. No path guard: D-11 turned X-5 off (the user's full read
/// access), so, as in Python, the control is the taint the gateway sets after the call
/// (TaintPolicy.untrusted), which blocks every executor for the rest of the turn.
struct ReadFile: ToolImpl {
    static let name = "read_file"
    static let schema = BuiltInTools.catalogSchema(named: name)
    /// `f.read(4000)`: code points, after newline translation.
    static let limit = 4000
    /// TextIOWrapper's chunk size; the decoder carries partial sequences across chunks.
    static let chunk = 8192

    /// `$HOME`, which `expanduser("~...")` reads.
    let home: String
    /// `pwd.getpwnam(name).pw_dir` for `~name`, nil for no such user.
    var userHome: @Sendable (String) -> String? = ReadFile.passwdHome
    /// P4: the screen tools' recogniser, for a scanned PDF (`ScannedPDF`), and its time limit.
    var recognizer: any TextRecognizing = VisionTextRecognizer()
    var ocrTimeout: Duration = ScannedPDF.timeout

    /// A PDF with no text layer is read by OCR (P4, native-only); everything else as Python's
    /// `_read_file` reads it.
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        if let raw = args["path"]?.stringValue, let path = expanduser(Py.strip(raw)),
           let text = await ScannedPDF.ocr(path: path, recognizer: recognizer, timeout: ocrTimeout) {
            return .text(text)
        }
        return .text(read(args["path"]))
    }

    func read(_ argument: JSONValue?) -> String {
        // args.get("path", ""): missing is "", a str is itself, anything else fails `.strip()`
        // inside the try, and the message shows the argument as `str()` prints it.
        guard let raw = argument == nil ? "" : argument?.stringValue else {
            return "Could not read \(PyArgs.str(argument)): \(PyError.noAttribute(argument, "strip"))"
        }
        let stripped = Py.strip(raw)
        guard let path = expanduser(stripped) else {
            return "Could not read \(raw): embedded null byte"   // pwd.getpwnam raised; path is still the argument
        }
        return Self.contents(of: path)
    }

    /// `posixpath.expanduser`: "~" or "~/..." takes `$HOME`, "~name/..." the user's passwd
    /// home (unchanged when there is no such user); the home loses trailing "/" and the result
    /// is `(home + rest) or "/"`. Nil where `getpwnam` raises (a NUL in the name).
    func expanduser(_ path: String) -> String? {
        let u = Array(path.unicodeScalars)
        guard u.first == "~" else { return path }
        let slash = u.dropFirst().firstIndex(of: "/") ?? u.count
        let userhome: String
        if slash == 1 {
            userhome = home
        } else {
            let name = String(String.UnicodeScalarView(u[1..<slash]))
            if name.unicodeScalars.contains("\0") { return nil }
            guard let found = userHome(name) else { return path }
            userhome = found
        }
        let joined = Py.rstrip(userhome, "/") + String(String.UnicodeScalarView(u[slash...]))
        return joined.isEmpty ? "/" : joined
    }

    static let passwdHome: @Sendable (String) -> String? = { name in
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        guard getpwnam_r(name, &entry, &buffer, buffer.count, &result) == 0, result != nil,
              let dir = entry.pw_dir else { return nil }
        return String(cString: dir)
    }

    /// Python's `open(path, "r", errors="ignore")` then `read(4000)`, or its error text.
    static func contents(of path: String) -> String {
        if path.unicodeScalars.contains("\0") { return "Could not read \(path): embedded null byte" }
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return failure(path, errno, filename: true) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            return failure(path, EISDIR, filename: true)      // io.FileIO refuses a directory
        }
        var decoder = IgnoringUTF8Decoder(limit: limit)
        var buffer = [UInt8](repeating: 0, count: chunk)
        while !decoder.full {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return failure(path, errno, filename: false)  // a read error carries no filename
            }
            if count == 0 { decoder.finish(); break }
            decoder.feed(buffer[0..<count])
        }
        let text = decoder.text
        return text.isEmpty ? "(file is empty)" : text
    }

    /// `f"Could not read {path}: {e}"` for an `OSError`: "[Errno N] strerror", plus
    /// ": <repr(filename)>" when the error carries the filename (open does, read does not).
    static func failure(_ path: String, _ code: Int32, filename: Bool) -> String {
        let base = "[Errno \(code)] \(String(cString: strerror(code)))"
        return "Could not read \(path): " + (filename ? base + ": " + PyRepr.string(path) : base)
    }
}

/// CPython's UTF-8 decoder with `errors="ignore"` behind a universal-newline reader, fed in
/// chunks: each invalid sequence is skipped over exactly the bytes CPython's error covers (one
/// for an invalid start byte, the lead and its valid continuations for an invalid
/// continuation, the rest for a sequence cut off at end of file), an incomplete sequence at a
/// chunk end waits for the next chunk, and "\r\n" or a lone "\r" becomes "\n" even when the
/// pair is split. Stops once `limit` code points are out.
struct IgnoringUTF8Decoder {
    let limit: Int
    private(set) var scalars = String.UnicodeScalarView()
    private var count = 0
    private var pending: [UInt8] = []
    private var afterCR = false

    init(limit: Int) { self.limit = limit }

    var full: Bool { count >= limit }
    var text: String { String(scalars) }

    mutating func feed(_ bytes: ArraySlice<UInt8>) {
        pending.append(contentsOf: bytes)
        drain(final: false)
    }

    mutating func finish() {
        drain(final: true)
    }

    private mutating func drain(final: Bool) {
        let b = pending
        var i = 0
        decoding: while i < b.count, !full {
            let c = b[i]
            var need = 0, low: UInt8 = 0x80, high: UInt8 = 0xBF
            switch c {
            case 0x00...0x7F: emit(UInt32(c)); i += 1; continue
            case 0xC2...0xDF: need = 1
            case 0xE0: need = 2; low = 0xA0
            case 0xED: need = 2; high = 0x9F
            case 0xE1...0xEC, 0xEE, 0xEF: need = 2
            case 0xF0: need = 3; low = 0x90
            case 0xF4: need = 3; high = 0x8F
            case 0xF1...0xF3: need = 3
            default: i += 1; continue                         // invalid start byte: skip it
            }
            var value = UInt32(c) & (need == 1 ? 0x1F : need == 2 ? 0x0F : 0x07)
            for k in 1...need {
                let j = i + k
                if j >= b.count {
                    if final { i = b.count } else { break decoding }   // cut off: drop at EOF, else wait
                    continue decoding
                }
                let ok = k == 1 ? (b[j] >= low && b[j] <= high) : (b[j] >= 0x80 && b[j] <= 0xBF)
                if !ok { i += k; continue decoding }          // invalid continuation: skip the prefix
                value = value << 6 | UInt32(b[j] & 0x3F)
            }
            emit(value)
            i += need + 1
        }
        pending = full ? [] : Array(b[i...])
    }

    private mutating func emit(_ value: UInt32) {
        if value == 0x0A && afterCR {                         // the "\n" of a "\r\n" already out
            afterCR = false
            return
        }
        afterCR = value == 0x0D
        scalars.append(afterCR ? "\n" : Unicode.Scalar(value)!)
        count += 1
    }
}
