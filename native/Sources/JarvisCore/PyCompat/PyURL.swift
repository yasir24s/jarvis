import Foundation

/// W1 part 1: Python's `urllib.parse.quote`, `quote_plus` and `urlencode` (with `quote_plus`, as
/// `urlencode` uses it), byte for byte, for the web tools' URLs. Proven by the `w1_pyurl` suite.
public enum PyURL {
    /// `_ALWAYS_SAFE`: ASCII letters, digits and `_.-~`.
    static func alwaysSafe(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39)
            || b == 0x5F || b == 0x2E || b == 0x2D || b == 0x7E
    }

    /// `urllib.parse.quote(s, safe)`: the UTF-8 bytes, each one that is not always safe and not
    /// in `safe` written as `%XX` (upper-case hex).
    public static func quote(_ s: String, safe: String = "/") -> String {
        let extra = Set(safe.utf8.filter { $0 < 0x80 })
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for b in s.utf8 {
            if alwaysSafe(b) || extra.contains(b) {
                out.unicodeScalars.append(Unicode.Scalar(b))
            } else {
                out += "%" + String(format: "%02X", b)
            }
        }
        return out
    }

    /// `urllib.parse.quote_plus(s, safe)`: spaces become `+`.
    public static func quotePlus(_ s: String, safe: String = "") -> String {
        guard s.contains(" ") else { return quote(s, safe: safe) }
        return quote(s, safe: safe + " ").replacingOccurrences(of: " ", with: "+")
    }

    /// `urllib.parse.urlencode(pairs)`: `quote_plus` of each key and value (already `str()`),
    /// joined `k=v&k=v` in order.
    public static func urlencode(_ pairs: [(String, String)]) -> String {
        pairs.map { quotePlus($0.0) + "=" + quotePlus($0.1) }.joined(separator: "&")
    }
}
