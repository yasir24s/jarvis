import Foundation

// Python-compatible JSON (plan: M01 §3.1, plus the M00 §3.6 `ensureASCII:` option).
// `PyJSON.loads` accepts exactly what `json.load(open(path))` accepts; `PyJSON.dumps` is
// byte-identical to `json.dumps(v)` / `json.dumps(v, indent=n)` / `json.dumps(v,
// ensure_ascii=False)`. Proven against Python by the `pyjson` golden suite.

// MARK: - Value model

public indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)          // integer literal that fits Int64
    case bigInt(String)      // integer literal outside Int64, kept as its literal digits (§8 R7)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// Structural equality. Strings and keys compare code point by code point (Python `==`),
/// never with Swift's canonical equivalence; objects compare member by member, in order.
extension JSONValue: Equatable {
    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.bigInt(x), .bigInt(y)): return pyStringEqual(x, y)
        case let (.double(x), .double(y)): return x == y
        case let (.string(x), .string(y)): return pyStringEqual(x, y)
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)): return x == y
        default: return false
        }
    }
}

/// Python `str ==`: equal code point sequences. Equal UTF-8 bytes ⇔ equal scalars.
@inline(__always)
func pyStringEqual(_ a: String, _ b: String) -> Bool {
    a.utf8.elementsEqual(b.utf8)
}

/// An insertion-ordered object with Python `dict` semantics: assigning an existing key
/// replaces its value in place, a new key appends, a removed key re-inserts at the end.
public struct JSONObject: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public var key: String
        public var value: JSONValue
        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
        public static func == (a: Member, b: Member) -> Bool {
            pyStringEqual(a.key, b.key) && a.value == b.value
        }
    }

    public private(set) var members: [Member]      // insertion order == Python dict order

    /// `dict(pairs)`: a repeated key keeps its first position and takes the last value.
    public init(_ members: [Member] = []) {
        self.members = []
        self.members.reserveCapacity(members.count)
        for m in members { self[m.key] = m.value }
    }

    /// Parser fast path: the caller guarantees the keys are already unique.
    init(uniqueMembers: [Member]) {
        self.members = uniqueMembers
    }

    private func index(of key: String) -> Int? {
        members.firstIndex { pyStringEqual($0.key, key) }
    }

    /// Get: `d.get(key)`. Set: `d[key] = v` (nil deletes, like `del d[key]`).
    public subscript(key: String) -> JSONValue? {
        get { index(of: key).map { members[$0].value } }
        set {
            if let i = index(of: key) {
                if let v = newValue { members[i].value = v } else { members.remove(at: i) }
            } else if let v = newValue {
                members.append(Member(key: key, value: v))
            }
        }
    }

    /// `d.setdefault(key, v)`: returns the existing value, or appends `v` and returns it.
    @discardableResult
    public mutating func setDefault(_ key: String, _ v: JSONValue) -> JSONValue {
        if let i = index(of: key) { return members[i].value }
        members.append(Member(key: key, value: v))
        return v
    }

    /// `d.pop(key, None)`.
    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let i = index(of: key) else { return nil }
        return members.remove(at: i).value
    }

    public var keys: [String] { members.map(\.key) }
    public var count: Int { members.count }
}

public extension JSONValue {
    /// Python `bool(x)`: null/false/0/0.0/""/[]/{} → false. NaN is truthy, as in Python.
    var pyTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .bigInt: return true                       // never zero: it lies outside Int64
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return o.count > 0
        }
    }

    /// Python `float(x)` for the JSON number/bool types; nil where Python would raise, and
    /// for strings (§8 R8).
    var pyFloat: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .bigInt(let digits):
            guard let d = Double(digits), d.isFinite else { return nil }   // OverflowError
            return d
        case .double(let d): return d
        case .bool(let b): return b ? 1.0 : 0.0
        case .null, .string, .array, .object: return nil
        }
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
}

// MARK: - Errors

public enum PyJSONError: Error, Equatable {
    case invalidUTF8                                   // Python: UnicodeDecodeError
    case bom                                           // "Unexpected UTF-8 BOM"
    case syntax(offset: Int, reason: String)           // JSONDecodeError; offset in UTF-8 bytes
    case depth                                         // nesting > 512 (Python: RecursionError)
}

