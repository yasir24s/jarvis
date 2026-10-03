import Foundation

/// F1: how a due alarm or reminder (ReminderSchedule's line) reaches the user. It is spoken in
/// his voice. While a reply is being written (`isBusy`), it is held and spoken once the reply is
/// done, so it follows the reply's speech in the queue instead of cutting in before it. With no
/// voice, the line is posted in the chat instead (`post`), so it is not lost.
@MainActor
public final class ReminderAnnouncer {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How often a held line checks whether the reply is done.
    public static let recheck: Duration = .milliseconds(500)

    private let isBusy: @MainActor () -> Bool
    private let speak: (@MainActor (String) -> Void)?
    private let post: @MainActor (String) -> Void
    private let sleep: Sleep
    private var held: [String] = []
    private var waiting: Task<Void, Never>?

    /// - Parameters:
    ///   - isBusy: a turn is running (the chat's `responding`).
    ///   - speak: queues the line in his voice; nil when there is no voice.
    ///   - post: shows the line in the chat (used only without a voice).
    public init(isBusy: @escaping @MainActor () -> Bool, speak: (@MainActor (String) -> Void)?,
                post: @escaping @MainActor (String) -> Void,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) {
        self.isBusy = isBusy
        self.speak = speak
        self.post = post
        self.sleep = sleep
    }

    /// Lines held until the running turn is done.
    public var heldCount: Int { held.count }

    public func announce(_ line: String) {
        held.append(line)
        if isBusy() {
            waitForIdle()
        } else {
            flush()
        }
    }

    private func flush() {
        let lines = held
        held = []
        for line in lines {
            if let speak { speak(line) } else { post(line) }
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
