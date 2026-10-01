import Foundation

/// Python's text decoding for bytes that came from a child or the pasteboard (plan: M05-M06
/// §3.4 `pyText`).
enum PyText {
    /// `subprocess.run(..., text=True)`: a strict UTF-8 decode, then `"\r\n"` and `"\r"` to
    /// `"\n"`. Nil where Python raises `UnicodeDecodeError` (invalid bytes, surrogates,
    /// overlong forms, a truncated sequence), which every caller here turns into its failure
    /// text.
    static func decode(_ data: Data) -> String? {
        String(validating: data, as: UTF8.self).map(universalNewlines)
    }

    /// Universal newlines: CRLF and lone CR become LF; no other line break is touched.
    static func universalNewlines(_ s: String) -> String {
        guard s.unicodeScalars.contains("\r") else { return s }
        var out = String.UnicodeScalarView()
        var previousCR = false
        for u in s.unicodeScalars {
            if u == "\n" && previousCR {
                previousCR = false
                continue
            }
            previousCR = u == "\r"
            out.append(previousCR ? "\n" : u)
        }
        return String(out)
    }
}
