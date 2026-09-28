import Foundation

// Python `re` patterns executed on NSRegularExpression (plan: M01 §3.3). Proven against Python
// by the `m1_regex` golden suite: every pattern jarvis.py's M1 subsystems use, plus the `\w`,
// `\s` and `\d` tables over every scalar.
//
// ICU's `\w`, `\s` and `\b` differ from Python's, so the pattern is translated by a tokenizer
// that knows whether it is inside a `[...]` class; everything else passes through verbatim.
// Under re.I, ICU also closes letter categories over case (U+0345 folds to ι, so ICU's
// case-insensitive `\p{L}` matches it); Python's `\w` ignores the case flag, so the translated
// categories are fenced with `(?-i:…)`. Case-insensitive *literals* keep ICU's semantics —
// full case folding (ß ~ ss, ﬀ ~ ff) and no case tie between İ/ı and i/I — a residual
// divergence the golden suite lists case by case (§8 R5).

public struct PyRegexError: Error, Equatable, CustomStringConvertible {
    public let pattern: String
    public let reason: String

    public var description: String { "PyRegex: \(reason) in \(pattern.debugDescription)" }
}

public struct PyMatch: Sendable, Equatable {
    /// [0] = the whole match; nil = the group did not participate.
    public let groups: [String?]
    /// In code points (converted from the UTF-16 NSRange).
    public let span: Range<Int>
}

public struct PyRegex: Sendable {
    public let pattern: String            // the Python pattern
    public let icuPattern: String         // what NSRegularExpression compiled
    public let ignoreCase: Bool
    private let regex: NSRegularExpression

    /// Translates a Python pattern and compiles it. Always `.useUnixLineSeparators` (only \n
    /// ends a line for `.` and `$`, as in Python), plus `.caseInsensitive` for re.I.
    public init(_ pythonPattern: String, ignoreCase: Bool = false) throws {
        pattern = pythonPattern
        self.ignoreCase = ignoreCase
        icuPattern = try Self.translate(pythonPattern, ignoreCase: ignoreCase)
        var options: NSRegularExpression.Options = [.useUnixLineSeparators]
        if ignoreCase { options.insert(.caseInsensitive) }
        do {
            regex = try NSRegularExpression(pattern: icuPattern, options: options)
        } catch {
            throw PyRegexError(pattern: pythonPattern, reason: "ICU rejected \(icuPattern.debugDescription)")
        }
    }

    /// `re.search`.
    public func search(_ s: String) -> PyMatch? {
        first(s, [])
    }

    /// `re.match`: anchored at the start, not at the end.
    public func match(_ s: String) -> PyMatch? {
        first(s, .anchored)
    }

    /// `re.findall` for a pattern with no groups (the whole matches) or one group (that
    /// group, "" when it did not participate). More groups give tuples in Python: a
    /// precondition failure here.
    public func findall(_ s: String) -> [String] {
        let groups = regex.numberOfCaptureGroups
        precondition(groups <= 1, "PyRegex.findall: \(groups) groups would return tuples in Python")
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            let r = m.range(at: groups)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    /// `re.sub(pattern, repl, s)` where `repl` is taken literally (no backslash processing).
    public func sub(_ s: String, literal: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                       withTemplate: NSRegularExpression.escapedTemplate(for: literal))
    }

    /// `re.escape`: the result matches `s` literally. Its escapes are opaque to `translate`.
    public static func escape(_ s: String) -> String {
        NSRegularExpression.escapedPattern(for: s)
    }

    private func first(_ s: String, _ options: NSRegularExpression.MatchingOptions) -> PyMatch? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, options: options, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let offsets = Self.scalarOffsets(s)
        let groups: [String?] = (0..<m.numberOfRanges).map { k in
            let r = m.range(at: k)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        return PyMatch(groups: groups,
                       span: offsets[m.range.location]..<offsets[m.range.location + m.range.length])
    }

