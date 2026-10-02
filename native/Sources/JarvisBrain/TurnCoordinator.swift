import Foundation
import JarvisCore
import JarvisTools

/// One command from a channel (plan: M02-M04 §3.5).
public struct UserInput: Sendable, Equatable {
    public let text: String
    public let channel: Channel
    /// Typed text that arrived by paste or drag-and-drop: external content, so the turn
    /// starts tainted (X-8, D-8).
    public let pasted: Bool
    /// UI1 part 4: sent while the reply to the last message was still coming, which stopped it.
    /// The brains get it labelled as more context for the same request (`BrainRouter.addedContext`);
    /// everything else sees the text as typed.
    public let addsContext: Bool
    /// UI1 part 5: the turns an edit of the user's message replaces (that message's turn and
    /// every one after it). Once this turn is taken, history is rewound to before the first of
    /// them and the archive marks them superseded; then it runs as usual.
    public let replacing: [UUID]

    public init(text: String, channel: Channel, pasted: Bool = false, addsContext: Bool = false,
                replacing: [UUID] = []) {
        self.text = text
        self.channel = channel
        self.pasted = pasted
        self.addsContext = addsContext
        self.replacing = replacing
    }
}

/// How `TurnCoordinator.submit` ended.
public enum TurnOutcome: Sendable, Equatable {
    /// Another turn was running. The input was not queued (D-10).
    case busy
    /// Nothing was left after trimming.
    case empty
    /// A pending confirmation took the input; this is its result.
    case confirmation(String)
    /// The fast path answered.
    case fastPath(String)
    /// A typed dismissal ended the conversation; this is JARVIS's answer to it.
    case dismissed(String)
    /// The brain answered.
    case reply(String)
}

/// jarvis.py `fast_path(command)`: a reply for a command handled without the brain, or nil.
/// M7 implements it (its tools go through the gateway with `origin: .fastPath`).
public protocol FastPathRouting: Sendable {
    func route(_ text: String, turn: TurnContext) async -> String?
}

/// The fast path until M7: it never answers.
public struct NoFastPath: FastPathRouting {
    public init() {}
    public func route(_ text: String, turn: TurnContext) async -> String? { nil }
}