// MARK: - loads / dumps

public enum PyJSON {
    /// Nesting deeper than this throws `.depth` (M01 §3.1 rule 7).
    public static let maxDepth = 512
    /// CPython's `sys.int_info.default_max_str_digits`: `json.loads` raises ValueError for an
    /// integer literal with more digits than this, so native rejects it too.
    public static let maxIntDigits = 4300

    /// `json.load(open(path))`: strict UTF-8, no BOM, then `json.loads` (strict mode).
    public static func loads(_ data: Data) throws(PyJSONError) -> JSONValue {
        guard String(validating: data, as: UTF8.self) != nil else { throw .invalidUTF8 }
        let bytes = [UInt8](data)
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            throw .bom
        }
        var p = Parser(b: bytes)
        return try p.parseDocument()
    }

    /// `json.dumps(v)` (indent nil: separators ", " and ": "), `json.dumps(v, indent=n)`
    /// (item separator "," + newline + n*level spaces), and `ensure_ascii=False` when
    /// `ensureASCII` is false. allow_nan=True, no key sorting, no trailing newline.
    public static func dumps(_ v: JSONValue, indent: Int? = nil, ensureASCII: Bool = true) -> String {
        var w = Writer(indent: indent.map { max(0, $0) }, ascii: ensureASCII)
        w.write(v, level: 0)
        return String(decoding: w.out, as: UTF8.self)
    }
}

// MARK: - Float repr

public enum PyFloat {
    /// Python `float.__repr__` ('r' mode: shortest round-trip digits; fixed notation iff
    /// -4 < decpt <= 16; integral values keep ".0"; exponents are signed, at least 2 digits).
    /// Non-finite values give Python's repr ("nan", "inf", "-inf"); the JSON writer spells
    /// them NaN / Infinity / -Infinity itself.
    public static func repr(_ x: Double) -> String {
        if x.isNaN { return "nan" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
        let (digits, decpt) = shortestDigits(Swift.abs(x))
        let n = digits.count
        var s = x < 0 ? "-" : ""
        if -4 < decpt && decpt <= 16 {
            if decpt <= 0 {
                s += "0." + String(repeating: "0", count: -decpt) + digits
            } else if decpt >= n {
                s += digits + String(repeating: "0", count: decpt - n) + ".0"
            } else {
                let cut = digits.index(digits.startIndex, offsetBy: decpt)
                s += digits[..<cut] + "." + digits[cut...]
            }
        } else {
            let first = digits.prefix(1)
            s += first
            if n > 1 { s += "." + digits.dropFirst() }
            let e = decpt - 1
            s += e < 0 ? "e-" : "e+"
            let mag = String(Swift.abs(e))
            s += mag.count < 2 ? "0" + mag : mag
        }
        return s
    }

    /// Shortest round-trip digits of a positive finite `x` (SwiftDtoa, via `description`),
    /// as a digit string D without leading/trailing zeros and `decpt` with x = 0.D × 10^decpt.
    /// Only the digits are taken from Swift; its exponent threshold is not used.
    static func shortestDigits(_ x: Double) -> (String, Int) {
        let text = x.description
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...])!
        }
        var intPart = mantissa
        var fracPart: Substring = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = mantissa[..<dot]
            fracPart = mantissa[mantissa.index(after: dot)...]
        }
        var digits = Array((intPart + fracPart).utf8)
        var decpt = intPart.count + exponent
        var lead = 0
        while lead < digits.count && digits[lead] == UInt8(ascii: "0") { lead += 1 }
        digits.removeFirst(lead)
        decpt -= lead
        while let last = digits.last, last == UInt8(ascii: "0") { digits.removeLast() }
        return (String(decoding: digits, as: UTF8.self), decpt)
    }
}

// MARK: - Parser (iterative, so 512 levels never touch a small thread stack)

private struct Parser {
    let b: [UInt8]
    var i = 0

    init(b: [UInt8]) { self.b = b }

    private enum Frame {
        case array([JSONValue])
        case object([JSONObject.Member], [[UInt8]: Int], key: [UInt8], keyString: String)
    }

