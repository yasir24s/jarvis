import Foundation
import JarvisCore
import JarvisTools

/// Where `TurnCoordinator` hands each exchange once its reply has gone to the sink (D-51 P2).
/// `record` must return at once and must never log the text.
public protocol ExchangeArchiving: Sendable {
    func record(user: String, reply: String, channel: Channel)
    /// UI1 part 5: the same, with the turn's id on each message, so an edit can supersede it.
    func record(user: String, reply: String, channel: Channel, turn: UUID)
    /// UI1 part 5: an edit replaced these turns.
    func supersede(turns: [UUID])
    /// MEM1 part 3: the same, with the brain that wrote the reply on the reply's line.
    func record(user: String, reply: String, channel: Channel, turn: UUID, brain: ArchiveBrain?)
}

public extension ExchangeArchiving {
    func record(user: String, reply: String, channel: Channel, turn: UUID) {
        record(user: user, reply: reply, channel: channel)
    }

    func record(user: String, reply: String, channel: Channel, turn: UUID, brain: ArchiveBrain?) {
        record(user: user, reply: reply, channel: channel, turn: turn)
    }

    func supersede(turns: [UUID]) {}
}

/// Appends each exchange to `memory/archive.jsonl`: the user's message, then JARVIS's reply
/// when there is one (a confirmation's result, the dismissal reply, a fast-path answer or the
/// brain's reply). Two small O_APPEND writes under the lease. One log line per exchange, with
/// counts only.
///
/// Voice input (M9) comes later: what the user says aloud must reach this same archive, through
/// `record` with the voice channel, so it is compiled, searched and backed up like typed chat.
public struct MemoryArchiver: ExchangeArchiving {
    private let memory: MemoryStore
    private let log: @Sendable (String) -> Void

    public init(memory: MemoryStore,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.memory = memory
        self.log = log
    }

    public func record(user: String, reply: String, channel: Channel) {
        record(user: user, reply: reply, channel: channel, turn: nil)
    }

    public func record(user: String, reply: String, channel: Channel, turn: UUID) {
        record(user: user, reply: reply, channel: channel, turn: Optional(turn))
    }

    public func record(user: String, reply: String, channel: Channel, turn: UUID, brain: ArchiveBrain?) {
        record(user: user, reply: reply, channel: channel, turn: Optional(turn), brain: brain)
    }

    /// UI1 part 5: one supersede line for `turns`; one log line, with the count.
    public func supersede(turns: [UUID]) {
        guard !turns.isEmpty else { return }
        if memory.supersede(turns: turns.map(\.uuidString)) {
            log("memory: superseded \(turns.count) turn(s)")
        } else {
            log("memory: \(turns.count) superseded turn(s) not marked")
        }
    }

    private func record(user: String, reply: String, channel: Channel, turn: UUID?, brain: ArchiveBrain? = nil) {
        var messages = [(MemoryRole.user, user)]
        if !reply.isEmpty { messages.append((.jarvis, reply)) }
        var written = 0
        for (role, text) in messages
        where memory.archive(text, role: role, channel: channel.rawValue, turn: turn?.uuidString,
                             brain: role == .jarvis ? brain?.rawValue : nil) {
            written += 1
        }
        if written == messages.count {
            log("memory: archived \(written) message(s)")
        } else {
            log("memory: \(messages.count - written) of \(messages.count) message(s) not archived")
        }
    }
}
