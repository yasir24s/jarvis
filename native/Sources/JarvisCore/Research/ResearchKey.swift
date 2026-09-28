import Foundation

// Every counter name the app may bump in research/usage.json (plan: M01b §2.3, §3.2). Call
// sites use these, never free strings. The dynamic names reproduce jarvis.py's sanitisers
// exactly (golden suite m1b_keys, driven through the real set_tone / _set_backend /
// emotion_event):
//   1056  "tone_" + re.sub(r"\W+", "_", desc.split(",")[0].strip())      (no lowercasing)
//   2351  "emotion_" + name                                               (name ∈ _EMO_DELTAS)
//   4855  "backend_" + re.sub(r"\W+", "_", name.lower())
// Names are the dataset's schema: existing ones never change; new ones are additive.

public enum ResearchKey {
    // Existing counters (schema 1): byte-identical to Python's.
    public static let interactions = "interactions"
    public static let sttSegmentsDropped = "stt_segments_dropped"
    public static let personalityConsolidations = "personality_consolidations"
    public static let userCorrection = "user_correction"
    public static let rephraseSuspected = "rephrase_suspected"
    public static let speakerReject = "speaker_reject"
    public static let speakerPass = "speaker_pass"
    public static let wakeRejectedForeignVoice = "wake_rejected_foreign_voice"

    // New counters (schema 2, additive; native-specified, no Python oracle).
    public static let interactionsText = "interactions_text"
    public static let aliveHours = "alive_hours"
    public static let fastPathHandled = "fast_path_handled"
    public static let ttsElevenLabs = "tts_elevenlabs"
    public static let ttsPiper = "tts_piper"
    public static let ttsCharsElevenLabs = "tts_chars_elevenlabs"

    /// The emotion events jarvis.py's call sites actually emit (§2.3). `task_ok` is in
    /// `_EMO_DELTAS` (Python would count it) but no call site emits it, so native never does.
    public static let emittedEmotionEvents: Set<String> = [
        "barge_in", "user_urgent", "insult", "praise", "gratitude", "corrected", "task_fail",
    ]

    /// `"backend_" + re.sub(r"\W+", "_", name.lower())` — Python `str.lower()`.
    public static func backend(_ name: String) -> String {
        "backend_" + PyWord.sub(PyStr.lower(name))
    }

    /// `"emotion_" + name`; the caller guarantees `event` is one `emotionEvent` accepts.
    public static func emotion(_ event: String) -> String {
        "emotion_" + event
    }

    /// nil when `desc == ""` (set_tone returns early); else
    /// `"tone_" + re.sub(r"\W+", "_", desc.split(",")[0].strip())`.
    public static func tone(_ desc: String) -> String? {
        guard !desc.unicodeScalars.isEmpty else { return nil }
        var first = String.UnicodeScalarView()
        for u in desc.unicodeScalars {
            if u == "," { break }
            first.append(u)
        }
        return "tone_" + PyWord.sub(PyStr.strip(String(first)))
    }

    /// Schema 2: `"tool_" + name` for a registered tool, `"tool_unknown"` otherwise (names
    /// compared code point by code point, like Python's `in`).
    public static func tool(_ name: String, known: Set<String>) -> String {
        let hit = known.contains { PyStr.equal($0, name) }
        return "tool_" + (hit ? name : "unknown")
    }

    /// Schema 2: once per app launch, `starts_swift_dev` / `starts_swift_release`.
    public static func starts(build: BuildChannel) -> String {
        "starts_swift_" + build.rawValue
    }

    /// Schema 2: `tts_fallback_<reason>`.
    public static func ttsFallback(_ r: TTSFallbackReason) -> String {
        "tts_fallback_" + r.rawValue
    }
}

public enum BuildChannel: String, Sendable, CaseIterable {
    case dev, release
}

public enum TTSFallbackReason: String, Sendable, CaseIterable {
    case offline, quota, timeout, error, sensitive
}

