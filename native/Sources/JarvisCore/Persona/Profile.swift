import Foundation

// profile.json (plan: M01 §2.4, §3.7). Mirrors jarvis.py profile_load, profile_remember,
// profile_forget, profile_context, _PROFILE_PATTERNS / _FORGET_ALL_RE / _FORGET_ONE_RE and
// maybe_learn_profile; proven against Python by the `m1_profile_kb` golden suite.
//
// The pure functions work on the loaded object. The `store:` overloads wrap them in Python's
// load → modify → save order (Python holds _profile_lock across it; native callers run inside
// CoreState). The file is re-read on every use, as in Python. None of these functions bumps a
// research counter.

public enum ProfileLogic {
    /// `{"facts": {}}`, what profile_load returns when `json.load` raises.
    public static func empty() -> JSONObject {
        JSONObject([JSONObject.Member(key: "facts", value: .object(JSONObject()))])
    }

    /// `profile_load`: whatever `json.load` returned, else `{"facts": {}}` (`raw` is nil when
    /// Python's `json.load` would raise). A parseable non-dict throws: every profile_* caller
    /// then raises in Python (`setdefault` / `.get` on a list, str, number or None).
    public static func load(_ raw: JSONValue?) throws(StateShapeError) -> JSONObject {
        guard let raw else { return empty() }
        guard case .object(let p) = raw else { throw shape("profile.json is not a dict (AttributeError)") }
        return p
    }

    /// profile_remember's cleaning: key `strip().lower()[:60]`, value `strip().rstrip(" .")`;
    /// nil when either is empty (Python returns before loading the file).
    public static func clean(key: String, value: String) -> (key: String, value: String)? {
        let k = Py.prefix(Py.lower(Py.strip(key)), 60)
        let v = Py.rstrip(Py.strip(value), " .")
        return k.isEmpty || v.isEmpty ? nil : (k, v)
    }

    /// `profile_remember` on a loaded object: `setdefault("facts", {})[key] = {"value":
    /// value[:300], "updated": now}` (a replaced key keeps its position). False = skipped: `p`
    /// is untouched and Python does not save. Throws where Python raises (non-dict "facts").
    public static func remember(key: String, value: String, in p: inout JSONObject,
                                now: Double) throws(StateShapeError) -> Bool {
        guard let c = clean(key: key, value: value) else { return false }
        guard case .object(var facts) = p.setDefault("facts", .object(JSONObject())) else {
            throw shape("\"facts\" is not a dict (TypeError)")
        }
        facts[c.key] = .object(JSONObject([JSONObject.Member(key: "value", value: .string(Py.prefix(c.value, 300))),
                                       JSONObject.Member(key: "updated", value: .double(now))]))
        p["facts"] = .object(facts)
        return true
    }

    /// `profile_forget(match)` on a loaded object: nil clears every fact, otherwise the facts
    /// whose key contains `matching` (code-point substring) are dropped. Always followed by a
    /// save. Throws where Python raises; a non-dict "facts" is handled as Python's list / str
    /// operations would (`clear()` empties a list; an unmatched scan changes nothing).
    public static func forget(matching: String?, in p: inout JSONObject) throws(StateShapeError) {
        let facts = p.setDefault("facts", .object(JSONObject()))
        guard let match = matching else {
            switch facts {
            case .object: p["facts"] = .object(JSONObject())
            case .array: p["facts"] = .array([])
            default: throw shape("\"facts\" has no clear() (AttributeError)")
            }
            return
        }
        switch facts {
        case .object(var o):
            for k in o.keys where Py.contains(k, match) { o.removeValue(forKey: k) }
            p["facts"] = .object(o)
        case .array(let a):
            // `[k for k in facts if match in k]`, then `facts.pop(k, None)` (a TypeError on a list).
            for e in a {
                if try PyObjects.contains(e, match) { throw shape("\"facts\" is a list: pop(k, None) (TypeError)") }
            }
        case .string(let s):
            for c in s.unicodeScalars where Py.contains(String(c), match) {
                throw shape("\"facts\" is a str: no pop() (AttributeError)")
            }
        default:
            throw shape("\"facts\" is not iterable (TypeError)")
        }
    }

    /// `profile_context()`: the 12 newest facts (by "updated", ties in file order) as
    /// `" What you know about the user — k: value; …"`, or "" when there are none.
    public static func context(_ p: JSONObject) throws(StateShapeError) -> String {
        let facts = p["facts"] ?? .object(JSONObject())
        if !facts.pyTruthy { return "" }
        guard case .object(let o) = facts else { throw shape("\"facts\" has no items() (AttributeError)") }
        let items = try PyObjects.sortedByUpdated(o, reverse: true, file: .profile)
        var parts: [String] = []
        for m in items.prefix(12) {
            guard case .object(let v) = m.value, let value = v["value"] else {
                throw shape("a fact has no \"value\" (KeyError)")
            }
            parts.append("\(m.key): \(PyObjects.str(value))")
        }
        return " What you know about the user — " + parts.joined(separator: "; ")
    }

    // MARK: - maybe_learn_profile