    /// For each UTF-16 offset in `s` (and the end), the number of scalars before it.
    private static func scalarOffsets(_ s: String) -> [Int] {
        var map: [Int] = []
        map.reserveCapacity(s.utf16.count + 1)
        for (k, u) in s.unicodeScalars.enumerated() {
            for _ in 0..<UTF16.width(u) { map.append(k) }
        }
        map.append(s.unicodeScalars.count)
        return map
    }

    // MARK: - Translation (M01 §3.3)

    /// Python `\w`: L* | N* | "_". Private use is subtracted because Apple's ICU gives some
    /// U+F8xx scalars letter properties (Python's Unicode has every private-use scalar as Co).
    static let word = #"[[\p{L}\p{N}_]--[\x{e000}-\x{f8ff}\x{f0000}-\x{ffffd}\x{100000}-\x{10fffd}]]"#
    static let spaceMembers = #"\t-\r\x{1c}-\x{20}\x{85}\x{a0}\x{1680}\x{2000}-\x{200a}\x{2028}\x{2029}\x{202f}\x{205f}\x{3000}"#
    static let boundary = "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))"

    /// ASCII letters Python accepts after a backslash (outside / inside a class). Any other
    /// ASCII letter is a Python `re.error` ("bad escape"), so it throws here too.
    private static let pythonLetterEscapes = Set("abBdDfnrsStuUvwWxAZzN".unicodeScalars)
    private static let pythonClassLetterEscapes = Set("abdDfnrsStuUvwWxN".unicodeScalars)