    private func fail(_ reason: String, at offset: Int? = nil) -> PyJSONError {
        .syntax(offset: offset ?? i, reason: reason)
    }

    @inline(__always) private static func isWS(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D           // exactly [ \t\n\r]
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    private mutating func skipWS() {
        while i < b.count && Parser.isWS(b[i]) { i += 1 }
    }

    mutating func parseDocument() throws(PyJSONError) -> JSONValue {
        var stack: [Frame] = []
        skipWS()
        next: while true {
            // A value starts at i.
            var value: JSONValue
            guard i < b.count else { throw fail("Expecting value") }
            switch b[i] {
            case UInt8(ascii: "["):
                if stack.count >= PyJSON.maxDepth { throw .depth }
                i += 1
                skipWS()
                if i < b.count && b[i] == UInt8(ascii: "]") {
                    i += 1
                    value = .array([])
                } else {
                    stack.append(.array([]))
                    continue next
                }
            case UInt8(ascii: "{"):
                if stack.count >= PyJSON.maxDepth { throw .depth }
                i += 1
                skipWS()
                if i < b.count && b[i] == UInt8(ascii: "}") {
                    i += 1
                    value = .object(JSONObject())
                } else {
                    let (kb, ks) = try parseKey()
                    stack.append(.object([], [:], key: kb, keyString: ks))
                    continue next
                }
            default:
                value = try parseScalar()
            }
            // The value is complete: fold it into the enclosing containers.
            while true {
                guard let top = stack.popLast() else {
                    skipWS()
                    if i != b.count { throw fail("Extra data") }
                    return value
                }
                skipWS()
                switch top {
                case .array(var items):
                    items.append(value)
                    guard i < b.count else { throw fail("Expecting ',' delimiter") }
                    if b[i] == UInt8(ascii: ",") {
                        i += 1
                        skipWS()
                        stack.append(.array(items))
                        continue next
                    }
                    guard b[i] == UInt8(ascii: "]") else { throw fail("Expecting ',' delimiter") }
                    i += 1
                    value = .array(items)
                case .object(var members, var index, let kb, let ks):
                    if let j = index[kb] {
                        members[j].value = value           // last value wins, first slot kept
                    } else {
                        index[kb] = members.count
                        members.append(JSONObject.Member(key: ks, value: value))
                    }
                    guard i < b.count else { throw fail("Expecting ',' delimiter") }
                    if b[i] == UInt8(ascii: ",") {
                        i += 1
                        skipWS()
                        let (nkb, nks) = try parseKey()
                        stack.append(.object(members, index, key: nkb, keyString: nks))
                        continue next
                    }
                    guard b[i] == UInt8(ascii: "}") else { throw fail("Expecting ',' delimiter") }
                    i += 1
                    value = .object(JSONObject(uniqueMembers: members))
                }
            }
        }
    }

    /// `"key"` ws `:` ws — leaves i at the start of the member's value.
    private mutating func parseKey() throws(PyJSONError) -> ([UInt8], String) {
        guard i < b.count && b[i] == UInt8(ascii: "\"") else {
            throw fail("Expecting property name enclosed in double quotes")
        }
        let bytes = try parseStringBytes()
        skipWS()
        guard i < b.count && b[i] == UInt8(ascii: ":") else { throw fail("Expecting ':' delimiter") }
        i += 1
        skipWS()
        return (bytes, String(decoding: bytes, as: UTF8.self))
    }

    private mutating func literal(_ word: String, _ v: JSONValue) throws(PyJSONError) -> JSONValue {
        let w = Array(word.utf8)
        guard i + w.count <= b.count && b[i..<(i + w.count)].elementsEqual(w) else {
            throw fail("Expecting value")
        }
        i += w.count
        return v
    }

    private mutating func parseScalar() throws(PyJSONError) -> JSONValue {
        switch b[i] {
        case UInt8(ascii: "\""): return .string(String(decoding: try parseStringBytes(), as: UTF8.self))
        case UInt8(ascii: "n"): return try literal("null", .null)
        case UInt8(ascii: "t"): return try literal("true", .bool(true))
        case UInt8(ascii: "f"): return try literal("false", .bool(false))
        case UInt8(ascii: "N"): return try literal("NaN", .double(.nan))
        case UInt8(ascii: "I"): return try literal("Infinity", .double(.infinity))
        case UInt8(ascii: "-") where i + 1 < b.count && b[i + 1] == UInt8(ascii: "I"):
            return try literal("-Infinity", .double(-.infinity))
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            return try parseNumber()
        default:
            throw fail("Expecting value")
        }
    }

    /// CPython `_match_number_unicode`: -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][-+]?[0-9]+)?, where a
    /// '.' or exponent that is not followed by digits is left unconsumed (then "Extra data").
    private mutating func parseNumber() throws(PyJSONError) -> JSONValue {
        let start = i
        if b[i] == UInt8(ascii: "-") { i += 1 }
        guard i < b.count else { throw fail("Expecting value", at: start) }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if b[i] >= UInt8(ascii: "1") && b[i] <= UInt8(ascii: "9") {
            i += 1
            while i < b.count && Parser.isDigit(b[i]) { i += 1 }
        } else {
            throw fail("Expecting value", at: start)
        }
        var isFloat = false
        if i + 1 < b.count && b[i] == UInt8(ascii: ".") && Parser.isDigit(b[i + 1]) {
            isFloat = true
            i += 2
            while i < b.count && Parser.isDigit(b[i]) { i += 1 }
        }
        if i < b.count && (b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E")) {
            let eStart = i
            i += 1
            if i < b.count && (b[i] == UInt8(ascii: "-") || b[i] == UInt8(ascii: "+")) { i += 1 }
            let digitsStart = i
            while i < b.count && Parser.isDigit(b[i]) { i += 1 }
            if i > digitsStart { isFloat = true } else { i = eStart }
        }
        let text = String(decoding: b[start..<i], as: UTF8.self)
        if isFloat {
            // Correctly rounded, like Python's float(): 1e400 → inf, 1e-400 → 0.0.
            guard let d = Double(text) else { throw fail("Invalid number", at: start) }
            return .double(d)
        }
        let digitCount = i - start - (b[start] == UInt8(ascii: "-") ? 1 : 0)
        if digitCount > PyJSON.maxIntDigits {
            throw fail("Exceeds the limit (4300 digits) for integer string conversion", at: start)
        }
        if let v = Int64(text) { return .int(v) }                   // "-0" → 0
        return .bigInt(text)
    }

    private func hex4(at j: Int) -> UInt32? {
        guard j + 4 <= b.count else { return nil }
        var v: UInt32 = 0
        for k in j..<(j + 4) {
            let c = b[k]
            let d: UInt8
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = c - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = c - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = c - UInt8(ascii: "A") + 10
            default: return nil
            }
            v = v << 4 | UInt32(d)
        }
        return v
    }

