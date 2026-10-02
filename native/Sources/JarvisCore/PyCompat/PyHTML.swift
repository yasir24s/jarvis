import Foundation

/// W1 part 1: Python's `html.unescape`, code point for code point: the same character
/// references (`&(#[0-9]+;?|#[xX][0-9a-fA-F]+;?|[^\t\n\f <&#;]{1,32};?)`), the HTML5 names
/// with the longest-prefix rule, and the same replacements for invalid numbers
/// (`HTML5Entities`, generated from Python's own tables). Proven by the `w1_html` suite.
public enum PyHTML {
    /// Python's `int()` refuses a decimal string longer than this (`sys.int_max_str_digits`), so
    /// `html.unescape` raises ValueError on such a reference.
    public static let intMaxStrDigits = 4300

    public struct TooManyDigits: Error, Equatable, CustomStringConvertible {
        public let digits: Int
        public var description: String {
            "Exceeds the limit (\(PyHTML.intMaxStrDigits) digits) for integer string conversion: "
                + "value has \(digits) digits; use sys.set_int_max_str_digits() to increase the limit"
        }
    }

    /// `html.unescape(s)`. Throws where Python raises: a decimal reference of more than 4,300
    /// digits.
    public static func unescape(_ s: String) throws -> String {
        guard s.contains("&") else { return s }
        let u = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < u.count {
            guard u[i] == "&", let (end, replacement) = try reference(u, at: i + 1) else {
                out.append(u[i])
                i += 1
                continue
            }
            out.append(contentsOf: replacement.unicodeScalars)
            i = end
        }
        return String(out)
    }

    /// The reference after an `&` at `start`: where it ends and what replaces it, or nil when
    /// none matches there (the `&` stays).
    private static func reference(_ u: [Unicode.Scalar], at start: Int) throws -> (Int, String)? {
        guard start < u.count else { return nil }
        if u[start] == "#" {
            var j = start + 1
            if j < u.count, isDigit(u[j]) {                          // #[0-9]+;?
                while j < u.count, isDigit(u[j]) { j += 1 }
                let digits = String(String.UnicodeScalarView(u[(start + 1)..<j]))
                let end = j < u.count && u[j] == ";" ? j + 1 : j
                guard digits.count <= intMaxStrDigits else { throw TooManyDigits(digits: digits.count) }
                return (end, numeric(decimal: digits))
            }
            if j < u.count, u[j] == "x" || u[j] == "X", j + 1 < u.count, isHex(u[j + 1]) {   // #[xX][0-9a-fA-F]+;?
                j += 1
                let from = j
                while j < u.count, isHex(u[j]) { j += 1 }
                let digits = String(String.UnicodeScalarView(u[from..<j]))
                let end = j < u.count && u[j] == ";" ? j + 1 : j
                return (end, numeric(hex: digits))
            }
            return nil
        }
        var j = start                                                // [^\t\n\f <&#;]{1,32};?
        while j < u.count, j - start < 32, !stops(u[j]) { j += 1 }
        guard j > start else { return nil }
        if j < u.count, u[j] == ";" { j += 1 }
        let name = String(String.UnicodeScalarView(u[start..<j]))
        return (j, named(name))
    }

    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }

    private static func isHex(_ c: Unicode.Scalar) -> Bool {
        isDigit(c) || (c.value >= 0x41 && c.value <= 0x46) || (c.value >= 0x61 && c.value <= 0x66)
    }

    private static func stops(_ c: Unicode.Scalar) -> Bool {
        ["\t", "\n", "\u{0C}", " ", "<", "&", "#", ";"].contains(c)
    }

    private static func numeric(decimal digits: String) -> String {
        // Past 0x10FFFF the value only matters as "too big": cap it there.
        let trimmed = digits.drop { $0 == "0" }
        let num: UInt32 = trimmed.count > 8 ? 0x110000 : min(UInt32(trimmed) ?? 0, 0x110000)
        return codePoint(num)
    }

    private static func numeric(hex digits: String) -> String {
        let trimmed = digits.drop { $0 == "0" }
        let num: UInt32 = trimmed.count > 6 ? 0x110000 : min(UInt32(trimmed, radix: 16) ?? 0, 0x110000)
        return codePoint(num)
    }

    private static func codePoint(_ num: UInt32) -> String {
        if let replacement = HTML5Entities.invalidCharrefs[num] {
            return String(Character(Unicode.Scalar(replacement)!))
        }
        if (0xD800...0xDFFF).contains(num) || num > 0x10FFFF { return "\u{FFFD}" }
        if HTML5Entities.invalidCodepoints.contains(num) { return "" }
        return String(String.UnicodeScalarView([Unicode.Scalar(num)!]))
    }

    private static func named(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        if let value = entity(scalars[...]) { return value }
        var x = scalars.count - 1
        while x >= 2 {
            if let value = entity(scalars[..<x]) {
                return value + String(String.UnicodeScalarView(scalars[x...]))
            }
            x -= 1
        }
        return "&" + s
    }

    /// The entity named exactly `name`, by code points. Every name is ASCII, so a name with any
    /// other code point is none (a Swift String key would match canonically equivalent text:
    /// U+212A KELVIN SIGN is "K" to it, never to Python).
    private static func entity(_ name: ArraySlice<Unicode.Scalar>) -> String? {
        guard name.allSatisfy(\.isASCII) else { return nil }
        return entities[String(String.UnicodeScalarView(name))]
    }

    /// `html.entities.html5`, parsed once from the generated table.
    static let entities: [String: String] = {
        var table: [String: String] = [:]
        for line in HTML5Entities.table.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count == 2 else { continue }
            let scalars = parts[1].split(separator: " ").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
            table[String(parts[0])] = String(String.UnicodeScalarView(scalars))
        }
        return table
    }()
}
