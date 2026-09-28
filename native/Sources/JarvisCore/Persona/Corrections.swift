import Foundation

// Explicit, user-taught transcription corrections (plan: M01 §2.5, §3.7). Mirrors jarvis.py
// _corrections_load / _corrections_save / _corr_norm / _parse_teach / _is_teach_correction /
// learn_correction / forget_correction / _apply_corrections; proven against Python by the
// `m1_corrections` golden suite.
//
// Pure. The caller owns `_corr_cache` (CoreState's `corrections: [JSONObject]?`, M01 §3.8):
// - load: on first use only, `filter(store.load(.corrections))`; never re-read afterwards,
//   so a later change to the file by anyone else is not seen until the process restarts;
// - save: `cache = capped(pairs)`, then write the cache (indent=1). The cache is replaced
//   even when the write fails, as Python assigns it before opening the file.
// `learn` and `apply` take the pairs as an autoclosure and evaluate it only where Python calls
// _corrections_load, so the cache is loaded at exactly the same moments. None of these paths
// bumps a research counter.

public enum CorrectionsLogic {
    // MARK: - Literals (verbatim from jarvis.py; checked by the fixture's "constants" case)

    public static let saidPattern = #"\b(?:i (?:said|meant)|it'?s|the word is|that'?s)\s+(.+?)\s+not\s+(.+)"#
    public static let toPattern = #"\bcorrect\s+(.+?)\s+to\s+(.+)"#
    public static let whenPattern = #"\bwhen i say\s+(.+?)\s+i (?:mean|meant)\s+(.+)"#
    public static let forgetPattern = #"\bforget (?:the )?corrections?(?: for)?\s*(.*)"#
    /// _corr_norm's two re.sub calls in source order: the outer `\s+`, the inner `[^\w\s]`.
    public static let normSubs: [(pattern: String, repl: String)] = [(#"\s+"#, " "), (#"[^\w\s]"#, " ")]

    /// `_corrections_save`: `pairs[-200:]`.
    public static let cap = 200
    /// `learn_correction`: `len(heard) < 2` is rejected.
    public static let minTeachHeardLength = 2
    /// `_apply_corrections`: `len(heard) < 3` is skipped.
    public static let minApplyHeardLength = 3
    /// `_apply_corrections`: the fuzzy rule applies to `len(norm.split()) <= 6`.
    public static let fuzzyMaxWords = 6
    /// `_apply_corrections`: `SequenceMatcher(None, norm, heard).ratio() >= 0.82`.
    public static let fuzzyThreshold = 0.82
    /// `forget_correction`: targets that clear every correction.
    public static let forgetAllWords = ["all", "everything", "them all", "all of them"]

    static let saidRE = compile(saidPattern, ignoreCase: true)          // _CORR_SAID_RE
    static let toRE = compile(toPattern, ignoreCase: true)              // _CORR_TO_RE
    static let whenRE = compile(whenPattern, ignoreCase: true)          // _CORR_WHEN_RE
    static let forgetRE = compile(forgetPattern, ignoreCase: true)      // _CORR_FORGET_RE
    private static let spaceRun = compile(normSubs[0].pattern)
    private static let nonWordSpace = compile(normSubs[1].pattern)

    // MARK: - Replies (verbatim from jarvis.py)

    public static let teachUsageReply = "Tell me like this, sir: 'I said the right word, not the wrong word.'"
    public static let bothWordsReply = "I didn't catch both words, sir — try 'I said X not Y'."
    public static let clearedAllReply = "Cleared all corrections, sir."

    public static func learnedReply(heard: String, meant: String) -> String {
        "Got it, sir — I'll read '\(heard)' as '\(meant)' from now on."
    }

    public static func forgottenReply(_ target: String) -> String {
        "Forgotten the correction for '\(target)', sir."
    }

    public static func noCorrectionReply(_ target: String) -> String {
        "I had no correction for '\(target)', sir."
    }

    // MARK: - Load / save

    /// `_corrections_load`'s filter: the dict entries whose "heard" and "meant" are truthy.
    /// Anything but a JSON array (nil = Python's except branch) gives [].
    public static func filter(_ raw: JSONValue?) -> [JSONObject] {
        guard case .array(let items)? = raw else { return [] }
        return items.compactMap { item in
            guard case .object(let p) = item, p["heard"]?.pyTruthy == true, p["meant"]?.pyTruthy == true
            else { return nil }
            return p
        }
    }

    /// `pairs[-200:]`: what `_corrections_save` keeps (and caches).
    public static func capped(_ pairs: [JSONObject]) -> [JSONObject] {
        Py.tail(pairs, cap)
    }

    // MARK: - Grammar

    /// `_corr_norm`: lower, every non-word non-space → " ", whitespace runs → " ", strip.
    public static func norm(_ s: String) -> String {
        Py.strip(spaceRun.sub(nonWordSpace.sub(Py.lower(s), literal: normSubs[1].repl),
                              literal: normSubs[0].repl))
    }

    /// `_parse_teach`: (heard, meant) of a teach command, else nil.
    public static func parseTeach(_ text: String) -> (heard: String, meant: String)? {
        let t = Py.strip(text)
        if let m = saidRE.search(t) { return (norm(m.groups[2] ?? ""), norm(m.groups[1] ?? "")) }  // "X not Y" → heard Y
        if let m = toRE.search(t) { return (norm(m.groups[1] ?? ""), norm(m.groups[2] ?? "")) }    // "correct Y to X"
        if let m = whenRE.search(t) { return (norm(m.groups[1] ?? ""), norm(m.groups[2] ?? "")) }  // "when I say Y I mean X"
        return nil
    }

    /// `_is_teach_correction`: a teach command, or the forget grammar anywhere in the text.
    public static func isTeachCorrection(_ text: String) -> Bool {
        parseTeach(text) != nil || forgetRE.search(text) != nil
    }

    // MARK: - Commands

    /// `learn_correction`. `save` is the list Python passes to `_corrections_save` (nil: no
    /// save); the caller's save caps it. `pairs` is evaluated only once the command is valid.
    public static func learn(_ text: String, pairs: @autoclosure () -> [JSONObject],
                             now: Double) -> (reply: String, save: [JSONObject]?) {
        guard let (heard, meant) = parseTeach(text) else { return (teachUsageReply, nil) }
        if heard.isEmpty || meant.isEmpty || Py.eq(heard, meant) || Py.len(heard) < minTeachHeardLength {
            return (bothWordsReply, nil)
        }
        var kept = pairs().filter { $0["heard"] != .string(heard) }
        kept.append(JSONObject([.init(key: "heard", value: .string(heard)),
                                .init(key: "meant", value: .string(meant)),
                                .init(key: "added", value: .double(now))]))
        return (learnedReply(heard: heard, meant: meant), kept)
    }

    /// `forget_correction`: always followed by a save (Python loads the cache first).
    public static func forget(_ text: String, pairs: [JSONObject]) -> (reply: String, save: [JSONObject]) {
        var target = ""
        if let m = forgetRE.search(text), let g = m.groups[1], !Py.strip(g).isEmpty {
            target = norm(g)
        }
        if target.isEmpty || forgetAllWords.contains(where: { Py.eq($0, target) }) {
            return (clearedAllReply, [])
        }
        let kept = pairs.filter { $0["heard"] != .string(target) && $0["meant"] != .string(target) }
        return (kept.count != pairs.count ? forgottenReply(target) : noCorrectionReply(target), kept)
    }

    /// `_apply_corrections`. Teach commands and "" pass through before `pairs` is evaluated.
    /// Pairs run longest `heard` first (stable). A whole-word hit in the normalised text is
    /// substituted, case-insensitively, into the un-normalised result (so a punctuation-split
    /// hit finds nothing to replace, as in Python); otherwise a short utterance close enough to
    /// `heard` becomes `meant` outright.
    ///
    /// Divergences (hand-edited files only; `learn` never writes these shapes):
    /// - `corr-malformed-pair-raises`: where a non-string heard/meant makes Python raise
    ///   (TypeError / AttributeError), native returns `text` unchanged;
    /// - `sub-literal-repl`: a `meant` holding a backslash is substituted literally (Python
    ///   treats it as a re.sub template).
    public static func apply(_ text: String, pairs: @autoclosure () -> [JSONObject]) -> String {
        if text.isEmpty || isTeachCorrection(text) { return text }
        return applyOrRaise(text, pairs()) ?? text
    }

    /// The loop of `_apply_corrections`; nil where Python raises.
    static func applyOrRaise(_ text: String, _ pairs: [JSONObject]) -> String? {
        if pairs.isEmpty { return text }
        var keyed: [(len: Int, index: Int, pair: JSONObject)] = []
        for (k, p) in pairs.enumerated() {
            guard let n = pyLen(p["heard"] ?? .string("")) else { return nil }   // len() raises
            keyed.append((n, k, p))
        }
        keyed.sort { $0.len != $1.len ? $0.len > $1.len : $0.index < $1.index }  // sorted(key=-len)
        var result = text, normed = norm(text)
        for (_, _, p) in keyed {
            guard let heardValue = p["heard"], let meantValue = p["meant"],       // KeyError
                  let n = pyLen(heardValue) else { return nil }
            if n < minApplyHeardLength { continue }
            guard case .string(let heard) = heardValue else { return nil }       // re.escape raises
            let pattern = #"\b"# + PyRegex.escape(heard) + #"\b"#
            guard let hit = try? PyRegex(pattern), let sub = try? PyRegex(pattern, ignoreCase: true) else {
                continue                                                          // unreachable: escaped
            }
            if hit.search(normed) != nil {
                guard case .string(let meant) = meantValue else { return nil }   // re.sub(repl) raises
                result = sub.sub(result, literal: meant)
                normed = norm(result)
            } else if Py.split(normed).count <= fuzzyMaxWords,
                      PyDifflib.ratio(normed, heard) >= fuzzyThreshold {
                guard case .string(let meant) = meantValue else { return nil }   // _corr_norm raises
                result = meant
                normed = norm(meant)
            }
        }
        return result
    }

    // MARK: - Helpers

    /// Python `len(x)` for the JSON types that have one; nil where it raises TypeError.
    private static func pyLen(_ v: JSONValue) -> Int? {
        switch v {
        case .string(let s): Py.len(s)
        case .array(let a): a.count
        case .object(let o): o.count
        case .null, .bool, .int, .bigInt, .double: nil
        }
    }

    private static func compile(_ pattern: String, ignoreCase: Bool = false) -> PyRegex {
        do { return try PyRegex(pattern, ignoreCase: ignoreCase) } catch {
            preconditionFailure("CorrectionsLogic: \(error)")
        }
    }
}
