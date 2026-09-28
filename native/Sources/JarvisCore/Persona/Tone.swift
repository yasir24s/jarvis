import Foundation

// The text half of vocal tone (plan: M01 §2.6, §3.7; integration decision D-33 puts it here,
// not in ToneAppFeedback.swift). Mirrors jarvis.py LAST_TONE, set_tone and tone_context;
// proven against Python by the `m1_emotions_tone` golden suite. The descriptor itself comes
// from analyze_tone, the audio-feature classifier (M9).

public enum ToneLogic {
    /// tone_context drops a tone older than this many seconds (strict `>`: 90 s still counts).
    public static let maxAge: Double = 90

    private static let nonWord: PyRegex = {
        do { return try PyRegex(#"\W+"#) } catch { preconditionFailure("ToneLogic: \(error)") }
    }()

    /// set_tone's counter, `"tone_" + re.sub(r"\W+", "_", desc.split(",")[0].strip())`.
    public static func counterKey(_ desc: String) -> String {
        let head = String(String.UnicodeScalarView(desc.unicodeScalars.prefix { $0 != "," }))
        return "tone_" + nonWord.sub(Py.strip(head), literal: "_")
    }

    /// `"hurried" in desc`: set_tone then fires `emotion_event("user_urgent")`.
    public static func isUrgent(_ desc: String) -> Bool {
        Py.contains(desc, "hurried")
    }

    /// `tone_context()`: "" when there is no descriptor or it is more than 90 s old.
    public static func context(desc: String, at: Double, now: Double) -> String {
        if desc.isEmpty || now - at > maxAge { return "" }
        return " VOCAL TONE: the user's last utterance SOUNDED \(desc) — that is "
            + "how it was said, not what was said. Read the room: match urgency with speed and "
            + "zero fluff, irritation with extra competence and less banter, subdued with a "
            + "gentler touch, upbeat with a bit more play."
    }
}

/// `LAST_TONE`: the last non-empty descriptor and when it was set (in memory only).
public struct LastTone: Sendable, Equatable {
    public var desc: String
    public var at: Double

    public init(desc: String = "", at: Double = 0.0) {
        self.desc = desc
        self.at = at
    }

    /// `set_tone(desc)`: an empty descriptor is a no-op; else store (desc, now), bump
    /// `tone_<head>`, and for a hurried one run `emotion_event("user_urgent")` (which saves
    /// emotions.json and bumps `emotion_user_urgent`). If that event throws, the tone and its
    /// bump have already happened, as in Python.
    public mutating func set(_ desc: String, store: StateStore, now: Double,
                             research: any ResearchCounting) throws(StateShapeError) {
        if desc.isEmpty { return }
        self.desc = desc
        self.at = now
        research.bump(ToneLogic.counterKey(desc), by: 1)
        if ToneLogic.isUrgent(desc) {
            try EmotionLogic.event("user_urgent", store: store, now: now, research: research)
        }
    }

    /// `tone_context()` at `now`.
    public func context(now: Double) -> String {
        ToneLogic.context(desc: desc, at: at, now: now)
    }
}
