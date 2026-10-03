import Foundation
import JarvisCore

/// Live fix 1: the on-device model as background work sees it (the file reads, the fact compile,
/// the personality writer, the page summaries). Each call waits until no turn runs and nothing
/// is being said (`TurnActivity.waitUntilQuiet`, with its grace), and runs through
/// `TurnActivity.yielding`, so a turn starting cancels it. A preempted call waits again and
/// starts over with the same prompt, so its caller loses nothing but time. A turn's own model
/// calls never go through this.
public struct YieldingPersonaLLM: PersonaLLM {
    private let base: any PersonaLLM
    private let turns: TurnActivity
    private let sleep: TurnActivity.Sleep
    private let log: @Sendable (String) -> Void

    public init(_ base: any PersonaLLM, turns: TurnActivity,
                sleep: @escaping TurnActivity.Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.base = base
        self.turns = turns
        self.sleep = sleep
        self.log = log
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let base = base
        while true {
            try await turns.waitUntilQuiet(sleep: sleep)
            switch try await turns.yielding({ try await base.complete(system: system, user: user, timeout: timeout) }) {
            case .finished(let reply):
                return reply
            case .preempted:
                log("on-device model: background call gave way to the user; it will start again")
            }
        }
    }
}
