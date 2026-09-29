import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Observation

/// What the chat sends its turns to: `TurnCoordinator` in the app, a fake in tests.
public protocol TurnSubmitting: Sendable {
    func submit(_ input: UserInput, sink: any ReplySink) async -> TurnOutcome
}

extension TurnCoordinator: TurnSubmitting {}

/// The chat window's state (plan: M02-M04 §3.12, §3.13). It is the `ReplySink` of the text
/// turns it starts: each turn gets a user row and one live assistant row. Deltas stream into
/// the live row as plain text, at 30 Hz or less (`DeltaCoalescer`). On a path that sends no
/// deltas (a confirmation, the fast path, the local model's fixed replies) each sentence
/// advances the row instead. When the turn ends the row is finished and renders as markdown.
@MainActor
@Observable
public final class ChatViewModel: ReplySink {
    /// Shown when a submit is refused because another turn is running (D-10).
    public static let busyNotice = "JARVIS is busy — voice turn in progress."

    public private(set) var messages: [ChatMessage] = []
    /// The last submit was refused because another turn was running (D-10). The draft was
    /// kept and the composer shows `busyNotice`. The next submit clears it.
    public private(set) var busy = false
    /// A turn this window started is running. Until it ends, Return neither sends nor queues
    /// the draft (D-10).
    public private(set) var responding = false
    /// The composer's text and paste flag.
    public var draft = ComposerDraft()
    /// `BackendReporter.last.name` read after this window's latest turn; nil before the first.
    public private(set) var lastBackend: String?

    /// The Speak-replies hook (plan §3.12 `SpeakPolicy`, the next batch). It is called with
    /// each finished assistant row. Nothing sets it in this batch, so no typed reply is spoken.
    @ObservationIgnored public var onReplyFinished: ((ChatMessage) -> Void)?

    @ObservationIgnored private var submitter: (any TurnSubmitting)?
    @ObservationIgnored private var backendName: (@Sendable () async -> String)?
    @ObservationIgnored private var live: LiveReply?
    private let minimumGap: Duration

    /// - Parameters:
    ///   - submitter: where turns go; nil until the brain has started (`connect`).
    ///   - lastBackend: reads the backend that served the latest turn, for the menu line.
    ///   - minimumGap: the shortest gap between two live-row updates.
    public init(submitter: (any TurnSubmitting)? = nil, lastBackend: (@Sendable () async -> String)? = nil,
                minimumGap: Duration = DeltaCoalescer.interval) {
        self.submitter = submitter
        self.backendName = lastBackend
        self.minimumGap = minimumGap
    }

    /// Called once the brain has started. Until then Return keeps the draft and sends nothing.
    public func connect(_ submitter: any TurnSubmitting, lastBackend: (@Sendable () async -> String)?) {
        self.submitter = submitter
        self.backendName = lastBackend
    }

    public var isConnected: Bool { submitter != nil }

    /// The menu's backend line.
    public var backendLine: String { "Last backend: \(lastBackend ?? "—")" }

    /// The composer saw a paste or a drop (X-8).
    public func notePaste() {
        draft.notePaste()
    }

    /// Sends the draft as one text turn. Returns the running turn, or nil when nothing was
    /// sent: the draft is empty after trimming, a turn from this window is still running, or
    /// the brain has not started. If the coordinator answers `.busy` the rows are withdrawn,
    /// the draft comes back with its paste flag, and `busy` is set (D-10).
    @discardableResult
    public func send() -> Task<Void, Never>? {
        guard !responding, let submitter, let input = draft.input else { return nil }
        let sent = draft
        draft = ComposerDraft()
        busy = false
        let user = ChatMessage(role: .user, text: Py.strip(sent.text), phase: .finished)
        let reply = ChatMessage(role: .assistant, text: "", phase: .streaming)
        messages.append(user)
        messages.append(reply)
        responding = true
        live = LiveReply(id: reply.id, coalescer: DeltaCoalescer(minimumGap: minimumGap))
        return Task {
            let outcome = await submitter.submit(input, sink: self)
            self.finish(outcome, sent: sent, userID: user.id)
            if outcome != .busy, outcome != .empty, let backendName = self.backendName {
                self.lastBackend = await backendName()
            }
        }
    }

    // MARK: - ReplySink

    public func delta(_ text: String) async {
        let now = ContinuousClock.now
        guard !text.isEmpty, let step = live?.coalescer.append(text, at: now) else { return }
        switch step {
        case .publish:
            live?.flush?.cancel()
            live?.flush = nil
            publishDeltas(at: now)
        case .hold(let deadline):
            scheduleFlush(at: deadline)
        }
    }

    public func sentence(_ text: String) async {
        guard var turn = live else { return }
        turn.sentences.append(text)
        live = turn
        if turn.coalescer.text.isEmpty {
            setRowText(turn.shownText, of: turn.id)
        }
    }

    // MARK: - Private

    /// The live assistant row of the running turn.
    private struct LiveReply {
        let id: UUID
        var coalescer: DeltaCoalescer
        var sentences: [String] = []
        var flush: Task<Void, Never>?

        /// What streamed into the row: the deltas, or the sentences on a path that sends none.
        var shownText: String {
            coalescer.text.isEmpty ? sentences.joined(separator: " ") : coalescer.text
        }
    }

    private func publishDeltas(at now: ContinuousClock.Instant) {
        guard let id = live?.id, let text = live?.coalescer.publish(at: now) else { return }
        setRowText(text, of: id)
    }

    private func scheduleFlush(at deadline: ContinuousClock.Instant) {
        guard let turn = live, turn.flush == nil else { return }
        let id = turn.id
        live?.flush = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.flushHeld(for: id)
        }
    }

    private func flushHeld(for id: UUID) {
        guard live?.id == id else { return }
        live?.flush = nil
        publishDeltas(at: .now)
    }

    private func setRowText(_ text: String, of id: UUID) {
        guard let index = messages.lastIndex(where: { $0.id == id }) else { return }
        messages[index].text = text
    }

    private func finish(_ outcome: TurnOutcome, sent: ComposerDraft, userID: UUID) {
        guard let turn = live else { return }
        turn.flush?.cancel()
        live = nil
        responding = false
        switch outcome {
        case .busy, .empty:
            // Refused, not queued (D-10): the rows go and the draft comes back, paste flag too.
            messages.removeAll { $0.id == userID || $0.id == turn.id }
            draft = ComposerDraft(text: sent.text + draft.text, pasted: sent.pasted || draft.pasted)
            busy = outcome == .busy
        case .confirmation(let reply), .fastPath(let reply), .reply(let reply):
            guard let index = messages.lastIndex(where: { $0.id == turn.id }) else { return }
            let text = ReplyText.finished(reply: reply, shown: turn.shownText)
            if text.isEmpty {
                messages.remove(at: index)
                return
            }
            messages[index].text = text
            messages[index].phase = .finished
            onReplyFinished?(messages[index])
        }
    }
}
