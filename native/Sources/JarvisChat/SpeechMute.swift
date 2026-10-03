import Foundation
import JarvisBrain
import JarvisTools
import Observation

/// Stop Speaking sticks: the menus' Stop Speaking silences him now and keeps him silent until the
/// user chooses to hear him again. The mute is its own setting (`speechMuted` in UserDefaults, off
/// until set), so it survives a relaunch and leaves "Speak replies" its old meaning. While muted
/// nothing is spoken: replies typed or said aloud, acknowledgements, the loop's own lines,
/// background lines, Mic Only Mode's speech. Time-critical alerts (timers, alarms, reminders,
/// meetings) are shown as a notification and on the HUD instead (`ReminderAnnouncer`). Unmuted,
/// everything is as it was: "Speak replies" governs typed replies and voice turns are spoken.
/// Only the user unmutes: the menus' "Resume Speaking", or a command such as "resume speaking"
/// (`ResumeSpeakingFastPath`).
@MainActor
@Observable
public final class SpeechMute {
    /// The UserDefaults key.
    public static let defaultsKey = "speechMuted"

    /// Muted; read again from the defaults each time it is asked through `isMuted`.
    public private(set) var muted: Bool {
        didSet { defaults.set(muted, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let cancel: @MainActor () -> Void

    /// - cancel: stops whatever is being spoken or generated now (the voice's `stop`).
    public init(defaults: UserDefaults = .standard, cancel: @escaping @MainActor () -> Void) {
        self.defaults = defaults
        self.cancel = cancel
        muted = defaults.bool(forKey: Self.defaultsKey)
    }

    /// Muted, as stored now, so a change made outside the menu (`defaults write`) holds at once.
    public var isMuted: Bool {
        let stored = defaults.bool(forKey: Self.defaultsKey)
        if stored != muted { muted = stored }
        return muted
    }

    /// Stop Speaking: muted, and what is speaking now stops.
    public func stop() {
        muted = true
        cancel()
    }

    /// The user's own choice to hear him again.
    public func resume() {
        muted = false
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
