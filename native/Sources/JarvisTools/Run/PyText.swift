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

    /// The `str()` of the `UnicodeDecodeError` a strict UTF-8 decode of `data` raises, or nil
    /// when it decodes. CPython's decoder: the first bad sequence, with its reason and its
    /// byte range ("byte 0x.. in position N" for one byte, "bytes in position A-B" for more).
    static func decodeError(_ data: Data) -> String? {
        let b = [UInt8](data)
        var i = 0
        func cont(_ j: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> Bool {
            j < b.count && b[j] >= low && b[j] <= high
        }
        while i < b.count {
            let c = b[i]
            var need = 0, low: UInt8 = 0x80, high: UInt8 = 0xBF
            switch c {
            case 0x00...0x7F: i += 1; continue
            case 0xC2...0xDF: need = 1
            case 0xE0: need = 2; low = 0xA0
            case 0xED: need = 2; high = 0x9F
            case 0xE1...0xEF: need = 2
            case 0xF0: need = 3; low = 0x90
            case 0xF4: need = 3; high = 0x8F
            case 0xF1...0xF3: need = 3
            default: return message(i, i + 1, b, "invalid start byte")
            }
            // Each following byte must continue the sequence; the first may be narrowed.
            for k in 1...need {
                let j = i + k
                if j >= b.count { return message(i, b.count, b, "unexpected end of data") }
                let ok = k == 1 ? cont(j, low, high) : cont(j)
                if !ok { return message(i, i + k, b, "invalid continuation byte") }
            }
            i += need + 1
        }
        return nil
    }

    private static func message(_ start: Int, _ end: Int, _ b: [UInt8], _ reason: String) -> String {
        if end - start == 1 {
            return "'utf-8' codec can't decode byte 0x\(String(format: "%02x", b[start])) in position \(start): \(reason)"
        }
        return "'utf-8' codec can't decode bytes in position \(start)-\(end - 1): \(reason)"
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
