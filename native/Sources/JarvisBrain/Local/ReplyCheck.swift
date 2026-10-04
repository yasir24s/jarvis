import Foundation
import JarvisCore
import JarvisTools

// od/phase2 item 1 (DEV-OD2-02): the on-device model says "Done, sir." whether or not a tool
// ran (11.6% of the scorecard's cases at 3b85f78). The model's text is not trusted on that point: after each
// local turn, Swift checks every sentence that reports an action against the gateway results
// of the same turn, and writes the reply itself when a tool was gated or blocked.

/// The deterministic check of one on-device reply against what the turn's tools did.
///
/// - A sentence that reports an action ("Done, sir.", "I've sent it", "Your alarm is set") is
///   dropped unless an action tool ran successfully in the turn. A leading "Done, sir —" is cut
///   from a sentence that goes on to say something else, and the rest is kept. Every other
///   sentence (the answer, the persona's remarks) is left exactly as the model wrote it.
/// - Read-only tools never count as an action, so a turn that only read the battery cannot say
///   "Done".
/// - If every sentence was a dropped claim, the reply is `notDone`.
/// - A gated or blocked call means Swift writes the whole reply from the gateway's result and
///   the model's text is not used at all (`overrideReply`).
public enum ReplyCheck {
    /// Said when the whole reply was a claim and nothing ran.
    public static let notDone = "I didn't do that, sir — shall I?"
    /// Said when a call was refused because the turn read untrusted content first.
    public static let taintBlocked = "I can't do that after reading untrusted content in the same request, sir."

    /// "That needs your confirmation, sir: that will email Priya. Say 'confirm' to proceed."
    public static func needsConfirmation(_ desc: String) -> String {
        var d = Py.strip(desc)
        while let last = d.last, ".!".contains(last) { d.removeLast() }
        if let first = d.first, d.dropFirst().first?.isUppercase != true { d = first.lowercased() + d.dropFirst() }
        return "That needs your confirmation, sir: \(d). Say 'confirm' to proceed."
    }

    /// Tools that change something. Everything else in the catalog only reads.
    public static let actionTools: Set<String> = [
        "run_command", "run_applescript", "set_volume", "music_play", "music_control", "delete_file",
        "move_file", "write_file", "set_reminder", "make_note", "set_alarm", "notify", "send_message",
        "send_email", "create_event", "set_brightness", "type_text", "take_screenshot", "run_shortcut",
        "open_settings", "system_control", "personality_note", "personality_rewrite", "forget_memory",
        "correct_memory", "restore_memory",
    ]

    /// One gateway result of the turn, as `LocalCallBudget` noted it.
    public struct Call: Sendable, Equatable {
        public let name: String
        public let outcome: ToolRunRecord.Outcome
        public let text: String

        public init(name: String, outcome: ToolRunRecord.Outcome, text: String) {
            self.name = name
            self.outcome = outcome
            self.text = text
        }
    }

    /// True when an action tool ran to completion.
    public static func actionRan(_ calls: [Call]) -> Bool {
        calls.contains { $0.outcome == .ran && actionTools.contains($0.name) }
    }

