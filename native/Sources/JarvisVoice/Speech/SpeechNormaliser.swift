import Foundation

/// V7: the reply as it should be read aloud, for every voice (Qwen, F5 and `say`). The HUD and
/// the chat keep the text as written; only what the voice is given changes. Python's `speak()`
/// had nothing like it (it only strips markdown, jarvis.py 723-729), so this is a native
/// addition (DEV-V7-01). It replaces M8's `TextClean.spokenNumbers`, which spelled every run of
/// digits as one number: Qwen then read "07700 900123" as "seven thousand seven hundred, nine
/// hundred thousand one hundred twenty-three".
///
/// One pass, left to right, so nothing it writes is read again:
/// - web addresses: the domain only, "dot" between its parts ("www." and the path dropped)
/// - email addresses: "name at example dot com"
/// - phone numbers (a leading 0 or +, 9 to 15 digits in groups): digit by digit, 0 as "oh",
///   a comma (a pause) between the groups as written, or in the UK grouping when written as one
/// - times: "23:52" is "eleven fifty-two p m"; a 24-hour time becomes a 12-hour one with a m or
///   p m, and a written am/pm is kept
/// - £ $ € amounts, percentages, degrees, ordinals ("21st"), dates ("3 March", "March 3rd")
/// - four-digit years after "in", "since", a month and the like: "twenty twenty-six"
/// - other numbers in words, British style ("three hundred and twenty"); a number written with a
///   leading 0, or seven or more digits with no commas, is read digit by digit
/// Digits glued to letters ("MP3", "4K") are left as they are.
public enum SpeechNormaliser {
    public static func spoken(_ text: String) -> String {
        let ns = text as NSString
        let matches = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var at = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += spoken(m, in: ns)
            at = m.range.location + m.range.length
            // Words written straight after a replaced number ("3:45pm" handled, "£5each") get a space.
            if at < ns.length, let next = Unicode.Scalar(ns.character(at: at)), next.properties.isAlphabetic {
                out += " "
            }
        }
        out += ns.substring(from: at)
        return out
    }

    // MARK: - The pattern

    static let months = ["January", "February", "March", "April", "May", "June", "July", "August",
                         "September", "October", "November", "December"]
    private static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "Jun", "Jul", "Aug", "Sep", "Sept",
                                             "Oct", "Nov", "Dec"]
    private static var monthPattern: String {
        "(?:" + (months + monthAbbreviations).sorted { $0.count > $1.count }.joined(separator: "|") + ")"
    }
    /// The endings a bare domain (no scheme, no "www.") must have to be read as one.
    private static let domainEndings = "com|org|net|uk|io|dev|app|ai|gov|edu|info|me|tv|co|ie|eu|us"

    private static let pattern: NSRegularExpression = {
        let number = #"[0-9]{1,3}(?:,[0-9]{3})+(?:\.[0-9]+)?|[0-9]+(?:\.[0-9]+)?"#
        let edge = #"(?<![\p{L}\p{N}])"#
        let parts = [
            // A web address with a scheme or www., its trailing punctuation left out.
            #"(?<url>\bhttps?://[^\s]*[^\s.,;:!?'"]|\bwww\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[^\s]*[^\s.,;:!?'"])?)"#,
            #"(?<email>[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)"#,
            #"(?<domain>\b[A-Za-z0-9-]*[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9-]+)*\.(?:"# + domainEndings
                + #")\b(?![.@][A-Za-z0-9])(?:/[^\s]*[^\s.,;:!?'"])?)"#,
            // A phone number: + and a country code, or a leading 0, then groups of digits.
            edge + #"(?<phone>(?:\+[0-9]{1,3}(?:[ -]?\(0\))?|0[0-9]{1,5})(?:[ -]?[0-9]{2,8}){1,4})(?![\p{L}\p{N}])"#,
            edge + #"(?<hour>[01]?[0-9]|2[0-3]):(?<minute>[0-5][0-9])(?![0-9])"#
                + #"(?:\s?(?<ampm>[AaPp]\.?[Mm](?:\.(?![\s]|$))?)(?![\p{L}]))?"#,
            edge + #"(?<currency>[£$€])(?<amount>"# + number + #")(?![\p{L}\p{N}])"#,
            edge + #"(?<day>[0-3]?[0-9])(?:st|nd|rd|th)?\s(?<dayMonth>"# + monthPattern + #")\b"#,
            #"\b(?<monthDay>"# + monthPattern + #")\s(?<date>[0-3]?[0-9])(?:st|nd|rd|th)?(?![\p{L}\p{N}:])"#,
            edge + #"(?<ordinal>[0-9]{1,6})(?<suffix>st|nd|rd|th|ST|ND|RD|TH)(?![\p{L}\p{N}])"#,
            #"(?:(?<![\p{L}\p{N}.,])(?<minus>[-−]))?"# + edge + #"(?<number>"# + number + #")"#
                + #"(?:(?<percent>\s?%)|(?<degrees>\s?°\s?(?<scale>[CF](?![\p{L}]))?))?(?![\p{L}\p{N}])"#,
        ]
        do {
            return try NSRegularExpression(pattern: parts.joined(separator: "|"))
        } catch {
            preconditionFailure("SpeechNormaliser: \(error)")
        }
    }()

    private static func spoken(_ m: NSTextCheckingResult, in ns: NSString) -> String {
        func group(_ name: String) -> String? {
            let r = m.range(withName: name)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let whole = ns.substring(with: m.range)
        if let url = group("url") { return domain(ofURL: url) }
        if let email = group("email") { return spokenEmail(email) }
        if let domain = group("domain") { return self.domain(ofURL: domain) }
        if let phone = group("phone") { return spokenPhone(phone) ?? numbersOnly(phone) }
        if let hour = group("hour"), let minute = group("minute"), let h = Int(hour), let mm = Int(minute) {
            return time(hour: h, minute: mm, written: hour, ampm: group("ampm"))
        }
        if let symbol = group("currency"), let amount = group("amount") { return money(symbol, amount) }
        if let day = group("day"), let month = group("dayMonth"), let d = Int(day), (1...31).contains(d) {
            return "the \(ordinal(d)) of \(month)"
        }
        if let month = group("monthDay"), let day = group("date"), let d = Int(day), (1...31).contains(d) {
            return "\(month) the \(ordinal(d))"
        }
        if let digits = group("ordinal"), let n = Int(digits) { return ordinal(n) }
        if let number = group("number") {
            var words: String
            if group("minus") == nil, group("percent") == nil, group("degrees") == nil,
               isYear(number, before: m.range.location, in: ns) {
                words = year(Int(number)!)
            } else {
                words = cardinalText(number)
            }
            if group("minus") != nil { words = "minus " + words }
            if group("percent") != nil { words += " percent" }
            if group("degrees") != nil {
                words += " degrees"
                switch group("scale") {
                case "C": words += " Celsius"
                case "F": words += " Fahrenheit"
                default: break
                }
            }
            return words
        }
        // A date whose day is out of range: its parts as they are, numbers in words.
        return numbersOnly(whole)
    }

    /// `text` with only its plain numbers spoken (a phone-shaped match that is not a phone number).
    private static func numbersOnly(_ text: String) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        for m in plainNumber.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            out += cardinalText(ns.substring(with: m.range))
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    private static let plainNumber: NSRegularExpression = {
        do { return try NSRegularExpression(pattern: #"[0-9]+"#) } catch { preconditionFailure("\(error)") }
    }()

    // MARK: - Addresses

    /// "https://www.example.co.uk/news?id=4" is "example dot co dot uk".
    static func domain(ofURL url: String) -> String {
        var host = url
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { $0 != "/" && $0 != "?" && $0 != "#" && $0 != ":" })
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if host.lowercased().hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host.split(separator: ".").map { spokenLabel(String($0)) }.joined(separator: " dot ")
    }

    /// "first.last+news@example.co.uk" is "first dot last plus news at example dot co dot uk".
    static func spokenEmail(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        let local = String(email[..<at])
        var words: [String] = []
        var part = ""
        func flush() {
            if !part.isEmpty { words.append(spokenLabel(part)) }
            part = ""
        }
        for c in local {
            switch c {
            case ".": flush(); words.append("dot")
            case "+": flush(); words.append("plus")
            case "-": flush(); words.append("dash")
            case "_": flush(); words.append("underscore")
            default: part.append(c)
            }
        }
        flush()
        return words.joined(separator: " ") + " at " + domain(ofURL: String(email[email.index(after: at)...]))
    }

    /// A label or name with its digits read one by one: "team42" is "team four two".
    private static func spokenLabel(_ label: String) -> String {
        guard label.contains(where: \.isNumber) else { return label }
        var words: [String] = []
        var letters = ""
        for c in label {
            if let d = c.wholeNumberValue, c.isASCII {
                if !letters.isEmpty { words.append(letters); letters = "" }
                words.append(digitNames[d])
            } else {
                letters.append(c)
            }
        }
        if !letters.isEmpty { words.append(letters) }
        return words.joined(separator: " ")
    }

    // MARK: - Phone numbers

    /// Digit by digit, 0 as "oh", the groups split by commas; nil when the digits do not make a
    /// phone number (a 0-led number needs 10 or 11 digits, a +-led one 9 to 15).
    static func spokenPhone(_ written: String) -> String? {
        let plus = written.hasPrefix("+")
        var text = written.replacingOccurrences(of: "(0)", with: " ")
        if plus { text.removeFirst() }
        var groups = text.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        let digits = groups.joined()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        if plus {
            guard (9...15).contains(digits.count) else { return nil }
            // A UK number written as one run: the country code apart, then the national groups
            // without their 0. "+447700900123" is "plus four four, seven seven oh oh, ...".
            if groups.count == 1, digits.hasPrefix("44") {
                var national = ukGroups("0" + digits.dropFirst(2))
                national[0].removeFirst()
                groups = ["44"] + national
            }
        } else {
            guard digits.hasPrefix("0"), (10...11).contains(digits.count) else { return nil }
            if groups.count == 1 { groups = ukGroups(digits) }
        }
        let spoken = groups.map { $0.compactMap(\.wholeNumberValue).map { $0 == 0 ? "oh" : digitNames[$0] }.joined(separator: " ") }
        return (plus ? "plus " : "") + spoken.joined(separator: ", ")
    }

    /// A UK number written as one run, in its usual groups: 020 7946 0018, 0161 496 0000,
    /// 07700 900123, 01632 960001.
    private static func ukGroups(_ digits: String) -> [String] {
        func split(_ sizes: [Int]) -> [String] {
            var out: [String] = []
            var rest = Substring(digits)
            for size in sizes where !rest.isEmpty {
                out.append(String(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            if !rest.isEmpty { out.append(String(rest)) }
            return out
        }
        guard digits.count == 11 else { return split([5]) }
        if digits.hasPrefix("02") { return split([3, 4]) }
        let chars = Array(digits)
        if digits.hasPrefix("011") || (digits.hasPrefix("01") && chars[3] == "1") || digits.hasPrefix("08")
            || digits.hasPrefix("03") || digits.hasPrefix("09") {
            return split([4, 3])
        }
        return split([5])
    }

    // MARK: - Times, money, years

    /// 24-hour times ("23:52", "09:05", "0:30") become 12-hour ones with a m or p m; a time with
    /// am or pm written keeps it; "3:45" alone is read as it is. "00:00" is midnight.
    static func time(hour h: Int, minute mm: Int, written: String, ampm: String?) -> String {
        let twentyFour = ampm == nil && (h == 0 || h > 12 || (written.count == 2 && written.hasPrefix("0")))
        if twentyFour, h == 0, mm == 0 { return "midnight" }
        let h12 = (ampm != nil || twentyFour) ? (h % 12 == 0 ? 12 : h % 12) : h
        var words = cardinal(h12)
        if mm == 0 {
            if ampm == nil && !twentyFour { words += " o'clock" }
        } else {
            words += mm < 10 ? " oh \(cardinal(mm))" : " \(cardinal(mm))"
        }
        if let ampm {
            words += ampm.lowercased().hasPrefix("a") ? " a m" : " p m"
        } else if twentyFour {
            words += h < 12 ? " a m" : " p m"
        }
        return words
    }

    static func money(_ symbol: String, _ amount: String) -> String {
        let (one, many, minorOne, minorMany) = switch symbol {
        case "£": ("pound", "pounds", "penny", "pence")
        case "$": ("dollar", "dollars", "cent", "cents")
        default: ("euro", "euros", "cent", "cents")
        }
        let plain = amount.replacingOccurrences(of: ",", with: "")
        let halves = plain.split(separator: ".", omittingEmptySubsequences: false)
        if halves.count == 2, halves[1].count == 2, let whole = Int(halves[0]), let minor = Int(halves[1]) {
            if whole == 0 { return minor == 0 ? "nothing" : "\(cardinal(minor)) \(minor == 1 ? minorOne : minorMany)" }
            let unit = whole == 1 ? one : many
            return minor == 0 ? "\(cardinal(whole)) \(unit)" : "\(cardinal(whole)) \(unit) \(cardinal(minor))"
        }
        return "\(cardinalText(amount)) \(plain == "1" ? one : many)"
    }

    /// Words that put a four-digit number from 1100 to 2099 in a date.
    private static let yearCues: Set<String> = ["in", "since", "by", "from", "until", "till", "of", "year",
                                                "during", "before", "after", "around", "circa", "between"]

    private static let afterMonth: NSRegularExpression = {
        let p = "\\b" + monthPattern + #"(?:\s[0-3]?[0-9](?:st|nd|rd|th)?)?,?\s$"#
        do { return try NSRegularExpression(pattern: p) } catch { preconditionFailure("\(error)") }
    }()

    private static func isYear(_ number: String, before location: Int, in ns: NSString) -> Bool {
        guard number.count == 4, let n = Int(number), (1100...2099).contains(n) else { return false }
        let start = max(0, location - 24)
        let before = ns.substring(with: NSRange(location: start, length: location - start))
        if afterMonth.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) != nil {
            return true
        }
        guard before.last == " " else { return false }
        let word = before.dropLast().split(whereSeparator: { !$0.isLetter }).last.map { $0.lowercased() }
        return word.map { yearCues.contains($0) } ?? false
    }

    /// 2026 is "twenty twenty-six", 2005 "two thousand and five", 1905 "nineteen oh five", 1900
    /// "nineteen hundred".
    static func year(_ n: Int) -> String {
        if (2000...2009).contains(n) { return cardinal(n) }
        let high = n / 100, low = n % 100
        if low == 0 { return "\(cardinal(high)) hundred" }
        return low < 10 ? "\(cardinal(high)) oh \(cardinal(low))" : "\(cardinal(high)) \(cardinal(low))"
    }

    // MARK: - Numbers

    static let digitNames = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    private static let teens = ["ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                                "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let scales = ["", "thousand", "million", "billion"]

    /// A number as written: thousands commas allowed, decimals read digit by digit after "point".
    /// A leading 0 ("007") or seven or more digits with no commas: every digit, 0 as "oh".
    static func cardinalText(_ written: String) -> String {
        let plain = written.replacingOccurrences(of: ",", with: "")
        let halves = plain.split(separator: ".", omittingEmptySubsequences: false)
        let whole = String(halves[0])
        var words: String
        if (whole.count > 1 && whole.hasPrefix("0")) || (!written.contains(",") && whole.count >= 7) || whole.count > 12 {
            words = whole.compactMap(\.wholeNumberValue).map { $0 == 0 ? "oh" : digitNames[$0] }
                .joined(separator: " ")
        } else {
            words = cardinal(Int(whole) ?? 0)
        }
        if halves.count == 2 {
            words += " point " + halves[1].compactMap(\.wholeNumberValue).map { digitNames[$0] }.joined(separator: " ")
        }
        return words
    }

    /// British cardinal words: 320 "three hundred and twenty", 2005 "two thousand and five",
    /// 1,520 "one thousand five hundred and twenty". Up to 999,999,999,999.
    static func cardinal(_ n: Int) -> String {
        if n == 0 { return "zero" }
        if n < 0 { return "minus " + cardinal(-n) }
        var groups: [Int] = []
        var rest = n
        while rest > 0 {
            groups.append(rest % 1000)
            rest /= 1000
        }
        guard groups.count <= scales.count else {
            return String(n).compactMap(\.wholeNumberValue).map { digitNames[$0] }.joined(separator: " ")
        }
        var parts: [String] = []
        for (k, g) in groups.enumerated().reversed() where g > 0 {
            var words = underThousand(g)
            if k > 0 { words += " " + scales[k] }
            // "two thousand and five": a last group under a hundred after a larger one takes "and".
            if k == 0, g < 100, groups.count > 1 { words = "and " + words }
            parts.append(words)
        }
        return parts.joined(separator: " ")
    }

    private static func underThousand(_ n: Int) -> String {
        let h = n / 100, r = n % 100
        var words: [String] = []
        if h > 0 { words.append("\(digitNames[h]) hundred") }
        if r > 0 {
            if h > 0 { words.append("and") }
            words.append(underHundred(r))
        }
        return words.joined(separator: " ")
    }

    private static func underHundred(_ n: Int) -> String {
        if n < 10 { return digitNames[n] }
        if n < 20 { return teens[n - 10] }
        return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10])-\(digitNames[n % 10])"
    }

    /// 1 "first", 22 "twenty-second", 101 "one hundred and first", 12 "twelfth".
    static func ordinal(_ n: Int) -> String {
        let words = cardinal(n)
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth", "eight": "eighth",
                         "nine": "ninth", "twelve": "twelfth"]
        // The last word, after a space or a hyphen.
        let cut = words.lastIndex(where: { $0 == " " || $0 == "-" }).map { words.index(after: $0) } ?? words.startIndex
        let head = String(words[..<cut]), last = String(words[cut...])
        if let word = irregular[last] { return head + word }
        if last.hasSuffix("y") { return head + String(last.dropLast()) + "ieth" }
        return head + last + "th"
    }
}
