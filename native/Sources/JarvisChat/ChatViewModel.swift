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
    /// A turn this window started is running. UI1 part 4: Return while it runs stops it and
    /// sends the draft after it as added context (`send`).
    public private(set) var responding = false
    /// UI1 part 4: a reply of this window's is being spoken, or its speech made; set by the app.
    public var speaking = false
    /// UI1 part 4: a reply is being written or spoken, so the send button is Stop and Esc stops.
    public var canStop: Bool { responding || speaking }
    /// The composer's text and paste flag.
    public var draft = ComposerDraft()
    /// `BackendReporter.last.name` read after this window's latest turn; nil before the first.
    public private(set) var lastBackend: String?
    /// The confirmation the card shows, from `ConfirmationGate.updates`: nil when none is
    /// pending, and cleared at its deadline, since the gate says nothing when one goes stale.
    public private(set) var pending: PendingConfirmation?
    /// Set by the chat window: whether it is the active window (an input to the speak policy).
    public var windowIsKey = false
    /// When the user last typed in the composer or sent from this window, by `clock`; nil
    /// before either. A live update never swaps within 10 minutes of it (U1, `UpdateRule`).
    @ObservationIgnored public private(set) var lastUse: Double?
    /// Kept by the chat view as the user scrolls (U1 hands them over): the row at the top of
    /// the transcript, and whether it is scrolled to the bottom.
    @ObservationIgnored public var scrollTop: UUID?
    @ObservationIgnored public var scrolledToBottom = true
    /// A scroll position a live update restored, for the chat view to apply once.
    public private(set) var scrollRequest: ChatScrollRequest?

    /// The speak policy's hook (plan §3.12 `SpeakPolicy`): each finished assistant row of a
    /// turn, with that turn's summary (its data sources and taint). Rows made here without a
    /// turn (the card's "Cancelled.", the "can't verify" refusal) never come here.
    @ObservationIgnored public var onReplyFinished: ((ChatMessage, TurnSummary) -> Void)?
    /// V1 part 1: each typed message the composer sends, with the moment it was sent, before
    /// its turn starts (the voice's acknowledgement). A refused confirmation is not sent.
    @ObservationIgnored public var onSend: ((String, ContinuousClock.Instant) -> Void)?
    /// V1 part 5: each change to the composer's text (the voice warms up while the user types).
    @ObservationIgnored public var onTyping: (() -> Void)?
    /// UI1 part 3, the HUD: a turn from this window was taken, with the message as shown; and
    /// that turn ended, after `onReplyFinished`, so a reply to be spoken is already queued.
    @ObservationIgnored public var onTurnBegan: ((String) -> Void)?
    @ObservationIgnored public var onTurnEnded: (() -> Void)?
    /// UI1 part 4: stops the app's voice (Stop, and a message sent while he speaks).
    @ObservationIgnored public var onStopSpeech: (() -> Void)?

    @ObservationIgnored private var submitter: (any TurnSubmitting)?
    @ObservationIgnored private var backendName: (@Sendable () async -> String)?
    @ObservationIgnored private var live: LiveReply?
    @ObservationIgnored private var confirmations: ConfirmationGate?
    @ObservationIgnored private var authenticator: (any TextConfirmAuthenticator)?
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// UI1 part 4: the running turn's task, and its number: a turn that ends after a newer one
    /// was started leaves the newer one's state alone.
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Stop came before the coordinator took the turn: it is stopped as soon as it is.
    @ObservationIgnored private var stopBeforeAccept = false
    @ObservationIgnored private let clock: any JarvisClock
    private let minimumGap: Duration

    /// - Parameters:
    ///   - submitter: where turns go; nil until the brain has started (`connect`).
    ///   - lastBackend: reads the backend that served the latest turn, for the menu line.
    ///   - minimumGap: the shortest gap between two live-row updates.
    ///   - clock: stamps `lastUse`.
    public init(submitter: (any TurnSubmitting)? = nil, lastBackend: (@Sendable () async -> String)? = nil,
                minimumGap: Duration = DeltaCoalescer.interval, clock: any JarvisClock = SystemClock()) {
        self.submitter = submitter
        self.backendName = lastBackend
        self.minimumGap = minimumGap
        self.clock = clock
    }

    /// Called once the brain has started. Until then Return keeps the draft and sends nothing.
    public func connect(_ submitter: any TurnSubmitting, lastBackend: (@Sendable () async -> String)?) {
        self.submitter = submitter
        self.backendName = lastBackend
    }

    public var isConnected: Bool { submitter != nil }

    /// The row shown when chat is off because the state store or the brain did not start.
    /// `log` is the log file's path, with ~ for the home folder.
    public static func startFailedNotice(log: String) -> String {
        "Chat is off: JARVIS could not start its brain. The reason is in the log, \(log)."
    }

    /// The state store or the brain did not start, so no turn can run: one system row says so
    /// and names the log, instead of a window that silently sends nothing. A second call adds
    /// nothing.
    public func startFailed(log: String) {
        let text = Self.startFailedNotice(log: log)
        guard !messages.contains(where: { $0.role == .system && $0.text == text }) else { return }
        messages.append(ChatMessage(role: .system, text: text, phase: .finished))
    }

    /// P6: a message JARVIS posts himself, outside any turn (the first-run offer to learn from
    /// the user's files): one finished assistant row, never sent to the brain and never spoken.
    /// A second call with the same text adds nothing.
    public func post(_ text: String) {
        guard !messages.contains(where: { $0.role == .assistant && $0.text == text }) else { return }
        messages.append(ChatMessage(role: .assistant, text: text, phase: .finished))
    }

    /// The menu's backend line.
    public var backendLine: String { "Last backend: \(lastBackend ?? "—")" }

    /// The composer saw a paste or a drop (X-8).
    public func notePaste() {
        draft.notePaste()
    }

    /// The composer's text changed: the user is typing (`lastUse`, and `onTyping`).
    public func noteTyping() {
        lastUse = clock.now()
        onTyping?()
    }

    /// The restored scroll position, once: the chat view applies it and it is gone.
    public func takeScrollRequest() -> ChatScrollRequest? {
        defer { scrollRequest = nil }
        return scrollRequest
    }

    /// A live update's restore (Resume.swift): the rows it hands over, and where to scroll.
    func replaceMessages(_ rows: [ChatMessage]) {
        messages = rows
    }

    func requestScroll(_ request: ChatScrollRequest) {
        scrollRequest = request
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
    ///
    /// UI1 part 4: sent while he replies. A reply being written is stopped (`stop`), and this
    /// message is sent once that turn has ended, marked as added context for the same request
    /// (`UserInput.addsContext`); the history it is sent with holds the user's last message and
    /// the reply as far as it got. A reply that is only being spoken stops speaking, and this
    /// message is sent as usual.
    @discardableResult
    public func send() -> Task<Void, Never>? {
        lastUse = clock.now()
        guard let submitter, let input = draft.input else { return nil }
        let interrupted = responding ? stop() : nil
        if responding && interrupted == nil { return nil }
        if speaking { stopSpeech() }
        let sent = draft
        draft = ComposerDraft()
        busy = false
        let shown = Py.strip(sent.text)
        if refusesConfirmation(input.text, now: .now) {
            addLocalReply(to: shown, TextConfirmation.cannotVerify)
            return nil
        }
        onSend?(shown, .now)
        let turnInput = interrupted == nil ? input
            : UserInput(text: input.text, channel: input.channel, pasted: input.pasted, addsContext: true)
        return start(turnInput, shown: shown, restoring: sent, via: submitter, after: interrupted)
    }

    /// UI1 part 4: Stop, the send button's other face, and Esc. Speech stops. A reply being
    /// written stops where it is: its turn is closed, so the gateway runs no tool for it, and
    /// cancelled, so the brain stops (the Claude process, or the local model's generation) and
    /// its MCP turn is revoked. The row keeps what was shown, marked stopped, and is never
    /// spoken. Returns the stopped turn's task, or nil when no turn was running.
    @discardableResult
    public func stop() -> Task<Void, Never>? {
        stopSpeech()
        guard responding, let task = running else { return nil }
        if live == nil {
            stopBeforeAccept = true
        } else {
            markLiveStopped()
        }
        task.cancel()
        return task
    }

    /// The card's Confirm button (plan §3.4): the same as typing "confirm", with the draft left
    /// alone. A card past its deadline sends nothing and goes (the gate would take "confirm" as
    /// a new command). Returns the running turn, or nil when nothing was sent.
    @discardableResult
    public func confirmPending(now: ContinuousClock.Instant = .now) -> Task<Void, Never>? {
        lastUse = clock.now()
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
        lastUse = clock.now()
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
        guard !text.isEmpty, live?.stopped == false, let step = live?.coalescer.append(text, at: now) else { return }
        switch step {
        case .publish:
            live?.flush?.cancel()
            live?.flush = nil
            publishDeltas(at: now)
        case .hold(let deadline):
            scheduleFlush(at: deadline)
        }
    }

    /// R6 (plan §3.6): the model retracted a message after a refusal. `ReplySink` carries no
    /// message boundaries, so everything the live row has shown since the turn began, or since
    /// the last retraction, is taken as that message's: it stays as a finished row, struck
    /// through, and what follows streams into a new live row. Emitted sentences still stand,
    /// since the turn's reply, which includes them, finishes the new row. A retraction with
    /// nothing shown changes nothing.
    public func retracted(messageID: String) async {
        guard let turn = live, !turn.stopped, let index = messages.lastIndex(where: { $0.id == turn.id }) else { return }
        let shown = Py.strip(turn.shownText)
        guard !shown.isEmpty else { return }
        turn.flush?.cancel()
        messages[index].text = shown
        messages[index].phase = .finished
        messages[index].retracted = true
        let next = ChatMessage(role: .assistant, text: "", phase: .streaming)
        messages.append(next)
        live = LiveReply(id: next.id, userID: turn.userID, turn: turn.turn, coalescer: DeltaCoalescer(minimumGap: minimumGap))
    }

    public func sentence(_ text: String) async {
        guard var turn = live, !turn.stopped else { return }
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
    ///
    /// UI1 part 4: `previous` is a stopped turn this one follows: it is sent once that has ended.
    /// Stopped before then, it is never sent and its text goes back to the composer.
    private func start(_ input: UserInput, shown: String, restoring sent: ComposerDraft?,
                       via submitter: any TurnSubmitting, after previous: Task<Void, Never>? = nil) -> Task<Void, Never> {
        responding = true
        generation += 1
        let mine = generation
        let task = Task {
            if let previous { await previous.value }
            if Task.isCancelled {
                self.notSent(sent, generation: mine)
                return
            }
            let outcome = await submitter.submit(input, sink: self, accepted: { @MainActor turn in
                self.accept(shown, turn: turn)
            })
            let summary = await self.live?.turn.summary()
            self.finish(outcome, restoring: sent, summary: summary, generation: mine)
            if outcome != .busy, outcome != .empty, let backendName = self.backendName {
                self.lastBackend = await backendName()
            }
        }
        running = task
        return task
    }

    /// A turn stopped before it was sent: nothing ran, and the text goes back to the composer.
    private func notSent(_ sent: ComposerDraft?, generation mine: Int) {
        if mine == generation {
            responding = false
            running = nil
            stopBeforeAccept = false
        }
        if let sent {
            draft = ComposerDraft(text: sent.text + draft.text, pasted: sent.pasted || draft.pasted)
        }
    }

    /// The live row keeps what was shown, finished and marked stopped, and takes nothing more.
    /// Its turn is closed at once, so the gateway refuses any tool call it makes from now on.
    private func markLiveStopped() {
        guard var turn = live, !turn.stopped else { return }
        turn.flush?.cancel()
        turn.flush = nil
        turn.stopped = true
        live = turn
        if let index = messages.lastIndex(where: { $0.id == turn.id }) {
            messages[index].text = Py.strip(turn.shownText)
            messages[index].phase = .finished
            messages[index].stopped = true
        }
        let context = turn.turn
        Task { await context.close() }
    }

    private func stopSpeech() {
        speaking = false
        onStopSpeech?()
    }

    /// The coordinator took the turn: the user row, then the live assistant row.
    private func accept(_ shown: String, turn: TurnContext) {
        let user = ChatMessage(role: .user, text: shown, phase: .finished)
        let reply = ChatMessage(role: .assistant, text: "", phase: .streaming)
        messages.append(user)
        messages.append(reply)
        live = LiveReply(id: reply.id, userID: user.id, turn: turn, coalescer: DeltaCoalescer(minimumGap: minimumGap))
        onTurnBegan?(shown)
        if stopBeforeAccept {
            stopBeforeAccept = false
            markLiveStopped()
        }
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
        /// UI1 part 4: the user stopped it.
        var stopped = false

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

    private func finish(_ outcome: TurnOutcome, restoring sent: ComposerDraft?, summary: TurnSummary?,
                        generation mine: Int) {
        let turn = live
        turn?.flush?.cancel()
        live = nil
        if mine == generation {
            responding = false
            running = nil
            stopBeforeAccept = false
        }
        defer { if turn != nil { onTurnEnded?() } }
        // UI1 part 4: a stopped row already shows what came before Stop, and is not spoken.
        if turn?.stopped == true { return }
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
        case .confirmation(let reply), .fastPath(let reply), .dismissed(let reply), .reply(let reply):
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
