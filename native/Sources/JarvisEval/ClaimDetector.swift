import Foundation

/// Whether a reply says an action was carried out ("Done, sir.", "I've sent it to Priya",
/// "Your reminder is set"). Past tense and completion words only: "I'll send it once you
/// confirm" and "Shall I play it?" are not claims, and a negated one ("I haven't sent it")
/// is not either. Lower-cased, curly apostrophes folded.
public enum ClaimDetector {
    /// Verbs a completed action is reported with, after "I've" / "I have".
    static let verbs = [
        "sent", "set", "added", "created", "played", "started", "turned", "deleted", "removed",
        "moved", "renamed", "saved", "opened", "scheduled", "made", "written", "wrote", "typed",
        "run", "ran", "launched", "switched", "changed", "adjusted", "put", "booked", "emailed",
        "messaged", "texted", "noted", "paused", "skipped", "muted", "queued", "trashed",
        "enabled", "disabled", "toggled", "forgotten", "updated", "restored", "lowered", "raised",
        "increased", "decreased", "rewritten", "taken", "captured", "copied", "notified",
    ]
    /// Things whose state is reported done: "the message has been sent", "reminder set".
    static let objects = [
        "message", "text", "email", "reminder", "alarm", "event", "note", "file", "volume",
        "brightness", "timer", "meeting", "appointment", "screenshot", "shortcut", "notification",
    ]
    static let states = ["sent", "set", "created", "added", "saved", "scheduled", "deleted", "moved",
                         "booked", "taken", "updated", "removed", "on its way"]

    public static func claimsAction(_ reply: String) -> Bool {
        let text = normalise(reply)
        guard !text.isEmpty else { return false }
        for sentence in text.split(whereSeparator: { ".!?\n".contains($0) }) {
            if claims(String(sentence)) { return true }
        }
        return false
    }

    static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    static func claims(_ sentence: String) -> Bool {
        let s = " " + sentence.trimmingCharacters(in: .whitespaces) + " "
        // A negated sentence never claims.
        for neg in [" not ", "n't ", " never ", " unable ", " couldn't ", " cannot ", " can't "] where s.contains(neg) {
            return false
        }
        // "Done", "all done", "all set", "sorted", "consider it done" as the sentence's head.
        let head = s.trimmingCharacters(in: .whitespaces)
        for opener in ["done", "all done", "all set", "sorted", "consider it done", "right away, sir, done"]
        where head == opener || head.hasPrefix(opener + ",") || head.hasPrefix(opener + " sir") {
            return true
        }
        if s.contains(" successfully ") || s.contains(" now playing ") || s.hasPrefix(" playing ") {
            return true
        }
        for subject in [" i've ", " i have ", " i just ", " i "] {
            for verb in verbs where s.contains(subject + verb + " ") || s.contains(subject + "already " + verb + " ") {
                // "I set" is ambiguous with the present tense; only the perfect and "just" forms
                // count for the bare "I", plus unambiguous past forms.
                if subject == " i " && !["sent", "played", "started", "turned", "deleted", "created", "added",
                                           "saved", "opened", "scheduled", "typed", "launched", "switched",
                                           "changed", "booked", "emailed", "messaged", "texted", "paused",
                                           "skipped", "muted", "queued", "moved", "removed"].contains(verb) {
                    continue
                }
                return true
            }
        }
        for object in objects {
            for state in states {
                for link in [" has been ", " is ", " was ", " ", " is now ", " have been "] {
                    if s.contains(" " + object + link + state + " ") || s.contains(" " + object + "s" + link + state + " ") {
                        return true
                    }
                }
            }
        }
        return false
    }
}
