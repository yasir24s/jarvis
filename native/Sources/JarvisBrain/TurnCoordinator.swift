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

    public init(text: String, channel: Channel, pasted: Bool = false) {
        self.text = text
        self.channel = channel
        self.pasted = pasted
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
    private let online: @Sendable () async -> Bool
    private let onTurnStart: (@Sendable (TurnContext) -> Void)?
    private let onConversationEnded: (@Sendable () -> Void)?
    private var running = false

    /// - Parameters:
    ///   - confirmations: the gate the gateway stashes into; pass the same one.
    ///   - textAuthenticator: what a text-channel confirmation must pass (M4: LocalAuthentication).
    ///   - online: Python's `is_online()`, asked only when a turn reaches the brain.
    ///   - onTurnStart: sees each turn's context as it is made (tests, the smoke mode).
    ///   - onConversationEnded: called after a dismissal's reply has gone to the sink. It must
    ///     return at once (the app's starts the distillation in the background).
    public init(brain: BrainRouter, fastPath: any FastPathRouting = NoFastPath(),
                confirmations: ConfirmationGate, textAuthenticator: any ConfirmAuthenticator,
                online: @escaping @Sendable () async -> Bool,
                onTurnStart: (@Sendable (TurnContext) -> Void)? = nil,
                onConversationEnded: (@Sendable () -> Void)? = nil) {
        self.brain = brain
        self.fastPath = fastPath
        self.confirmations = confirmations
        self.textPort = .text(authenticator: textAuthenticator)
        self.online = online
        self.onTurnStart = onTurnStart
        self.onConversationEnded = onConversationEnded
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

        let turn = TurnContext(channel: input.channel, startTainted: input.pasted)
        defer { await turn.close() }
        onTurnStart?(turn)
        await accepted?(turn)

        let port: InputPort = input.channel == .text ? textPort : .voice
        if case .handled(let result) = await confirmations.consume(text, via: port, runIn: turn) {
            if !result.isEmpty { await sink.sentence(result) }
            return .confirmation(result)
        }
        // P1: a typed message that is a dismissal as a whole ends the conversation. Python's
        // voice loop answers it without handle_one, so no brain call and no interaction count.
        if input.channel == .text, Dismissal.isTextDismissal(text) {
            await sink.sentence(Dismissal.reply)
            onConversationEnded?()
            return .dismissed(Dismissal.reply)
        }
        if let reply = await fastPath.route(text, turn: turn) {
            if !reply.isEmpty { await sink.sentence(reply) }
            return .fastPath(reply)
        }
        let isOnline = await online()
        return .reply(await brain.process(text, online: isOnline, channel: input.channel, turn: turn, sink: sink))
    }
}
