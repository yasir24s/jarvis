import Foundation
import JarvisCore

/// Python's `repr` and `str` for the values the tool bodies print (plan: M05-M06 §3.1 PyStr
/// `repr`). Used where Python formats a value into a reply: an `OSError`'s filename and a plist
/// value passed to `str()`.
enum PyRepr {
    /// CPython's `unicode_repr`: single quotes unless the text holds `'` and no `"`; `\\`, the
    /// quote, `\t`, `\n`, `\r` escaped; other non-printables as `\xNN`, `\uNNNN` or `\UNNNNNNNN`.
    static func string(_ s: String) -> String {
        let scalars = s.unicodeScalars
        let quote: Unicode.Scalar = scalars.contains("'") && !scalars.contains("\"") ? "\"" : "'"
        // Built as UTF-8 bytes. A UnicodeScalarView built with append(contentsOf:) took 41 s
        // on a 900 000-scalar path in a debug build; this takes 0.2 s.
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 2)
        func put(_ text: String) { out.append(contentsOf: text.utf8) }
        out.append(UInt8(quote.value))
        for u in scalars {
            switch u {
            case quote, "\\": out.append(0x5C); out.append(UInt8(u.value))
            case "\t": put("\\t")
            case "\n": put("\\n")
            case "\r": put("\\r")
            default:
                if u.value < 0x20 || u.value == 0x7F {
                    put(hex(u.value, "x", 2))
                } else if u.value < 0x7F || isPrintable(u) {
                    out.append(contentsOf: String(u).utf8)
                } else {
                    put(u.value <= 0xFF ? hex(u.value, "x", 2) : u.value <= 0xFFFF ? hex(u.value, "u", 4)
                        : hex(u.value, "U", 8))
                }
            }
        }
        out.append(UInt8(quote.value))
        return String(decoding: out, as: UTF8.self)
    }

    /// `str.isprintable()` for one code point: not Other (Cc Cf Cs Co Cn) and not a separator
    /// (Zl Zp Zs), except the ASCII space.
    static func isPrintable(_ u: Unicode.Scalar) -> Bool {
        if u == " " { return true }
        switch u.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    /// `repr(bytes)`: b'...' (or b"..." when it holds `'` and no `"`), printable ASCII kept,
    /// `\t \n \r \\` and the quote escaped, everything else `\xNN`.
    static func bytes(_ data: Data) -> String {
        let quote: UInt8 = data.contains(0x27) && !data.contains(0x22) ? 0x22 : 0x27
        var out = "b" + String(UnicodeScalar(quote))
        for b in data {
            switch b {
            case quote, 0x5C: out += "\\" + String(UnicodeScalar(b))
            case 0x09: out += "\\t"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x20..<0x7F: out += String(UnicodeScalar(b))
            default: out += hex(UInt32(b), "x", 2)
            }
        }
        return out + String(UnicodeScalar(quote))
    }

    private static func hex(_ v: UInt32, _ tag: String, _ width: Int) -> String {
        let digits = String(v, radix: 16)
        return "\\" + tag + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
