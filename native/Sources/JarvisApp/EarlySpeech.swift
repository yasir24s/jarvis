import Foundation
import JarvisBrain
import JarvisVoice

/// V8, Speak First Sentence Early with Qwen: a typed reply is spoken while the brain is still
/// writing it. The chat's streamed text (`ChatViewModel.onReplyDelta`, what the row shows, so
/// nothing the chat leaves out is said) goes through `EarlySentences`; the reply's speech starts
/// with its first complete sentence (`SpeechQueue.begin`), and each sentence after it is handed
/// to the queue as it completes. When the turn finishes, the part of the final reply after what
/// was already handed over is spoken; a final reply that does not start with that (a rewrite) is
/// logged and nothing more is said. A turn whose first sentence never completed before the reply
/// finished (a brain that sends the reply whole) takes the old path (`finished` returns false).
///
/// The setting is read at a turn's first streamed text (`applies`: Qwen in use, the setting on,
/// speaking not muted); a turn decided against stays on the old path. A stop ends the turn's
/// speech at once, sentences not yet generated too, and nothing more of it is said.
///
/// The acknowledgement still plays first, but waits `acknowledgementWindow` after the send while
/// this applies: a first sentence ready by then is spoken instead of it.
@MainActor
final class EarlySpeech {
    struct Hooks {
        /// Whether a turn starting now is spoken as it is written.
        var applies: () -> Bool
        /// The voice's stop count, for `SpeechQueue.begin(stops:)`.
        var stops: () -> Int
        /// A turn's speech began, with its first sentence; `over` is called once that speech
        /// (or one that replaced it) is over.
        var began: (_ first: String) -> Void
        var over: () -> Void
        /// Each sentence handed to the voice.
        var handed: (String) -> Void
        var log: (String) -> Void
    }

    /// A first sentence ready this soon after the send is spoken without the acknowledgement.
    static let acknowledgementWindow: Duration = .milliseconds(300)
    /// The speak policy's limit (`SpeakRules.replyLimit`): no more is handed over past it.
    static let replyLimit = 600

    private struct Turn {
        let id: UUID
        var sentences = EarlySentences()
        /// What was handed to the voice, in order.
        var spoken: [String] = []
        var characters = 0
        var full = false
    }

    private let queue: SpeechQueue
    private let hooks: Hooks
    private var turn: Turn?
    /// The latest turn decided against, or stopped: nothing more of it is spoken early.
    private var declined: UUID?
    private var stopped: UUID?
    private var sentAt: ContinuousClock.Instant?
    private var pendingAcknowledgement: Task<Void, Never>?
    /// The queue's calls, one after another in the order they were made.
    private var chain: Task<Void, Never>?

    init(queue: SpeechQueue, hooks: Hooks) {
        self.queue = queue
        self.hooks = hooks
    }

    /// The message was sent: plays its acknowledgement through `play`, at once, or after the
    /// window while this applies. Returns whether it was held back.
    @discardableResult
    func acknowledge(sentAt: ContinuousClock.Instant, play: @escaping @MainActor () -> Void) -> Bool {
        self.sentAt = sentAt
        pendingAcknowledgement?.cancel()
        pendingAcknowledgement = nil
        guard hooks.applies() else {
            play()
            return false
        }
        pendingAcknowledgement = Task { [weak self] in
            try? await Task.sleep(until: sentAt + Self.acknowledgementWindow, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.pendingAcknowledgement = nil
            play()
        }
        return true
    }

    /// Streamed text of `turn`'s reply, as the chat row shows it.
    func delta(_ text: String, turn id: UUID) {
        if id == stopped || id == declined { return }
        if turn?.id != id {
            guard hooks.applies() else {
                declined = id
                turn = nil
                return
            }
            turn = Turn(id: id)
        }
        guard var current = turn else { return }
        let sentences = current.sentences.push(text)
        turn = current
        hand(sentences)
    }

    /// The model retracted what `turn`'s row showed (R6): what was not yet handed over is
    /// dropped. What was spoken stays spoken; the final reply will not start with it, so nothing
    /// more is said (`finished`).
    func retracted(turn id: UUID) {
        guard turn?.id == id else { return }
        turn?.sentences = EarlySentences()
        hooks.log("voice: speak-early: the brain retracted a message; what was not yet spoken is dropped")
    }

    /// The turn's reply finished and the speak policy said yes. Returns true when it was handled
    /// here (spoken early, or stopped), false when the old path should speak it whole.
    func finished(_ text: String, turn id: UUID) -> Bool {
        if id == stopped {
            hooks.log("voice: speak-early: the reply was stopped; the rest is not spoken")
            return true
        }
        guard let current = turn, current.id == id else { return false }
        turn = nil
        guard !current.spoken.isEmpty else { return false }
        if let rest = EarlySentences.rest(of: text, after: current.spoken) {
            var tail = EarlySentences()
            turn = current
            hand(tail.push(rest) + tail.finish())
            turn = nil
        } else {
            hooks.log("voice: speak-early: the final reply differs from what streamed; "
                      + "what was said is not said again, and the rest is not spoken")
        }
        let queue = self.queue
        enqueue { await queue.end(turn: id) }
        return true
    }

    /// The turn's reply finished and the speak policy said no (too long for it, say): what was
    /// handed over finishes, and nothing more is said.
    func notSpoken(turn id: UUID) {
        guard let current = turn, current.id == id else { return }
        turn = nil
        guard !current.spoken.isEmpty else { return }
        hooks.log("voice: speak-early: the speak policy declined the finished reply; nothing more is said")
        let queue = self.queue
        enqueue { await queue.end(turn: id) }
    }

    /// Stop, mute, barge-in or push-to-talk: the turn being spoken early takes nothing more, and
    /// an acknowledgement still held back is not played. The queue's own stop does the rest.
    func stop() {
        pendingAcknowledgement?.cancel()
        pendingAcknowledgement = nil
        if let current = turn {
            stopped = current.id
            turn = nil
        }
    }

    private func hand(_ sentences: [String]) {
        guard var current = turn else { return }
        let queue = self.queue
        let id = current.id
        for sentence in sentences {
            if current.full { break }
            let count = sentence.unicodeScalars.count
            if current.characters + count > Self.replyLimit {
                current.full = true
                hooks.log("voice: speak-early: the reply passed \(Self.replyLimit) chars; the rest is shown, not spoken")
                break
            }
            current.characters += count
            if current.spoken.isEmpty { begin(id, first: sentence) }
            current.spoken.append(sentence)
            hooks.handed(sentence)
            enqueue { await queue.sentence(sentence, turn: id) }
        }
        turn = current
    }

    private func begin(_ id: UUID, first: String) {
        if let pending = pendingAcknowledgement {
            pending.cancel()
            pendingAcknowledgement = nil
            hooks.log("voice: speak-early first sentence within \(Self.milliseconds(Self.acknowledgementWindow)) ms "
                      + "of the send; acknowledgement skipped")
        }
        hooks.began(first)
        let queue = self.queue
        let sentAt = self.sentAt
        let stops = hooks.stops()
        enqueue { await queue.begin(turn: id, sentAt: sentAt, stops: stops) }
        let begun = chain
        let over = hooks.over
        Task {
            await begun?.value
            await queue.idle()   // this reply, or one that replaced it, is over
            over()
        }
    }

    private func enqueue(_ call: @escaping @Sendable () async -> Void) {
        let previous = chain
        chain = Task {
            await previous?.value
            await call()
        }
    }

    private static func milliseconds(_ d: Duration) -> Int {
        Int(d / .milliseconds(1))
    }
}
