import Foundation

/// The end of a conversation (P1): the user's dismissal, "that's all, JARVIS", spoken or
/// typed. JARVIS answers `reply`, and the conversation-ended hook runs the personality
/// distillation.
///
/// - `isDismiss` is Python's `is_dismiss(t)`, nested in the voice loop (jarvis.py
///   5606-5611), exactly: `strip()`, then a code-point substring test for each phrase in
///   `contained`, or equality with one in `exact`. Case-sensitive, as Python's is. The
///   `p1_dismiss` golden suite runs the real nested function.
/// - `isTextDismissal` is the text channel's stricter rule (a deviation): a typed message
///   dismisses only when the whole of it is a dismissal, so "thanks, now open Safari" still
///   reaches the brain.
public enum Dismissal {
    /// The voice loop's `speak("Always a pleasure, sir.")`.
    public static let reply = "Always a pleasure, sir."

    /// `is_dismiss`'s `"<phrase>" in t` tests, in source order.
    public static let contained = ["thank you", "thanks jarvis", "thats all", "that's all", "that will be all",
                                   "goodbye jarvis", "dismissed", "stand down", "go to sleep"]
    /// `is_dismiss`'s `t in (...)` tuple, in source order.
    public static let exact = ["goodbye", "bye jarvis", "thanks", "that is all"]

    /// The words of address the text rule sets aside, at most one at each end of a message.
    public static let address = ["jarvis", "sir"]

    /// `is_dismiss(t)`; nil is Python's None (`(t or "")`).
    public static func isDismiss(_ t: String?) -> Bool {
        let t = Py.strip(t ?? "")
        return contained.contains { Py.contains(t, $0) } || exact.contains { Py.eq(t, $0) }
    }

    /// The text rule: the message is lowercased, its punctuation (Unicode P*) dropped and its
    /// whitespace collapsed. It dismisses when the result is one of `is_dismiss`'s phrases
    /// treated the same way, once one leading and one trailing word of address are set aside:
    /// "that's all, JARVIS" and "Jarvis, that's all" both dismiss.
    public static func isTextDismissal(_ text: String) -> Bool {
        var words = normalized(text)
        if isPhrase(words) { return true }
        if words.count > 1, let first = words.first, isAddress(first) {
            words.removeFirst()
            if isPhrase(words) { return true }
        }
        if words.count > 1, let last = words.last, isAddress(last) {
            words.removeLast()
            if isPhrase(words) { return true }
        }
        return false
    }

    static func isAddress(_ word: String) -> Bool {
        address.contains { Py.eq(word, $0) }
    }

    /// Every phrase of `contained` and `exact`, normalized as a message is.
    static let phrases: [[String]] = (contained + exact).map(normalized)

    static func isPhrase(_ words: [String]) -> Bool {
        phrases.contains { $0.count == words.count && zip($0, words).allSatisfy(Py.eq) }
    }

    /// Lowercased (`str.lower()`), punctuation scalars removed, split on whitespace.
    static func normalized(_ s: String) -> [String] {
        let kept = Py.lower(s).unicodeScalars.filter { !isPunctuation($0) }
        return Py.split(String(String.UnicodeScalarView(kept)))
    }

    static func isPunctuation(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            true
        default:
            false
        }
    }
}
