import Foundation

/// The words the transcriber is told to expect (plan M08-M13 §3.4): the vocabulary list in
/// `WHISPER_PROMPT`, then the profile name and the `meant` of the last 12 corrections, as
/// `_whisper_prompt` adds them (J:915-931). The name and the corrections come from
/// `CoreState.whisperVocabularyInputs()`.
public enum Vocabulary {
    /// `WHISPER_PROMPT`'s default (J:95-98), verbatim.
    public static let defaultPrompt = "A short voice command spoken to JARVIS, a personal assistant. "
        + "Vocabulary: Jarvis, calendar, reminder, alarm, timer, volume, brightness, "
        + "screenshot, weather, news, Safari, Chrome, thank you, that's all Jarvis."

    /// `os.environ.get("JARVIS_WHISPER_PROMPT", ...)`: a set but empty variable is used as it is.
    public static func basePrompt(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["JARVIS_WHISPER_PROMPT"] ?? defaultPrompt
    }

    /// The prompt's own words: the text after the last "Vocabulary:", split on commas, each
    /// trimmed of spaces and a trailing full stop. With no "Vocabulary:", the whole prompt is
    /// one entry. Empty entries are left out.
    public static func words(in prompt: String) -> [String] {
        let list: String
        let parts: [Substring]
        if let r = prompt.range(of: "Vocabulary:", options: .backwards) {
            list = String(prompt[r.upperBound...])
            parts = list.split(separator: ",", omittingEmptySubsequences: false)
        } else {
            parts = [Substring(prompt)]
        }
        return parts.compactMap { part in
            var w = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if w.hasSuffix(".") { w.removeLast() }
            w = w.trimmingCharacters(in: .whitespacesAndNewlines)
            return w.isEmpty ? nil : w
        }
    }

    /// `dict.fromkeys(extra)`: the name (when it is not empty) and then the meant words, the
    /// first of each kept. Equal means the same code points, as in Python, not Swift's canonical
    /// equivalence.
    public static func extras(name: String?, meant: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<[Unicode.Scalar]>()
        let all = (name.flatMap { $0.isEmpty ? nil : [$0] } ?? []) + meant
        for w in all where seen.insert(Array(w.unicodeScalars)).inserted { out.append(w) }
        return out
    }

    /// `_whisper_prompt()`'s string. Native never sends it anywhere: the golden test compares it
    /// with Python's, which pins the extras' order and de-duplication.
    public static func prompt(base: String, name: String?, meant: [String]) -> String {
        let extra = extras(name: name, meant: meant)
        return extra.isEmpty ? base : base + " Also: " + extra.joined(separator: ", ") + "."
    }

    /// What goes into `AnalysisContext.contextualStrings[.general]`: the prompt's words, then the
    /// extras. An extra that repeats a prompt word is kept, as Python's prompt repeats it.
    public static func contextualStrings(base: String, name: String?, meant: [String]) -> [String] {
        words(in: base) + extras(name: name, meant: meant)
    }
}