/// `re.sub(r"\W+", "_", s)` with a Python 3 str pattern: every maximal run of non-word
/// scalars becomes one "_". A word scalar is CPython's `_PyUnicode_IsAlpha` (general
/// category L*) or `_PyUnicode_IsNumeric` (any Numeric_Type), or "_". Combining marks
/// (M*) are NOT word characters, so a decomposed "e\u{301}" becomes "e_". Scalars newer
/// than Python's Unicode database are unassigned there, hence non-word (`PyStr.known`).
public enum PyWord {
    public static func sub(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for u in s.unicodeScalars {
            if isWord(u) {
                out.append(u)
                inRun = false
            } else if !inRun {
                out.append("_")
                inRun = true
            }
        }
        return String(out)
    }

    public static func isWord(_ u: Unicode.Scalar) -> Bool {
        if u == "_" { return true }
        guard PyStr.known(u) else { return false }
        switch u.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return u.properties.numericType != nil
        }
    }
}

/// The few Python `str` operations the dataset needs, on Unicode scalars (Python strings
/// are code point sequences; Swift `String` compares and splits by grapheme and canonical
/// equivalence, which would differ). Internal: M1's PyCompat layer owns the public ones.
enum PyStr {
    /// CPython 3.14's `unicodedata.unidata_version` is 16.0.0; Swift's stdlib carries a newer
    /// Unicode (17.0 on this toolchain). A scalar assigned after 16.0 is Cn to Python: no
    /// letter/number class, no case mapping, neither cased nor case-ignorable.
    static func known(_ u: Unicode.Scalar) -> Bool {
        guard let age = u.properties.age else { return false }
        return age.major < 16 || (age.major == 16 && age.minor == 0)
    }

    /// `str.lower()`: each scalar's full lowercase mapping (SpecialCasing, unconditional:
    /// "İ" → "i̇"), except U+03A3 Σ, which takes CPython's Final_Sigma context rule.
    static func lower(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, u) in scalars.enumerated() {
            if u.value == 0x3A3 {
                out.append(finalSigma(scalars, i) ? "\u{3C2}" : "\u{3C3}")
            } else if known(u) {
                out.append(contentsOf: u.properties.lowercaseMapping.unicodeScalars)
            } else {
                out.append(u)
            }
        }
        return String(out)
    }

    /// CPython `handle_capital_sigma`: \p{cased}\p{case-ignorable}* Σ !(\p{case-ignorable}* \p{cased}).
    private static func finalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0 && caseIgnorable(s[j]) { j -= 1 }
        guard j >= 0 && cased(s[j]) else { return false }
        j = i + 1
        while j < s.count && caseIgnorable(s[j]) { j += 1 }
        return j == s.count || !cased(s[j])
    }

    private static func cased(_ u: Unicode.Scalar) -> Bool { known(u) && u.properties.isCased }
    private static func caseIgnorable(_ u: Unicode.Scalar) -> Bool {
        known(u) && u.properties.isCaseIgnorable
    }

    /// `str.isspace()` for one scalar: CPython's `_PyUnicode_IsWhitespace` (bidi WS/B/S or
    /// Zs; Unicode 16). Includes U+001C–U+001F and U+0085; excludes U+200B and U+180E.
    static func isSpace(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029,
             0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// `str.strip()` with no argument.
    static func strip(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        var lo = 0, hi = u.count
        while lo < hi && isSpace(u[lo]) { lo += 1 }
        while hi > lo && isSpace(u[hi - 1]) { hi -= 1 }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: u[lo..<hi])
        return String(out)
    }

    /// A `str.splitlines()` boundary: \n \v \f \r \x1c \x1d \x1e \x85 U+2028 U+2029
    /// ("\r\n" is one boundary; the caller handles the pair).
    static func isLineBreak(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// `a == b` for Python strings: code point equality, not canonical equivalence.
    static func equal(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// `a < b` for Python strings (code point order), as `sorted()` uses.
    static func less(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }
}
