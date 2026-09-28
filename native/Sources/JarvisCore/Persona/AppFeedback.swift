import Foundation

// Frontmost-app context and outcome feedback (plan: M01 §2.6, §3.7; integration decision
// D-33 puts them here, not in ToneAppFeedback.swift). Mirrors jarvis.py _front_app /
// app_context and _FEEDBACK_NEG_RE / _LAST_CMD / track_feedback; proven against Python by
// the `m1_history_app` golden suite.

public enum AppContextLogic {
    /// `app_context` returns "" for these (compared with `app.lower()`).
    public static let excluded = ["jarvis", "finder", "loginwindow"]

    /// `app_context()` for a frontmost-app name ("" = unknown).
    public static func context(frontApp app: String) -> String {
        let lower = Py.lower(app)
        if app.isEmpty || excluded.contains(where: { Py.eq($0, lower) }) { return "" }
        return " CONTEXT: the user's frontmost app right now is \(app) — interpret "
            + "ambiguous commands in its light."
    }

    /// `app_context()` with the name read from `provider` (the only suspension point).
    public static func context(from provider: any FrontAppProviding) async -> String {
        context(frontApp: await provider.frontmostAppName())
    }

    /// `_front_app`'s mapping, for the FrontAppProviding binding: `str(app.localizedName())
    /// if app else ""`, so a running app without a localized name reads as "None".
    public static func frontAppName(appPresent: Bool, localizedName: String?) -> String {
        appPresent ? (localizedName ?? "None") : ""
    }
}

/// `track_feedback`, pure (integration decision D-34): the only implementation of the
/// negative-phrase regex, the 30 s window and the 0.65 threshold. M1b's FeedbackTracker holds
/// the `LastCommand` state and performs the outcome's effects.
public enum FeedbackLogic {
    /// `_FEEDBACK_NEG_RE` (re.I), verbatim.
    public static let negativePattern = #"\bno,? (?:i said|i meant|that's not)\b|\bnot what i (?:said|meant|asked)\b"#
        + #"|\bthat'?s (?:wrong|not right)\b|\bwrong answer\b|\bcancel that\b"#
        + #"|\bundo that\b|\bnever ?mind\b"#
    /// `now - _LAST_CMD["at"] < 30`.
    public static let window: Double = 30
    /// `SequenceMatcher(None, text, _LAST_CMD["text"]).ratio() > 0.65`.
    public static let threshold: Double = 0.65
    public static let negativeCounter = "user_correction"
    public static let rephraseCounter = "rephrase_suspected"
    /// `emotion_event("corrected")`, fired after the negative bump.
    public static let negativeEmotionEvent = "corrected"

    static let negativeRE: PyRegex = {
        do { return try PyRegex(negativePattern, ignoreCase: true) } catch {
            preconditionFailure("FeedbackLogic: \(error)")
        }
    }()

    public enum Signal: Equatable, Sendable { case negative, rephrase, none }

    /// `_LAST_CMD`: the previous command and when it arrived (in memory only).
    public struct LastCommand: Sendable, Equatable {
        public var text: String
        public var at: Double

        /// `{"text": "", "at": 0.0}`, the value at import.
        public init(text: String = "", at: Double = 0.0) {
            self.text = text
            self.at = at
        }
    }

    /// One `track_feedback` call. Effects, in Python's order: bump `counter` (if any), then
    /// fire `emotionEvent` (if any); the state becomes `last`.
    public struct Outcome: Sendable, Equatable {
        public let signal: Signal
        public let counter: String?
        public let emotionEvent: String?
        public let last: LastCommand
    }

    /// The branch `track_feedback` takes. Raw text, not normalised.
    public static func classify(_ text: String, lastText: String, lastAt: Double, now: Double) -> Signal {
        if negativeRE.search(text) != nil { return .negative }
        if !lastText.isEmpty && now - lastAt < window && !Py.eq(text, lastText)
            && PyDifflib.ratio(text, lastText) > threshold {
            return .rephrase
        }
        return .none
    }

    /// `track_feedback(text)` at `now`.
    public static func track(_ text: String, last: LastCommand, now: Double) -> Outcome {
        let signal = classify(text, lastText: last.text, lastAt: last.at, now: now)
        return Outcome(signal: signal,
                       counter: signal == .negative ? negativeCounter : signal == .rephrase ? rephraseCounter : nil,
                       emotionEvent: signal == .negative ? negativeEmotionEvent : nil,
                       last: LastCommand(text: text, at: now))
    }
}
