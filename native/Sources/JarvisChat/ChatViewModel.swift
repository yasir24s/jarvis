import Foundation
import JarvisBrain
import JarvisCore
import JarvisTools
import Observation

/// What the chat sends its turns to: `TurnCoordinator` in the app, a fake in tests.
public protocol TurnSubmitting: Sendable {
    /// `accepted` gets the turn's context once the turn is taken, before anything reaches
    /// `sink`. A submit refused as `.busy` or `.empty` never calls it.
    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome
}

extension TurnCoordinator: TurnSubmitting {}

/// The chat window's state (plan: M02-M04 §3.12, §3.13). It is the `ReplySink` of the text
/// turns it starts: each turn gets a user row and one live assistant row. Deltas stream into
/// the live row as plain text, at 30 Hz or less (`DeltaCoalescer`). On a path that sends no
/// deltas (a confirmation, the fast path, the local model's fixed replies) each sentence
/// advances the row instead. When the turn ends the row is finished and renders as markdown.
/// It also holds the confirmation card's state (plan §3.4): the gate's pending confirmation,
/// its Confirm and Cancel buttons, and the refusal when the owner check cannot run.
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
    /// The confirmation the card shows, from `ConfirmationGate.updates`: nil when none is
    /// pending, and cleared at its deadline, since the gate says nothing when one goes stale.
    public private(set) var pending: PendingConfirmation?

    /// The speak policy's hook (plan §3.12 `SpeakPolicy`): each finished assistant row of a
    /// turn, with that turn's summary (its data sources and taint). Rows made here without a
    /// turn (the card's "Cancelled.", the "can't verify" refusal) never come here.
    @ObservationIgnored public var onReplyFinished: ((ChatMessage, TurnSummary) -> Void)?

    @ObservationIgnored private var submitter: (any TurnSubmitting)?
    @ObservationIgnored private var backendName: (@Sendable () async -> String)?
    @ObservationIgnored private var live: LiveReply?
    @ObservationIgnored private var confirmations: ConfirmationGate?
    @ObservationIgnored private var authenticator: (any TextConfirmAuthenticator)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
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

    /// Shows `gate`'s pending confirmation on the card from now on (plan §3.4, §3.12).
    /// `authenticator` is the one the coordinator's text port asks: its `canAuthenticate`
    /// decides the "can't verify" refusal here, before anything is sent.
    public func watchConfirmations(_ gate: ConfirmationGate, authenticator: any TextConfirmAuthenticator) {
        confirmations = gate
        self.authenticator = authenticator
        watcher?.cancel()
        let updates = gate.updates
        watcher = Task { [weak self] in
            for await value in updates {
                guard let self else { return }
                self.show(value)
            }
        }
    }

    /// Sends the draft as one text turn. Returns the running turn, or nil when nothing was
    /// sent: the draft is empty after trimming, a turn from this window is still running, or
    /// the brain has not started. The rows are added only once the coordinator takes the turn.
    /// If it answers `.busy` instead, no row appears, the draft comes back with its paste
    /// flag, and `busy` is set (D-10).
    ///
    /// A typed affirmation while the card shows, on a Mac whose owner check cannot run, is
    /// refused here (plan §3.4): the user row and the refusal are added, nothing is sent, and
    /// the confirmation stays pending until its deadline, for the voice channel.
    @discardableResult
    public func send() -> Task<Void, Never>? {
        guard !responding, let submitter, let input = draft.input else { return nil }
        let sent = draft
        draft = ComposerDraft()
        busy = false
        let shown = Py.strip(sent.text)
        if refusesConfirmation(input.text, now: .now) {
            addLocalReply(to: shown, TextConfirmation.cannotVerify)
            return nil
        }
        return start(input, shown: shown, restoring: sent, via: submitter)
    }

    /// The card's Confirm button (plan §3.4): the same as typing "confirm", with the draft left
    /// alone. A card past its deadline sends nothing and goes (the gate would take "confirm" as
    /// a new command). Returns the running turn, or nil when nothing was sent.
    @discardableResult
    public func confirmPending(now: ContinuousClock.Instant = .now) -> Task<Void, Never>? {
        guard let pending, !responding, let submitter else { return nil }
        guard !TextConfirmation.isStale(pending, now: now) else {
            show(nil)
            return nil
        }
        busy = false
        let input = UserInput(text: TextConfirmation.confirmInput, channel: .text)
        if refusesConfirmation(input.text, now: now) {
            addLocalReply(to: input.text, TextConfirmation.cannotVerify)
            return nil
        }
        return start(input, shown: input.text, restoring: nil, via: submitter)
    }

    /// The card's Cancel button (plan §3.4): the gate is handed "cancel", which clears its slot
    /// without an owner check, then a local "Cancelled." row is added. Nothing goes to the
    /// brain. Returns the task that does it, or nil when no card shows.
    @discardableResult
    public func cancelPending() -> Task<Void, Never>? {
        guard pending != nil, let confirmations, let authenticator else { return nil }
        show(nil)
        return Task {
            _ = await confirmations.consume(TextConfirmation.cancelInput, via: .text(authenticator: authenticator),
                                            runIn: TurnContext(channel: .text))
            self.messages.append(ChatMessage(role: .system, text: TextConfirmation.cancelled, phase: .finished))
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

    /// Starts one text turn. Its rows are added once the coordinator takes it (`accept`), so a
    /// submit refused as `.busy` shows nothing. `restoring` is what a refused turn gives back to
    /// the composer: the sent draft, or nil for the card's Confirm button.
    private func start(_ input: UserInput, shown: String, restoring sent: ComposerDraft?,
                       via submitter: any TurnSubmitting) -> Task<Void, Never> {
        responding = true
        return Task {
            let outcome = await submitter.submit(input, sink: self, accepted: { @MainActor turn in
                self.accept(shown, turn: turn)
            })
            let summary = await self.live?.turn.summary()
            self.finish(outcome, restoring: sent, summary: summary)
            if outcome != .busy, outcome != .empty, let backendName = self.backendName {
                self.lastBackend = await backendName()
            }
        }
    }

    /// The coordinator took the turn: the user row, then the live assistant row.
    private func accept(_ shown: String, turn: TurnContext) {
        let user = ChatMessage(role: .user, text: shown, phase: .finished)
        let reply = ChatMessage(role: .assistant, text: "", phase: .streaming)
        messages.append(user)
        messages.append(reply)
        live = LiveReply(id: reply.id, userID: user.id, turn: turn, coalescer: DeltaCoalescer(minimumGap: minimumGap))
    }

    /// True when `text` would confirm the card's confirmation but the owner check cannot run.
    private func refusesConfirmation(_ text: String, now: ContinuousClock.Instant) -> Bool {
        guard let pending, !TextConfirmation.isStale(pending, now: now), Affirmation.matches(text),
              let authenticator else { return false }
        return !authenticator.canAuthenticate()
    }

    /// A user row and JARVIS's answer to it, made here: nothing was sent to the coordinator.
    private func addLocalReply(to shown: String, _ reply: String) {
        messages.append(ChatMessage(role: .user, text: shown, phase: .finished))
        messages.append(ChatMessage(role: .assistant, text: reply, phase: .finished))
    }

    /// The card shows `value` until the gate replaces or clears it, or its deadline passes.
    private func show(_ value: PendingConfirmation?) {
        expiry?.cancel()
        expiry = nil
        pending = value
        guard let value else { return }
        expiry = Task { [weak self] in
            try? await Task.sleep(until: value.deadline, clock: .continuous)
            guard !Task.isCancelled, let self, self.pending == value else { return }
            self.pending = nil
        }
    }

    /// The live assistant row of the running turn.
    private struct LiveReply {
        let id: UUID
        let userID: UUID
        let turn: TurnContext
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

    private func finish(_ outcome: TurnOutcome, restoring sent: ComposerDraft?, summary: TurnSummary?) {
        let turn = live
        turn?.flush?.cancel()
        live = nil
        responding = false
        switch outcome {
        case .busy, .empty:
            // Refused, not queued (D-10). The coordinator refuses before it takes a turn, so
            // there are no rows to take back; the draft comes back, paste flag too.
            if let turn {
                messages.removeAll { $0.id == turn.userID || $0.id == turn.id }
            }
            if let sent {
                draft = ComposerDraft(text: sent.text + draft.text, pasted: sent.pasted || draft.pasted)
            }
            busy = outcome == .busy
        case .confirmation(let reply), .fastPath(let reply), .reply(let reply):
            guard let turn, let index = messages.lastIndex(where: { $0.id == turn.id }) else { return }
            let text = ReplyText.finished(reply: reply, shown: turn.shownText)
            if text.isEmpty {
                messages.remove(at: index)
                return
            }
            messages[index].text = text
            messages[index].phase = .finished
            if let summary {
                onReplyFinished?(messages[index], summary)
            }
        }
    }
}