/// jarvis.py `handle_one` (plan: M02-M04 §3.5): one turn at a time across every channel.
/// Each turn: trim (empty: nothing happens), then a pending confirmation, then on the text
/// channel a dismissal (P1), then the fast path, then the brain. The coordinator is the only
/// place that builds an `InputPort`, so the model can never confirm its own action.
public actor TurnCoordinator {
    private let brain: BrainRouter
    private let fastPath: any FastPathRouting
    private let confirmations: ConfirmationGate
    private let textPort: InputPort
    /// M9a part 6: the port spoken turns confirm through, carrying the voice confirmation check.
    private let voicePort: InputPort
    private let online: @Sendable () async -> Bool
    private let onTurnStart: (@Sendable (TurnContext) -> Void)?
    private let onConversationEnded: (@Sendable () -> Void)?
    private let archive: (any ExchangeArchiving)?
    private let activity: TurnActivity?
    private var running = false
    /// UI1 part 5: where history stood before each recent turn, by turn id, oldest first; an
    /// edit rewinds to the first replaced turn's mark.
    private var marks: [(turn: UUID, mark: Int)] = []
    static let marksKept = 64

    /// - Parameters:
    ///   - confirmations: the gate the gateway stashes into; pass the same one.
    ///   - textAuthenticator: what a text-channel confirmation must pass (M4: LocalAuthentication).
    ///   - online: Python's `is_online()`, asked only when a turn reaches the brain.
    ///   - onTurnStart: sees each turn's context as it is made (tests, the smoke mode).
    ///   - onConversationEnded: called after a dismissal's reply has gone to the sink. It must
    ///     return at once (the app's starts the distillation in the background).
    ///   - archive: given every accepted turn's message and reply (D-51 P2), after the reply
    ///     has gone to the sink, so it never delays it; a dismissal is archived before
    ///     `onConversationEnded`. A turn refused as `.empty` or `.busy` is not archived.
    ///   - activity: told when each accepted turn begins and ends, so background work (the
    ///     file scanner, D-51 P3) can wait for it.
    ///   - voiceConfirmation: what a spoken confirmation must pass (M9a part 6, D-41); nil means
    ///     the owner check `textAuthenticator` is. M10 adds no voiceprint route (VoiceConfirmation).
    public init(brain: BrainRouter, fastPath: any FastPathRouting = NoFastPath(),
                confirmations: ConfirmationGate, textAuthenticator: any ConfirmAuthenticator,
                online: @escaping @Sendable () async -> Bool,
                onTurnStart: (@Sendable (TurnContext) -> Void)? = nil,
                onConversationEnded: (@Sendable () -> Void)? = nil,
                archive: (any ExchangeArchiving)? = nil,
                activity: TurnActivity? = nil,
                voiceConfirmation: VoiceConfirmation? = nil) {
        self.brain = brain
        self.fastPath = fastPath
        self.confirmations = confirmations
        self.textPort = .text(authenticator: textAuthenticator)
        self.voicePort = .voice(confirming: voiceConfirmation ?? .ownerCheck(textAuthenticator))
        self.online = online
        self.onTurnStart = onTurnStart
        self.onConversationEnded = onConversationEnded
        self.archive = archive
        self.activity = activity
    }

    /// Runs one turn, or returns `.busy` at once if one is already running. A confirmation
    /// or fast-path result goes to `sink` as one sentence, as Python speaks it; the brains
    /// send their own replies. `accepted` is called with the turn's context once the turn is
    /// taken, before any of it runs and before anything reaches `sink`; a submit refused as
    /// `.empty` or `.busy` never calls it. The chat adds its rows there, so a refused submit
    /// shows none.
    public func submit(_ input: UserInput, sink: any ReplySink,
                       accepted: (@Sendable (TurnContext) async -> Void)? = nil) async -> TurnOutcome {
        let text = Py.strip(input.text)
        guard !text.isEmpty else { return .empty }
        guard !running else { return .busy }
        running = true
        defer { running = false }
        activity?.begin()
        defer { activity?.end() }

        if !input.replacing.isEmpty {
            // UI1 part 5: an edit. The replaced turns leave history and are superseded in the
            // archive before this one begins.
            let replaced = Set(input.replacing)
            if let first = marks.filter({ replaced.contains($0.turn) }).map(\.mark).min() {
                await brain.rewindHistory(to: first)
            }
            marks.removeAll { replaced.contains($0.turn) }
            archive?.supersede(turns: input.replacing)
        }
        let started = ContinuousClock.now
        let turn = TurnContext(channel: input.channel, startTainted: input.pasted)
        defer { await turn.close() }
        let turnID = await turn.turnID
        marks.append((turnID, await brain.historyMark()))
        if marks.count > Self.marksKept { marks.removeFirst(marks.count - Self.marksKept) }
        onTurnStart?(turn)
        await accepted?(turn)

        let port: InputPort = input.channel == .text ? textPort : voicePort
        if case .handled(let result) = await confirmations.consume(text, via: port, runIn: turn) {
            if !result.isEmpty { await sink.sentence(result) }
            archive?.record(user: text, reply: result, channel: input.channel, turn: turnID)
            return .confirmation(result)
        }
        // P1: a typed message that is a dismissal as a whole ends the conversation. Python's
        // voice loop answers it without handle_one, so no brain call and no interaction count.
        if input.channel == .text, Dismissal.isTextDismissal(text) {
            await sink.sentence(Dismissal.reply)
            archive?.record(user: text, reply: Dismissal.reply, channel: input.channel, turn: turnID)
            onConversationEnded?()
            return .dismissed(Dismissal.reply)
        }
        if let reply = await fastPath.route(text, turn: turn) {
            if !reply.isEmpty { await sink.sentence(reply) }
            archive?.record(user: text, reply: reply, channel: input.channel, turn: turnID)
            return .fastPath(reply)
        }
        let isOnline = await online()
        let brain = self.brain
        let reply = await withTaskCancellationHandler {
            await brain.process(text, online: isOnline, channel: input.channel, turn: turn, sink: sink,
                                addsContext: input.addsContext)
        } onCancel: {
            // UI1 part 4: stopped. From now on the gateway runs no tool for this turn.
            Task { await turn.close() }
        }
        if Task.isCancelled {
            // UI1 part 4: stopped. Nothing it asked for may run later: a confirmation it stashed
            // is dropped (any earlier one was consumed when this turn began).
            await turn.close()
            await dropConfirmation(stashedSince: started)
        }
        archive?.record(user: text, reply: reply, channel: input.channel, turn: turnID)   // the brain sent it
        return .reply(reply)
    }

    /// Clears the pending confirmation if it was stashed at or after `start`, as the card's
    /// Cancel does: "cancel" is no affirmation, so the gate drops it and runs nothing.
    private func dropConfirmation(stashedSince start: ContinuousClock.Instant) async {
        guard let pending = await confirmations.pending,
              pending.deadline - ConfirmationGate.timeout >= start else { return }
        _ = await confirmations.consume("cancel", via: textPort, runIn: TurnContext(channel: .text))
    }
}
