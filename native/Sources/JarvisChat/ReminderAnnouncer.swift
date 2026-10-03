import Foundation

/// F1: how a due alarm or reminder (ReminderSchedule's line) reaches the user. It is spoken in
/// his voice. While a reply is being written (`isBusy`), it is held and spoken once the reply is
/// done, so it follows the reply's speech in the queue instead of cutting in before it. With no
/// voice, the line is posted in the chat instead (`post`), so it is not lost.
///
/// Stop Speaking sticks (`SpeechMute`): while speaking is off (`muted`), nothing is spoken. An
/// urgent line (a timer, alarm, reminder or meeting alert) goes to `alert` instead, a notification
/// and the HUD, so it is not lost; any other line (the unlock greeting, the voiceprint reminder)
/// is posted in the chat. Whether speaking is off is asked as each line goes out, so a held line
/// follows the setting as it is then.
@MainActor
public final class ReminderAnnouncer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How often a held line checks whether the reply is done.
    public static let recheck: Duration = .milliseconds(500)

    private let isBusy: @MainActor () -> Bool
    private let speak: (@MainActor (String) -> Void)?
    private let post: @MainActor (String) -> Void
    private let muted: @MainActor () -> Bool
    private let alert: (@MainActor (String) -> Void)?
    private let sleep: Sleep
    private var held: [(line: String, urgent: Bool)] = []
    private var waiting: Task<Void, Never>?

    /// - Parameters:
    ///   - isBusy: a turn is running (the chat's `responding`).
    ///   - speak: queues the line in his voice; nil when there is no voice.
    ///   - post: shows the line in the chat (used without a voice, or while speaking is off).
    ///   - muted: speaking is off (Stop Speaking).
    ///   - alert: shows an urgent line while speaking is off (a notification and the HUD); nil
    ///     posts it in the chat.
    public init(isBusy: @escaping @MainActor () -> Bool, speak: (@MainActor (String) -> Void)?,
                post: @escaping @MainActor (String) -> Void,
                muted: @escaping @MainActor () -> Bool = { false },
                alert: (@MainActor (String) -> Void)? = nil,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) {
        self.isBusy = isBusy
        self.speak = speak
        self.post = post
        self.muted = muted
        self.alert = alert
        self.sleep = sleep
    }

    /// Lines held until the running turn is done.
    public var heldCount: Int { held.count }

    /// - urgent: a timer, alarm, reminder or meeting alert, which must reach the user even
    ///   while speaking is off.
    public func announce(_ line: String, urgent: Bool = false) {
        held.append((line, urgent))
        if isBusy() {
            waitForIdle()
        } else {
            flush()
        }
    }

    private func flush() {
        let lines = held
        held = []
        for (line, urgent) in lines {
            if muted() {
                if urgent, let alert { alert(line) } else { post(line) }
            } else if let speak {
                speak(line)
            } else {
                post(line)
            }
        }
    }

    private func waitForIdle() {
        guard waiting == nil else { return }
        let sleep = sleep, recheck = Self.recheck
        waiting = Task { @MainActor [weak self] in
            while let self, self.isBusy() {
                do { try await sleep(recheck) } catch { break }
            }
            self?.waiting = nil
            self?.flush()
        }
    }
}
