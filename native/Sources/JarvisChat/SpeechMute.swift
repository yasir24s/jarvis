import Foundation
import JarvisBrain
import JarvisTools

/// Stop Speaking sticks: the menus' Stop Speaking silences him now and turns speaking off until
/// the user turns it back on. The state is the "Speak Replies" setting (`SpeakRepliesToggle`,
/// `speakReplies` in UserDefaults), so it survives a relaunch and there is one source of truth.
/// Off, nothing is spoken: replies typed or said aloud, acknowledgements, the loop's own lines and
/// background lines. Time-critical alerts (timers, alarms, reminders, meetings) are shown as a
/// notification and on the HUD instead (`ReminderAnnouncer`). Only the user turns it back on:
/// the menu's toggle, or a command such as "resume speaking" (`ResumeSpeakingFastPath`).
@MainActor
public final class SpeechMute {
    public let toggle: SpeakRepliesToggle
    private let cancel: @MainActor () -> Void

    /// - cancel: stops whatever is being spoken or generated now (the voice's `stop`).
    public init(toggle: SpeakRepliesToggle, cancel: @escaping @MainActor () -> Void) {
        self.toggle = toggle
        self.cancel = cancel
    }

    /// Off: the setting as it is stored now, so a change made outside the menu holds at once.
    public var isMuted: Bool {
        toggle.refresh()
        return !toggle.isOn
    }

    /// Stop Speaking: speaking goes off, and stays off, and what is speaking now stops.
    public func stop() {
        toggle.isOn = false
        cancel()
    }

    /// The user's own choice to hear him again.
    public func resume() {
        toggle.isOn = true
    }
}

/// The explicit command that turns speaking back on ("you can speak again", "resume speaking",
/// "unmute"), asked before the quick commands. Only a message that is the command as a whole
/// matches, so "unmute the TV" goes on to the brain. The reply is spoken, since speaking is back
/// on by the time it is finished.
public struct ResumeSpeakingFastPath: FastPathRouting {
    public static let reply = "Speaking again, sir."
    static let commands: Set<String> = [
        "you can speak again", "you may speak again", "you can talk again", "speak again",
        "resume speaking", "start speaking again", "unmute", "unmute yourself",
    ]

    private let next: any FastPathRouting
    private let resume: @Sendable () async -> Void

    /// - next: the fast path after this one (the quick commands).
    /// - resume: turns speaking back on (`SpeechMute.resume`).
    public init(next: any FastPathRouting, resume: @escaping @Sendable () async -> Void) {
        self.next = next
        self.resume = resume
    }

    public func route(_ text: String, turn: TurnContext) async -> String? {
        guard Self.matches(text) else { return await next.route(text, turn: turn) }
        await resume()
        return Self.reply
    }

    /// The message, lowercased, without punctuation, a leading "jarvis" or a closing "please" or
    /// "sir", is one of `commands`.
    static func matches(_ text: String) -> Bool {
        let letters = text.lowercased().unicodeScalars.map {
            CharacterSet.letters.contains($0) || $0 == "'" ? Character($0) : " "
        }
        var words = String(letters).split(separator: " ").map(String.init)
        if words.first == "jarvis" { words.removeFirst() }
        while let last = words.last, ["please", "sir", "jarvis"].contains(last) { words.removeLast() }
        return commands.contains(words.joined(separator: " "))
    }
}
