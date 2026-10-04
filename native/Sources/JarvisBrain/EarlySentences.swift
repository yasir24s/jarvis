import JarvisCore

/// V8: a reply's sentences for the voice while the reply is still streaming (Speak First
/// Sentence Early with Qwen). `push` takes the reply's text as the chat shows it and returns each
/// sentence once it has really ended: `SentenceSplitter.pop` finds the ends (a terminator and the
/// whitespace after it, so "3.5" and a terminator at the very end of what has come wait), and a
/// piece it splits after a title or a common abbreviation ("Dr.", "e.g.", "Mr.") or a list number
/// ("2.") is joined to the next, as is the piece `pop` cuts at its 160-character limit, which ends
/// mid-sentence. A phone number or a link is never split, since neither has a terminator followed
/// by whitespace inside it. `finish` hands over what is left at the end of the reply.
public struct EarlySentences: Sendable {
    /// Words after which a full stop is not a sentence's end, lower case, without their last dot.
    public static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "sr", "jr", "vs", "etc", "e.g", "i.e", "approx", "dept",
        "fig", "inc", "ltd", "co", "mt", "no", "a.m", "p.m", "u.s", "u.k",
    ]

    private var buf = ""
    /// Every sentence handed over so far, in order.
    public private(set) var handed: [String] = []

    public init() {}

    /// Adds streamed text; returns the sentences it completed.
    public mutating func push(_ text: String) -> [String] {
        buf += text
        return take(force: false)
    }

    /// The reply has ended: whatever is left, as sentences.
    public mutating func finish() -> [String] {
        take(force: true)
    }

    private mutating func take(force: Bool) -> [String] {
        let (popped, rest) = SentenceSplitter.pop(buf, force: force)
        var out: [String] = []
        var carry = ""
        for (n, piece) in popped.enumerated() {
            let joined = carry.isEmpty ? piece : carry + " " + piece
            let last = force && n == popped.count - 1
            if last || Self.ends(joined) {
                out.append(joined)
                carry = ""
            } else {
                carry = joined
            }
        }
        buf = carry.isEmpty ? rest : carry + " " + rest
        handed += out
        return out
    }

    /// Whether `sentence` (as `pop` gave it) ends a sentence: it ends in a terminator, and the
    /// word before it is not an abbreviation, an initial or a list number.
    static func ends(_ sentence: String) -> Bool {
        guard let last = sentence.unicodeScalars.last, ".!?".unicodeScalars.contains(last) else { return false }
        guard last == "." else { return true }
        let word = String(sentence.split(whereSeparator: \.isWhitespace).last ?? "")
        let bare = word.drop { "(\"'[“‘".contains($0) }.dropLast().lowercased()
        if abbreviations.contains(bare) { return false }
        if bare.count == 1, bare.first?.isLetter == true { return false }            // an initial: "J. Smith"
        if sentence.split(whereSeparator: \.isWhitespace).count == 1, !bare.isEmpty,
           bare.allSatisfy(\.isNumber) { return false }                               // a list number: "2."
        return true
    }

    /// The part of `final` after the words `spoken` covered, when `spoken`'s words are the first
    /// words of `final` (whitespace aside); nil when they are not, so the reply was rewritten.
    public static func rest(of final: String, after spoken: [String]) -> String? {
        let said = spoken.flatMap { Py.split($0) }
        let scalars = Array(final.unicodeScalars)
        var i = 0
        for word in said {
            while i < scalars.count, Py.isSpace(scalars[i]) { i += 1 }
            let w = Array(word.unicodeScalars)
            guard i + w.count <= scalars.count, Array(scalars[i..<(i + w.count)]) == w else { return nil }
            i += w.count
            guard i == scalars.count || Py.isSpace(scalars[i]) else { return nil }
        }
        return Py.strip(String(String.UnicodeScalarView(scalars[i...])))
    }
}