    /// Characters ICU's set syntax treats specially that Python's class syntax takes literally.
    private static let icuSetSpecials = Set("[&$:{}~^".unicodeScalars)

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c)
    }

    private static func has(_ u: [Unicode.Scalar], _ at: Int, _ s: String) -> Bool {
        let p = Array(s.unicodeScalars)
        return at + p.count <= u.count && u[at..<(at + p.count)].elementsEqual(p)
    }

    private static func text(_ u: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(u))
    }

    /// Python pattern → ICU pattern. Throws for the constructs M01 §3.3 excludes (`\B`, `\A`,
    /// `\W`/`\S` inside a class, variable-width lookbehind, inline flags such as `(?x)`), for
    /// escapes whose ICU meaning differs from Python's (`\v`, `[\b]`), and for escapes Python
    /// itself rejects.
    static func translate(_ p: String, ignoreCase: Bool = false) throws -> String {
        let u = Array(p.unicodeScalars)
        var out = ""
        var i = 0
        // Group kinds, innermost last: true = a lookbehind (its width must be fixed).
        var groups: [Bool] = []
        func fail(_ why: String) -> PyRegexError { PyRegexError(pattern: p, reason: why) }
        func fence(_ s: String) -> String { ignoreCase ? "(?-i:\(s))" : s }
        var inLookbehind: Bool { groups.contains(true) }

        while i < u.count {
            let c = u[i]
            switch c {
            case "\\":
                guard i + 1 < u.count else { throw fail("trailing backslash") }
                let e = u[i + 1]
                i += 2
                if isASCIILetter(e), !pythonLetterEscapes.contains(e) { throw fail("bad escape \\\(e)") }
                switch e {
                case "w": out += fence(word)
                case "W": out += fence("[^" + word + "]")
                case "s": out += "[" + spaceMembers + "]"
                case "S": out += "[^" + spaceMembers + "]"
                case "b": out += fence(boundary)
                case "Z": out += #"\z"#
                case "B", "A": throw fail("\\\(e) is not supported")
                case "v": throw fail("\\v means one character in Python but a class in ICU")
                case "N":
                    guard i < u.count, u[i] == "{", let close = u[i...].firstIndex(of: "}") else {
                        throw fail("\\N needs {name}")
                    }
                    out += "\\N" + text(u[i...close])
                    i = close + 1
                default: out += "\\" + String(e)
                }
            case "[":
                i = try translateClass(u, i, &out, ignoreCase: ignoreCase, fail)
            case "(":
                if i + 1 < u.count, u[i + 1] == "?" {
                    if has(u, i + 2, "P<") {
                        out += "(?<"; i += 4; groups.append(false)
                    } else if has(u, i + 2, "P=") {
                        guard let close = u[i...].firstIndex(of: ")") else { throw fail("unterminated (?P=") }
                        out += "\\k<" + text(u[(i + 4)..<close]) + ">"
                        i = close + 1
                    } else if has(u, i + 2, "<=") || has(u, i + 2, "<!") {
                        out += "(?<" + String(u[i + 3]); i += 4; groups.append(true)
                    } else if i + 2 < u.count, "aiLmsux-".unicodeScalars.contains(u[i + 2]) {
                        throw fail("inline flags are not supported")
                    } else {
                        out += "(?"; i += 2; groups.append(false)
                    }
                } else {
                    out += "("; i += 1; groups.append(false)
                }
            case ")":
                if !groups.isEmpty { groups.removeLast() }
                out += ")"; i += 1
            case "*", "+", "?":
                if inLookbehind { throw fail("variable-width lookbehind") }
                out.unicodeScalars.append(c); i += 1
            case "{":
                if inLookbehind {
                    let close = u[i...].firstIndex(of: "}") ?? i
                    let body = text(u[(i + 1)..<max(close, i + 1)])
                    let parts = body.split(separator: ",", omittingEmptySubsequences: false)
                    if parts.count != 1 { throw fail("variable-width lookbehind") }
                }
                out.unicodeScalars.append(c); i += 1
            default:
                out.unicodeScalars.append(c); i += 1
            }
        }
        return out
    }

    /// Translates the class opening at u[start] and returns the index after its `]`.
    private static func translateClass(_ u: [Unicode.Scalar], _ start: Int, _ out: inout String, ignoreCase: Bool,
                                       _ fail: (String) -> PyRegexError) throws -> Int {
        var i = start + 1
        var negated = false
        if i < u.count, u[i] == "^" { negated = true; i += 1 }
        var categories = ""        // \w \s \d \D members (case never applies to them in Python)
        var others = ""            // literals, ranges and other escapes
        var hasWord = false
        var first = true
        while true {
            guard i < u.count else { throw fail("unterminated character class") }
            let c = u[i]
            if c == "]" && !first { i += 1; break }
            first = false
            if c == "\\" {
                guard i + 1 < u.count else { throw fail("trailing backslash") }
                let e = u[i + 1]
                i += 2
                if isASCIILetter(e), !pythonClassLetterEscapes.contains(e) {
                    throw fail("bad escape \\\(e) in class")
                }
                switch e {
                case "w": categories += word; hasWord = true
                case "s": categories += spaceMembers
                case "d", "D": categories += "\\" + String(e)
                case "W", "S": throw fail("\\\(e) inside a class is not supported")
                case "b": throw fail("[\\b] is a backspace in Python but not in ICU")
                case "v": throw fail("\\v means one character in Python but a class in ICU")
                case "N":
                    guard i < u.count, u[i] == "{", let close = u[i...].firstIndex(of: "}") else {
                        throw fail("\\N needs {name}")
                    }
                    others += "\\N" + text(u[i...close])
                    i = close + 1
                default: others += "\\" + String(e)
                }
            } else if c == "]" || icuSetSpecials.contains(c) {
                others += "\\" + String(c); i += 1
            } else {
                others.unicodeScalars.append(c); i += 1
            }
        }
        let neg = negated ? "^" : ""
        if !(ignoreCase && hasWord) {
            out += "[" + neg + categories + others + "]"
        } else if others.isEmpty {
            out += "(?-i:[" + neg + categories + "])"
        } else if negated {
            out += "(?:(?!(?-i:[" + categories + "]))[^" + others + "])"
        } else {
            out += "(?:(?-i:[" + categories + "])|[" + others + "])"
        }
        return i
    }
}
