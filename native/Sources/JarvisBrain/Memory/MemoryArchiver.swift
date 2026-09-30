import Foundation
import JarvisCore
import JarvisTools

/// Where `TurnCoordinator` hands each exchange once its reply has gone to the sink (D-51 P2).
/// `record` must return at once and must never log the text.
public protocol ExchangeArchiving: Sendable {
    func record(user: String, reply: String, channel: Channel)
}

/// Appends each exchange to `memory/archive.jsonl`: the user's message, then JARVIS's reply
/// when there is one (a confirmation's result, the dismissal reply, a fast-path answer or the
/// brain's reply). Two small O_APPEND writes under the lease. One log line per exchange, with
/// counts only.
public struct MemoryArchiver: ExchangeArchiving {
    private let memory: MemoryStore
    private let log: @Sendable (String) -> Void

    public init(memory: MemoryStore,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.memory = memory
        self.log = log
    }

    public func record(user: String, reply: String, channel: Channel) {
        var messages = [(MemoryRole.user, user)]
        if !reply.isEmpty { messages.append((.jarvis, reply)) }
        var written = 0
        for (role, text) in messages where memory.archive(text, role: role, channel: channel.rawValue) {
            written += 1
        }
        if written == messages.count {
            log("memory: archived \(written) message(s)")
        } else {
            log("memory: \(messages.count - written) of \(messages.count) message(s) not archived")
        }
    }
}
