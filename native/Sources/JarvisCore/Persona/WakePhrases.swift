import Foundation

/// The wake word in what was heard, and the other phrases the voice loop looks for (M11, plan
/// M08-M13 §3.6). Each is jarvis.py's function, exactly; the `m11_phrases` golden suite runs the
/// real ones:
///
/// - `containsWakeWord`: `contains_wake_word` (J:5125), `_WAKE_RE` on the lowercased text.
/// - `extractCommand`: `extract_command` (J:5128-5145), what is left of an utterance once the
///   wake word is taken out of it.
/// - `isEnroll`: `_is_enroll` (J:5215-5221), "learn my voice" and the like.
/// - `endsMidSentence`: `_INCOMPLETE_TAIL_RE.search` (J:986-988), a transcript that stops
///   mid-thought ("remind me to", a trailing "and").
/// - `isShazam`: `_is_shazam` (J:4169-4173), "what song is this".
///
/// `Dismissal.isDismiss` is the loop's fourth, "that's all, Jarvis".
public enum WakePhrases {
    /// `WAKE_WORDS` (J:69), in source order.
    public static let wakeWords = ["jarvis", "hey jarvis", "ok jarvis", "j.a.r.v.i.s", "jervis", "jarvis."]

    /// `sorted(WAKE_WORDS, key=len, reverse=True)`: longest first, a stable sort, so of two the
    /// same length the earlier in `wakeWords` stays first.
    static let longestFirst: [String] = wakeWords.enumerated()
        .sorted { a, b in
            let (la, lb) = (Py.len(a.element), Py.len(b.element))
            return la != lb ? la > lb : a.offset < b.offset
        }
        .map(\.element)

    /// `_WAKE_RE` (J:5124).
    static let wake = try! PyRegex(#"\b(?:hey |ok |okay )?(?:jarvis|jarviss|jervis|j\.?a\.?r\.?v\.?i\.?s)\b"#)

    /// `_INCOMPLETE_TAIL_RE` (J:986-988), re.I.
    static let incompleteTail = try! PyRegex(
        #"(?:,|\b(?:and|but|or|so|then|because|to|the|a|an|my|your|for|with|of|in|on|at"#
            + #"|that|i|you|please|um|uh|er))$"#, ignoreCase: true)

    /// `_is_enroll`'s exact phrases (STT may cut "learn my voice" short), then its contained ones.
    static let enrolExact = ["learn my", "learn my voice", "learn voice", "learn my voice."]
    static let enrolContained = ["learn my voice", "set up voice", "voice recognition", "remember my voice",
                                 "enroll my voice", "calibrate my voice", "register my voice",
                                 "recognize my voice", "recognise my voice"]

    /// `contains_wake_word(text)`; nil is Python's None.
    public static func containsWakeWord(_ text: String?) -> Bool {
        wake.search(Py.lower(text ?? "")) != nil
    }

    /// `extract_command(text)`: lowercased and stripped; a leading wake word (the longest that
    /// fits) and the `" ,;."` after it come off; else, with "jarvis" anywhere, the words either
    /// side of its first "jarvis" are kept, less a "hey", "ok" or "okay" word just before it.
    public static func extractCommand(_ text: String?) -> String {
        let t = Py.strip(Py.lower(text ?? ""))
        for w in longestFirst where Py.startsWith(t, w) {
            return Py.strip(Py.lstrip(dropFirst(t, Py.len(w)), " ,;."))
        }
        let u = Array(t.unicodeScalars)
        guard let i = firstIndex(of: Array("jarvis".unicodeScalars), in: u) else { return t }
        var before = Py.strip(Py.rstrip(string(u[..<i]), " ,;."))
        let after = Py.strip(Py.lstrip(string(u[(i + 6)...]), " ,;."))
        // `before.endswith(("hey", "ok", "okay"))` is a plain suffix test: "they" ends with "hey".
        if ["hey", "ok", "okay"].contains(where: { before.unicodeScalars.reversed().starts(with: $0.unicodeScalars.reversed()) }) {
            before = Py.contains(before, " ") ? rsplitFirst(before) : ""
        }
        if !before.isEmpty && !after.isEmpty { return Py.strip(before + " " + after) }
        return after.isEmpty ? before : after
    }

    /// `_is_enroll(t)`.
    public static func isEnroll(_ text: String?) -> Bool {
        let t = Py.strip(Py.lower(text ?? ""))
        if enrolExact.contains(where: { Py.eq(t, $0) }) { return true }
        return enrolContained.contains { Py.contains(t, $0) }
    }

    /// `_is_shazam`'s phrases (J:4169-4173), in source order.
    static let shazam = ["what song is this", "what's this song", "whats this song", "name this song",
                         "identify this song", "identify the song", "shazam", "what song is playing",
                         "what is this song"]

    /// `_is_shazam(t)`: a request to identify the music playing.
    public static func isShazam(_ text: String?) -> Bool {
        let t = Py.lower(text ?? "")
        return shazam.contains { Py.contains(t, $0) }
    }

    /// `bool(_INCOMPLETE_TAIL_RE.search(text))`.
    public static func endsMidSentence(_ text: String) -> Bool {
        incompleteTail.search(text) != nil
    }

    // MARK: code-point helpers

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }

    private static func dropFirst(_ s: String, _ n: Int) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.dropFirst(n)))
    }

    /// `str.index(sub)` in code points; nil where Python raises (never here: the caller asked
    /// `"jarvis" in t` first, as Python does).
    private static func firstIndex(of needle: [Unicode.Scalar], in hay: [Unicode.Scalar]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for start in 0...(hay.count - needle.count) where hay[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    /// `s.rsplit(None, 1)[0]` for a stripped `s` with whitespace in it: everything before its last
    /// run of whitespace.
    private static func rsplitFirst(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var end = u.count
        while end > 0, !Py.isSpace(u[end - 1]) { end -= 1 }
        while end > 0, Py.isSpace(u[end - 1]) { end -= 1 }
        return string(u[..<end])
    }
}
