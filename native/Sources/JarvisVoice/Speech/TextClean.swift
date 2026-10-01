import Foundation
import JarvisCore

/// The text cleaning in Python's `speak()` (jarvis.py 723-729), proven by the m8_textclean
/// golden suite, which records the real function:
///
///     clean = re.sub(r'[*_`#\[\]()|\\~>•]', '', text).strip()
///     clean = re.sub(r'\s+', ' ', clean)
///     if not clean: return
///
/// Python works on code points, so this works on Unicode scalars. Its `strip()` and `\s` are
/// the same 29-scalar whitespace set (`Py.isSpace`).
public enum TextClean {
    /// The characters `speak()` removes: `* _ ` # [ ] ( ) | \ ~ > •`.
    public static let removed: Set<Unicode.Scalar> = [
        "*", "_", "`", "#", "[", "]", "(", ")", "|", "\\", "~", ">", "\u{2022}",
    ]

    /// The text to speak, or nil when nothing is left (Python returns without speaking).
    public static func clean(_ text: String) -> String? {
        var kept = String.UnicodeScalarView()
        for u in text.unicodeScalars where !removed.contains(u) {
            kept.append(u)
        }
        var out = String.UnicodeScalarView()
        var inSpace = false
        for u in Py.strip(String(kept)).unicodeScalars {
            if Py.isSpace(u) {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(u)
                inSpace = false
            }
        }
        return out.isEmpty ? nil : String(out)
    }

    // MARK: - Numbers, for F5 only

    /// Digits spelled out for the F5 clone (not for `say`, and not in Python, which never had
    /// this voice). F5 misread them in M8's live check: "It's 3:45 PM." came back as "It's
    /// three." and "That costs £20." as "That costs the 20.". Its duration rule counts the
    /// written UTF-8 bytes, so "3:45" also got the time of four characters. NumberFormatter's
    /// `.spellOut` (en-GB) writes the words. Times (h:mm), £ $ € amounts, percentages and plain
    /// numbers, with or without thousands commas, are spelled; digits glued to letters
    /// ("MP3", "1st", "4K") are left as they are.
    public static func spokenNumbers(_ text: String) -> String {
        let ns = text as NSString
        let matches = numberPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        let words = NumberFormatter()
        words.numberStyle = .spellOut
        words.locale = Locale(identifier: "en_GB")
        var out = ""
        var at = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += spoken(m, in: ns, words)
            at = m.range.location + m.range.length
            // A time may run into its "pm": "3:45pm" becomes "three forty-five pm".
            if m.range(withName: "hour").location != NSNotFound, at < ns.length,
               let next = Unicode.Scalar(ns.character(at: at)), next.properties.isAlphabetic {
                out += " "
            }
        }
        out += ns.substring(from: at)
        return out
    }

    private static let numberPattern: NSRegularExpression = {
        let number = #"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?"#
        let pattern = #"(?<![\p{L}\p{N}])(?:"#
            + #"(?<hour>[01]?[0-9]|2[0-3]):(?<minute>[0-5][0-9])(?![0-9])"#
            + #"|(?<currency>[£$€])(?<amount>"# + number + #")(?![\p{L}\p{N}])"#
            + #"|(?<number>"# + number + #")(?<percent>\s?%)?(?![\p{L}\p{N}])"#
            + ")"
        do { return try NSRegularExpression(pattern: pattern) } catch { preconditionFailure("TextClean: \(error)") }
    }()

    private static func spoken(_ m: NSTextCheckingResult, in ns: NSString, _ words: NumberFormatter) -> String {
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func say(_ digits: String) -> String {
            let value = NSDecimalNumber(string: digits.replacingOccurrences(of: ",", with: ""),
                                        locale: Locale(identifier: "en_US_POSIX"))
            guard value != NSDecimalNumber.notANumber else { return digits }
            return words.string(from: value) ?? digits
        }
        if let hour = group("hour"), let minute = group("minute"), let h = Int(hour), let mm = Int(minute) {
            let hourWords = say(String(h))
            if mm == 0 { return hourWords }
            return hourWords + (mm < 10 ? " oh " : " ") + say(String(mm))
        }
        if let symbol = group("currency"), let amount = group("amount") {
            let (one, many) = switch symbol {
            case "£": ("pound", "pounds")
            case "$": ("dollar", "dollars")
            default: ("euro", "euros")
            }
            let halves = amount.replacingOccurrences(of: ",", with: "").split(separator: ".", omittingEmptySubsequences: false)
            if halves.count == 2, halves[1].count == 2, let whole = Int(halves[0]), let cents = Int(halves[1]) {
                let unit = whole == 1 ? one : many
                return cents == 0 ? "\(say(String(whole))) \(unit)" : "\(say(String(whole))) \(unit) \(say(String(cents)))"
            }
            let unit = amount == "1" ? one : many
            return "\(say(amount)) \(unit)"
        }
        if let number = group("number") {
            return group("percent") == nil ? say(number) : "\(say(number)) percent"
        }
        return ns.substring(with: m.range)
    }
}