    /// The decoded UTF-8 bytes of the string starting at the opening quote at i.
    private mutating func parseStringBytes() throws(PyJSONError) -> [UInt8] {
        let start = i
        i += 1
        var out: [UInt8] = []
        while true {
            guard i < b.count else { throw fail("Unterminated string starting at", at: start) }
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                i += 1
                return out
            }
            if c < 0x20 { throw fail("Invalid control character at") }
            if c != UInt8(ascii: "\\") {
                out.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < b.count else { throw fail("Unterminated string starting at", at: start) }
            switch b[i] {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard var cp = hex4(at: i + 1) else { throw fail("Invalid \\uXXXX escape", at: i - 1) }
                i += 5
                if (0xD800...0xDBFF).contains(cp) && i + 1 < b.count
                    && b[i] == UInt8(ascii: "\\") && b[i + 1] == UInt8(ascii: "u") {
                    guard let low = hex4(at: i + 2) else { throw fail("Invalid \\uXXXX escape", at: i) }
                    if (0xDC00...0xDFFF).contains(low) {
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
                        i += 6
                    }
                }
                // A lone surrogate cannot live in a Swift String: U+FFFD (M01 §8 R6).
                if (0xD800...0xDFFF).contains(cp) { cp = 0xFFFD }
                UTF8.encode(Unicode.Scalar(cp)!) { out.append($0) }
                continue
            default:
                throw fail("Invalid \\escape", at: i - 1)
            }
            i += 1
        }
    }
}

// MARK: - Writer

