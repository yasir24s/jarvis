import Foundation

// Python `str` semantics for the idioms M1 ports (plan: M01 §3.2). Proven against Python by
// the `m1_strings` golden suite, including the isspace and `\w` tables over every scalar.
//
// Swift's `==`, `hasPrefix`, `contains`, `count`, `lowercased()`, `trimmingCharacters` and
// `split` work on grapheme clusters or canonical equivalence; Python works on code points.
// Every helper here works on `String.unicodeScalars`, so all M1 logic calls these instead.

public enum Py {
    /// `str.isspace()` for one code point: exactly these 29 scalars (the same set as Python
    /// `re`'s `\s`): U+0009–000D, U+001C–001F, U+0020, U+0085, U+00A0, U+1680, U+2000–200A,
    /// U+2028, U+2029, U+202F, U+205F, U+3000.
    public static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    /// Python `re`'s `\w` for str patterns: general category L* or N*, or "_".
    public static func isWord(_ u: Unicode.Scalar) -> Bool {
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            true
        default:
            u == "_"
        }
    }

    /// `str.lower()`: the full (unconditional) lowercase mapping per scalar, plus Final_Sigma:
    /// U+03A3 becomes ς when a cased letter precedes it (skipping case-ignorables) and no cased
    /// letter follows it (again skipping case-ignorables); otherwise σ.
    public static func lower(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in u.enumerated() {
            if c.value == 0x03A3 {
                out.append(finalSigma(u, i) ? "\u{03C2}" : "\u{03C3}")
            } else {
                out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
            }
        }
        return String(out)
    }

    /// CPython's handle_capital_sigma: a scalar that is case-ignorable is skipped even if it is
    /// also cased, in both directions.
    private static func finalSigma(_ u: [Unicode.Scalar], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, u[j].properties.isCaseIgnorable { j -= 1 }
        guard j >= 0, u[j].properties.isCased else { return false }
        j = i + 1
        while j < u.count, u[j].properties.isCaseIgnorable { j += 1 }
        return j == u.count || !u[j].properties.isCased
    }

    /// `str.strip()`: removes leading and trailing `isSpace` scalars.
    public static func strip(_ s: String) -> String {
        trim(s, leading: true, trailing: true, isSpace)
    }

    /// `str.strip(chars)`: `chars` is a set of code points.
    public static func strip(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return trim(s, leading: true, trailing: true) { set.contains($0) }
    }

    /// `str.lstrip(chars)`.
    public static func lstrip(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return trim(s, leading: true, trailing: false) { set.contains($0) }
    }

    /// `str.rstrip(chars)`.
    public static func rstrip(_ s: String, _ chars: String) -> String {
        let set = Set(chars.unicodeScalars)
        return trim(s, leading: false, trailing: true) { set.contains($0) }
    }

    private static func trim(_ s: String, leading: Bool, trailing: Bool,
                             _ drop: (Unicode.Scalar) -> Bool) -> String {
        let u = s.unicodeScalars
        var lo = u.startIndex, hi = u.endIndex
        if leading { while lo < hi, drop(u[lo]) { lo = u.index(after: lo) } }
        if trailing {
            while hi > lo {
                let prev = u.index(before: hi)
                guard drop(u[prev]) else { break }
                hi = prev
            }
        }
        return String(String.UnicodeScalarView(u[lo..<hi]))
    }

    /// `str.split()`: runs of `isSpace` separate fields; no empty fields.
    public static func split(_ s: String) -> [String] {
        var out: [String] = []
        var field = String.UnicodeScalarView()
        var inField = false
        for c in s.unicodeScalars {
            if isSpace(c) {
                if inField { out.append(String(field)); field = String.UnicodeScalarView(); inField = false }
            } else {
                field.append(c)
                inField = true
            }
        }
        if inField { out.append(String(field)) }
        return out
    }

    /// `str.splitlines()`: line boundaries are \n \r \v \f \x1c \x1d \x1e \x85 U+2028 U+2029,
    /// with \r\n as one boundary. No trailing empty line; "" gives [].
    public static func splitlines(_ s: String) -> [String] {
        let u = Array(s.unicodeScalars)
        var out: [String] = []
        var i = 0, j = 0
        while i < u.count {
            while i < u.count, !isLineBreak(u[i]) { i += 1 }
            let eol = i
            if i < u.count {
                i += (u[i] == "\r" && i + 1 < u.count && u[i + 1] == "\n") ? 2 : 1
            }
            out.append(String(String.UnicodeScalarView(u[j..<eol])))
            j = i
        }
        return out
    }

    private static func isLineBreak(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }

    /// `len(s)`: the number of code points.
    public static func len(_ s: String) -> Int {
        s.unicodeScalars.count
    }

    /// `s[:n]` in code points (negative n counts from the end). May split a grapheme cluster,
    /// as Python does.
    public static func prefix(_ s: String, _ n: Int) -> String {
        let u = s.unicodeScalars
        let count = u.count
        let end = n < 0 ? max(0, count + n) : min(n, count)
        return String(String.UnicodeScalarView(u.prefix(end)))
    }

    /// `a == b`: code-point equality (no canonical equivalence).
    public static func eq(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// `needle in hay` for strings, by code points. The empty needle is always found.
    public static func contains(_ hay: String, _ needle: String) -> Bool {
        let h = Array(hay.unicodeScalars), n = Array(needle.unicodeScalars)
        if n.isEmpty { return true }
        if n.count > h.count { return false }
        for start in 0...(h.count - n.count) where h[start] == n[0] {
            if h[start..<(start + n.count)].elementsEqual(n) { return true }
        }
        return false
    }

    /// `s.startswith(p)`, by code points.
    public static func startsWith(_ s: String, _ p: String) -> Bool {
        s.unicodeScalars.starts(with: p.unicodeScalars)
    }

    /// `a[-n:]`. As in Python, n == 0 gives the whole array (`a[-0:]` is `a[0:]`), and a
    /// negative n drops the first |n| elements.
    public static func tail<T>(_ a: [T], _ n: Int) -> [T] {
        let start = -n
        let from = start < 0 ? max(0, a.count + start) : min(start, a.count)
        return Array(a[from...])
    }

    /// Python `min(a, b)`: b only when b < a, so ties and NaN comparisons keep a.
    public static func pyMin(_ a: Double, _ b: Double) -> Double {
        b < a ? b : a
    }

    /// Python `max(a, b)`: b only when b > a.
    public static func pyMax(_ a: Double, _ b: Double) -> Double {
        b > a ? b : a
    }
}

/// A string key that hashes and compares by code points, as Python `set`/`dict` keys do.
public struct PyKey: Hashable, Sendable {
    public let string: String

    public init(_ string: String) {
        self.string = string
    }

    public static func == (a: PyKey, b: PyKey) -> Bool {
        Py.eq(a.string, b.string)
    }

    public func hash(into hasher: inout Hasher) {
        for u in string.unicodeScalars { hasher.combine(u.value) }
    }
}