    public enum Action: Equatable, Sendable {
        case forgetAll
        case forget(String)
        case remember(key: String, value: String)
    }

    public struct Pattern: Sendable {
        public let regex: PyRegex
        /// The fixed key; nil for the dynamic "my X is Y" row (the key is group 1).
        public let key: String?
    }

    /// `_PROFILE_PATTERNS`, in order (the first match wins).
    public static let patterns: [Pattern] = [
        (#"\bmy name(?:'s| is)\s+([a-z][\w '-]{1,40})"#, "name"),
        (#"\bcall me\s+([a-z][\w '-]{1,40})"#, "name"),
        (#"\bi(?:'m| am) working on\s+(.+)"#, "current project"),
        (#"\bi(?:'m| am) an?\s+([\w '-]{2,40})"#, "role"),
        (#"\bi (?:prefer|really like|love)\s+(.+)"#, "preference"),
        (#"\bremember that\s+(.+)"#, "note"),
        (#"\bmy (\w[\w ]{1,20}?) is\s+(.+)"#, nil),
    ].map { Pattern(regex: compile($0.0), key: $0.1) }

    /// `_FORGET_ALL_RE`.
    public static let forgetAllPattern = compile(
        #"\b(forget everything (?:about me|you know about me)|clear my profile|wipe my profile)\b"#)
    /// `_FORGET_ONE_RE`.
    public static let forgetOnePattern = compile(
        #"\bforget (?:that |what you know )?(?:about )?my (\w[\w ]{0,30})\b"#)

    /// `maybe_learn_profile`'s decision: nil for a blank text or no match; forget-all; forget
    /// one (`g1.strip().lower()`); else the first pattern's (key, value) before
    /// profile_remember's own cleaning. The dynamic key is `g1.strip()`, not lowercased here.
    public static func action(for text: String) -> Action? {
        let t = Py.strip(text)
        if t.isEmpty { return nil }
        if forgetAllPattern.search(t) != nil { return .forgetAll }
        if let m = forgetOnePattern.search(t) {
            return .forget(Py.lower(Py.strip(m.groups[1] ?? "")))
        }
        for p in patterns {
            guard let m = p.regex.search(t) else { continue }
            if let key = p.key { return .remember(key: key, value: m.groups[1] ?? "") }
            return .remember(key: Py.strip(m.groups[1] ?? ""), value: m.groups[2] ?? "")
        }
        return nil
    }

    // MARK: - Helpers

    private static func compile(_ pattern: String) -> PyRegex {
        do { return try PyRegex(pattern, ignoreCase: true) } catch {
            preconditionFailure("ProfileLogic: \(error)")
        }
    }

    private static func shape(_ detail: String) -> StateShapeError {
        StateShapeError(file: .profile, detail: detail)
    }
}

// MARK: - The Python functions, with their file IO

public extension ProfileLogic {
    /// `profile_remember(key, value)`: saves only when both survive cleaning.
    static func remember(key: String, value: String, store: StateStore, now: Double) throws(StateShapeError) {
        guard clean(key: key, value: value) != nil else { return }
        var p = try load(store.load(.profile))
        if try remember(key: key, value: value, in: &p, now: now) {
            store.save(.profile, .object(p))
        }
    }

    /// `profile_forget(match)`: always saves, even when nothing changed.
    static func forget(matching: String?, store: StateStore) throws(StateShapeError) {
        var p = try load(store.load(.profile))
        try forget(matching: matching, in: &p)
        store.save(.profile, .object(p))
    }

    /// `profile_context()`.
    static func context(store: StateStore) throws(StateShapeError) -> String {
        try context(load(store.load(.profile)))
    }

    /// `maybe_learn_profile(text)`.
    static func maybeLearn(_ text: String, store: StateStore, now: Double) throws(StateShapeError) {
        switch action(for: text) {
        case .forgetAll?: try forget(matching: nil, store: store)
        case .forget(let match)?: try forget(matching: match, store: store)
        case .remember(let key, let value)?: try remember(key: key, value: value, store: store, now: now)
        case nil: break
        }
    }
}

// MARK: - Python object semantics shared by ProfileLogic and KnowledgeLogic

enum PyObjects {
    /// `str(v)` for a JSON value, as an f-string field formats it.
    static func str(_ v: JSONValue) -> String {
        if case .string(let s) = v { return s }
        return repr(v)
    }

    /// `repr(v)`: None/True/False, ints, float repr, and str/list/dict reprs.
    static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .bigInt(let digits): return digits
        case .double(let d): return PyFloat.repr(d)
        case .string(let s): return reprString(s)
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o):
            return "{" + o.members.map { reprString($0.key) + ": " + repr($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// `repr(s)` for a str: single quotes unless the text has ' and no ", then CPython's
    /// escapes (\\ \t \n \r, \xNN below 0x20 and 0x7F, non-printables as \x / \u / \U).
    static func reprString(_ s: String) -> String {
        let quote: Unicode.Scalar = s.unicodeScalars.contains("'") && !s.unicodeScalars.contains("\"") ? "\"" : "'"
        var out = String.UnicodeScalarView()
        out.append(quote)
        for c in s.unicodeScalars {
            switch c {
            case quote, "\\": out.append("\\"); out.append(c)
            case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
            case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
            default:
                if c.value < 0x20 || c.value == 0x7F {
                    out.append(contentsOf: hex(c.value, "x", 2).unicodeScalars)
                } else if c.value < 0x7F || isPrintable(c) {
                    out.append(c)
                } else if c.value <= 0xFF {
                    out.append(contentsOf: hex(c.value, "x", 2).unicodeScalars)
                } else if c.value <= 0xFFFF {
                    out.append(contentsOf: hex(c.value, "u", 4).unicodeScalars)
                } else {
                    out.append(contentsOf: hex(c.value, "U", 8).unicodeScalars)
                }
            }
        }
        out.append(quote)
        return String(out)
    }

    /// `str.isprintable()` for one non-ASCII scalar: not Cc, Cf, Cs, Co, Cn, Zl, Zp or Zs.
    private static func isPrintable(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            false
        default:
            true
        }
    }

    private static func hex(_ v: UInt32, _ tag: String, _ width: Int) -> String {
        let digits = String(v, radix: 16)
        return "\\" + tag + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// `needle in x` for one element of a scanned container, where `needle` is a str: a str
    /// is a substring test, a list an equality scan, a dict a key test; numbers, bools and
    /// None raise TypeError.
    static func contains(_ x: JSONValue, _ needle: String) throws(StateShapeError) -> Bool {
        switch x {
        case .string(let s): return Py.contains(s, needle)
        case .array(let a): return a.contains(.string(needle))
        case .object(let o): return o[needle] != nil
        default: throw StateShapeError(file: .profile, detail: "'in' on a non-container (TypeError)")
        }
    }

    /// `sorted(d.items(), key=lambda kv: kv[1].get("updated", 0), reverse=reverse)`: stable,
    /// so ties keep dict order in both directions. Every value must be a dict (the key calls
    /// `.get`). With two or more items the keys must be mutually orderable, as Python's `<`:
    /// all numbers (int / float / bool, exact int-float comparison) or all str (code-point
    /// order). Anything else raises TypeError in Python. NaN is rejected too: Python orders
    /// it by the accident of its timsort run, which native does not reproduce.
    static func sortedByUpdated(_ d: JSONObject, reverse: Bool,
                                file: StateFile) throws(StateShapeError) -> [JSONObject.Member] {
        var keys: [JSONValue] = []
        for m in d.members {
            guard case .object(let v) = m.value else {
                throw StateShapeError(file: file, detail: "an entry is not a dict (AttributeError)")
            }
            keys.append(v["updated"] ?? .int(0))
        }
        let members = d.members
        if members.count < 2 { return members }
        let order: [Int]
        if keys.allSatisfy({ if case .string = $0 { true } else { false } }) {
            let s = keys.map { $0.stringValue ?? "" }
            order = stableOrder(members.count, reverse: reverse) { PyStr.less(s[$0], s[$1]) }
        } else {
            var n: [Num] = []
            for k in keys {
                guard let x = Num(k) else {
                    throw StateShapeError(file: file, detail: "\"updated\" values are not mutually orderable (TypeError)")
                }
                n.append(x)
            }
            order = stableOrder(members.count, reverse: reverse) { Num.less(n[$0], n[$1]) }
        }
        return order.map { members[$0] }
    }

    /// Indices in `sorted(..., reverse=reverse)` order: by key, ties by position.
    private static func stableOrder(_ count: Int, reverse: Bool, less: (Int, Int) -> Bool) -> [Int] {
        Array(0..<count).sorted { a, b in
            let (x, y) = reverse ? (b, a) : (a, b)
            if less(x, y) { return true }
            if less(y, x) { return false }
            return a < b
        }
    }

    /// A JSON number as Python compares it.
    private enum Num {
        case int(Int64)
        case double(Double)

        init?(_ v: JSONValue) {
            switch v {
            case .int(let i): self = .int(i)
            case .bool(let b): self = .int(b ? 1 : 0)
            case .double(let d) where !d.isNaN: self = .double(d)
            case .bigInt(let digits):
                // Outside Int64: ordered by its nearest double (exact enough for "updated").
                guard let d = Double(digits) else { return nil }
                self = .double(d)
            default: return nil
            }
        }

        static func less(_ a: Num, _ b: Num) -> Bool {
            switch (a, b) {
            case let (.int(x), .int(y)): return x < y
            case let (.double(x), .double(y)): return x < y
            case let (.int(x), .double(y)): return compare(x, y) < 0
            case let (.double(x), .int(y)): return compare(y, x) > 0
            }
        }

        /// Exact sign of `i - d` for a non-NaN double, as CPython's int/float comparison.
        private static func compare(_ i: Int64, _ d: Double) -> Int {
            if d >= 9_223_372_036_854_775_808.0 { return -1 }
            if d < -9_223_372_036_854_775_808.0 { return 1 }
            let t = d.rounded(.towardZero)
            let ti = Int64(t)
            if i < ti { return -1 }
            if i > ti { return 1 }
            let frac = d - t
            return frac > 0 ? -1 : (frac < 0 ? 1 : 0)
        }
    }
}
