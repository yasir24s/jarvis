import Foundation
import JarvisCore

/// jarvis.py `pop_sentences` (plan: M02-M04 §3.6), proven by golden suite m3_pop_sentences.
/// Indices are code points, as in Python.
public enum SentenceSplitter {
    /// `_SENT_BOUNDARY.pattern`.
    public static let boundaryPattern = #"[.!?]+\s+"#
    /// `_SENT_MAX_CHARS`.
    public static let maxChars = 160

    private static let boundary: PyRegex = {
        do { return try PyRegex(boundaryPattern) } catch { preconditionFailure("SentenceSplitter: \(error)") }
    }()

    /// Splits complete sentences off the front of `buf`: `(sentences, remainder)`. With `force`,
    /// a trailing fragment with no terminal punctuation is flushed too.
    public static func pop(_ buf: String, force: Bool = false) -> (sentences: [String], rest: String) {
        let u = Array(buf.unicodeScalars)
        var out: [String] = []
        var pos = 0
        // `for m in _SENT_BOUNDARY.finditer(buf)`. The pattern has no anchors or lookbehind and
        // never matches empty, so searching what follows the last match finds finditer's next one.
        while pos < u.count, let m = boundary.search(string(u[pos...])) {
            let end = pos + m.span.upperBound
            out.append(Py.strip(string(u[pos..<end])))
            pos = end
        }
        var rest = Array(u[pos...])
        if !force && rest.count > maxChars {
            var cut = rest[..<maxChars].lastIndex(of: " ") ?? -1        // rest.rfind(" ", 0, 160)
            if cut <= 0 { cut = maxChars }
            out.append(Py.strip(string(rest[..<cut])))
            rest = Array(rest[cut...].drop(while: Py.isSpace))          // .lstrip()
        }
        var remainder = string(rest[...])
        if force && !Py.strip(remainder).isEmpty {
            out.append(Py.strip(remainder))
            remainder = ""
        }
        return (out.filter { !$0.isEmpty }, remainder)
    }

    private static func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(s))
    }
}