    /// The reply Swift writes instead of the model's when a call was gated or blocked; nil when
    /// none was. Each distinct line once, in call order.
    public static func overrideReply(_ calls: [Call]) -> String? {
        var lines: [String] = []
        for call in calls {
            let line: String
            switch call.outcome {
            case .blockedTaint: line = taintBlocked
            case .blockedGuard: line = Py.strip(call.text)
            case .gated: line = needsConfirmation(gateDescription(call.text))
            case .ran, .failed, .unknown: continue
            }
            if !line.isEmpty && !lines.contains(line) { lines.append(line) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The description inside `GuardStrings.gatePrompt(desc)`; the text itself if it is not one.
    static func gateDescription(_ text: String) -> String {
        let suffix = GuardStrings.gatePrompt("")
        return text.hasSuffix(suffix) ? String(text.dropLast(suffix.count)) : text
    }

    /// One popped sentence with its unsupported claims taken out; nil when nothing is left.
    /// `actionRan` is whether an action tool has run in the turn.
    public static func filter(_ sentence: String, actionRan: Bool) -> String? {
        if actionRan { return sentence }
        var kept: [String] = []
        for piece in pieces(sentence) {
            let trimmed = Py.strip(piece)
            guard !trimmed.isEmpty else { continue }
            if let rest = strippedOpener(trimmed) {
                if !rest.isEmpty && !claims(rest) { kept.append(rest) }
                continue
            }
            if !claims(trimmed) { kept.append(trimmed) }
        }
        let out = kept.joined(separator: " ")
        return out.isEmpty ? nil : out
    }

    /// The check over a stream of popped sentences. `pass` gives the text to show and speak for
    /// one sentence, or nil when none is; `changed` counts the sentences dropped or cut.
    public struct Stream: Sendable {
        public private(set) var changed = 0

        public init() {}

        public mutating func pass(_ sentence: String, calls: [Call]) -> String? {
            if overrideReply(calls) != nil {
                changed += 1
                return nil
            }
            guard let kept = filter(sentence, actionRan: actionRan(calls)) else {
                changed += 1
                return nil
            }
            if kept != sentence { changed += 1 }
            return kept
        }
    }

    /// A whole reply through `filter`, for tests and callers without a sentence stream.
    public static func check(_ reply: String, calls: [Call]) -> String {
        if let swift = overrideReply(calls) { return swift }
        let ran = actionRan(calls)
        let kept = pieces(reply).compactMap { filter($0, actionRan: ran) }
        if kept.isEmpty { return Py.strip(reply).isEmpty ? reply : notDone }
        return kept.joined(separator: " ")
    }

    /// The text split after each `.`, `!`, `?` or newline, terminators kept.
    static func pieces(_ text: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in text {
            cur.append(ch)
            if ".!?\n".contains(ch) {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static let openers = ["consider it done", "all done", "all set", "done", "sorted", "right away"]

    /// "Done, sir — it's 3:45." gives "It's 3:45."; "Done, sir." gives "". Nil when the piece
    /// does not open with a completion word.
    static func strippedOpener(_ piece: String) -> String? {
        let low = normalise(piece)
        for opener in openers where low.hasPrefix(opener) {
            let after = low.dropFirst(opener.count)
            guard after.isEmpty || !(after.first!.isLetter) else { continue }
            var rest = Substring(piece).dropFirst(opener.count)
            // ", sir", " sir", then any run of punctuation and spaces.
            rest = rest.drop { " ,".contains($0) }
            if rest.lowercased().hasPrefix("sir") && !(rest.dropFirst(3).first?.isLetter ?? false) {
                rest = rest.dropFirst(3)
            }
            rest = rest.drop { " ,.!;:—–-".contains($0) }
            guard let first = rest.first else { return "" }
            return first.uppercased() + rest.dropFirst()
        }
        return nil
    }

    // MARK: - Claim detection

    /// Verbs a finished action is reported with, after "I've" / "I have" / "I just".
    static let verbs = [
        "sent", "set", "added", "created", "played", "started", "turned", "deleted", "removed",
        "moved", "renamed", "saved", "opened", "scheduled", "made", "written", "wrote", "typed",
        "run", "ran", "launched", "switched", "changed", "adjusted", "put", "booked", "emailed",
        "messaged", "texted", "noted", "paused", "skipped", "muted", "unmuted", "queued", "trashed",
        "enabled", "disabled", "toggled", "forgotten", "updated", "restored", "lowered", "raised",
        "increased", "decreased", "rewritten", "taken", "captured", "copied", "notified", "resumed",
        "closed", "dimmed", "brightened", "cranked", "turned up", "turned down", "gone ahead",
    ]
    /// Past forms that are unambiguous after a bare "I" ("I set" can be present tense).
    static let pastAfterBareI: Set<String> = [
        "sent", "played", "started", "turned", "deleted", "created", "added", "saved", "opened",
        "scheduled", "typed", "launched", "switched", "changed", "booked", "emailed", "messaged",
        "texted", "paused", "skipped", "muted", "unmuted", "queued", "moved", "removed", "resumed",
        "closed", "dimmed", "brightened", "cranked", "wrote", "ran", "noted", "restored", "renamed",
    ]
    /// Things whose state is reported done: "the message has been sent", "reminder set".
    static let objects = [
        "message", "text", "email", "reminder", "alarm", "event", "note", "file", "volume",
        "brightness", "timer", "meeting", "appointment", "screenshot", "shortcut", "notification",
        "music", "song", "track", "playback", "app", "settings", "command", "script",
    ]
    static let states = ["sent", "set", "created", "added", "saved", "scheduled", "deleted", "moved",
                         "booked", "taken", "updated", "removed", "on its way", "paused", "muted", "opened",
                         "done", "adjusted", "changed"]
    static let links = [" has been ", " have been ", " is now ", " are now ", " is ", " are ", " was ", " were ", " "]

    static func normalise(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }

    /// Whether one sentence reports an action as done. Questions, offers ("Shall I…", "I'll…")
    /// and negated sentences never do.
    public static func claims(_ sentence: String) -> Bool {
        let trimmed = Py.strip(normalise(sentence))
        guard !trimmed.isEmpty, !trimmed.hasSuffix("?") else { return false }
        let s = " " + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ".!")) + " "
        for neg in [" not ", "n't ", " never ", " unable ", " cannot ", " no longer "] where s.contains(neg) {
            return false
        }
        if strippedOpener(trimmed) != nil { return true }
        // "Now playing: …" is left alone: music_now_playing reports it, and it reads, not acts.
        if s.contains(" successfully ") { return true }
        for subject in [" i've ", " i have ", " i just ", " i "] {
            for verb in verbs where s.contains(subject + verb + " ") || s.contains(subject + "already " + verb + " ") {
                if subject == " i " && !pastAfterBareI.contains(verb) { continue }
                return true
            }
        }
        for object in objects {
            for state in states {
                for link in links where s.contains(" " + object + link + state + " ")
                    || s.contains(" " + object + "s" + link + state + " ") {
                    return true
                }
            }
        }
        return false
    }
}