private struct Writer {
    let indent: Int?
    let ascii: Bool
    var out: [UInt8] = []

    private static let hex = Array("0123456789abcdef".utf8)

    private mutating func put(_ s: String) { out.append(contentsOf: s.utf8) }

    private mutating func newline(level: Int) {
        out.append(0x0A)
        out.append(contentsOf: repeatElement(0x20, count: level * indent!))
    }

    private enum Frame {
        case array([JSONValue], next: Int, level: Int)
        case object([JSONObject.Member], next: Int, level: Int)
    }

    /// Iterative, like the parser: a 512-deep value must not recurse on a small stack.
    mutating func write(_ root: JSONValue, level rootLevel: Int) {
        var stack: [Frame] = []
        var pending: JSONValue? = root
        var level = rootLevel
        while true {
            if let v = pending {
                pending = nil
                switch v {
                case .array(let items) where !items.isEmpty:
                    out.append(UInt8(ascii: "["))
                    stack.append(.array(items, next: 0, level: level))
                case .object(let o) where o.count > 0:
                    out.append(UInt8(ascii: "{"))
                    stack.append(.object(o.members, next: 0, level: level))
                default:
                    writeLeaf(v)
                }
            }
            guard let top = stack.popLast() else { return }
            switch top {
            case let .array(items, next, lvl):
                if next == items.count {
                    if indent != nil { newline(level: lvl) }
                    out.append(UInt8(ascii: "]"))
                    continue
                }
                separator(first: next == 0, level: lvl + 1)
                stack.append(.array(items, next: next + 1, level: lvl))
                pending = items[next]
                level = lvl + 1
            case let .object(members, next, lvl):
                if next == members.count {
                    if indent != nil { newline(level: lvl) }
                    out.append(UInt8(ascii: "}"))
                    continue
                }
                separator(first: next == 0, level: lvl + 1)
                writeString(members[next].key)
                put(": ")
                stack.append(.object(members, next: next + 1, level: lvl))
                pending = members[next].value
                level = lvl + 1
            }
        }
    }

    /// Before an item: "," + newline + indent (indent mode) or ", " (compact).
    private mutating func separator(first: Bool, level: Int) {
        if indent != nil {
            if !first { out.append(UInt8(ascii: ",")) }
            newline(level: level)
        } else if !first {
            put(", ")
        }
    }

    /// Scalars and empty containers.
    private mutating func writeLeaf(_ v: JSONValue) {
        switch v {
        case .null: put("null")
        case .bool(let b): put(b ? "true" : "false")
        case .int(let i): put(String(i))
        case .bigInt(let digits): put(digits)
        case .double(let d):
            if d.isNaN { put("NaN") }
            else if d.isInfinite { put(d < 0 ? "-Infinity" : "Infinity") }
            else { put(PyFloat.repr(d)) }
        case .string(let s): writeString(s)
        case .array: put("[]")
        case .object: put("{}")
        }
    }

    private mutating func escapeUnit(_ u: UInt32) {
        out.append(contentsOf: [0x5C, UInt8(ascii: "u"),
                                Writer.hex[Int(u >> 12 & 0xF)], Writer.hex[Int(u >> 8 & 0xF)],
                                Writer.hex[Int(u >> 4 & 0xF)], Writer.hex[Int(u & 0xF)]])
    }

    /// ensure_ascii=True: CPython ESCAPE_ASCII, i.e. everything outside U+0020…U+007E except
    /// the short escapes becomes \u%04x (DEL included; astral → surrogate pair). "/" is never
    /// escaped. ensure_ascii=False: only '"', '\\' and U+0000…U+001F are escaped.
    private mutating func writeString(_ s: String) {
        out.append(0x22)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x20...0x7E: out.append(UInt8(v))
            case 0x00..<0x20: escapeUnit(v)
            default:
                if !ascii {
                    UTF8.encode(scalar) { out.append($0) }
                } else if v >= 0x10000 {
                    let w = v - 0x10000
                    escapeUnit(0xD800 | (w >> 10))
                    escapeUnit(0xDC00 | (w & 0x3FF))
                } else {
                    escapeUnit(v)
                }
            }
        }
        out.append(0x22)
    }
}
