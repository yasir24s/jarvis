import Foundation
import JarvisCore

/// P6b part 5: the gateway's task journal (`MemoryStore.journal`, memory/journal.jsonl). Every call
/// the gateway handles is noted once it is answered, and a confirmed one again when it runs: ran,
/// gated, blocked (a guard or the injection guard) or failed (it threw, the turn was closed, or
/// there is no such tool), with its arguments summarised. The start of the reply is kept, except
/// for a tool that reads (`TaintPolicy.untrusted`: a file, the screen, the clipboard, a web page,
/// messages, the news, memory itself), whose reply is never kept.
public struct ToolJournal: Sendable {
    let memory: MemoryStore

    public init(memory: MemoryStore) {
        self.memory = memory
    }

    func note(_ name: String, _ args: JSONObject, _ result: ToolCallResult) {
        note(name, args, outcome: Self.outcome(result.record.outcome), reply: result.text)
    }

    func note(_ name: String, _ args: JSONObject, outcome: JournalEntry.Outcome, reply: String) {
        memory.journal(tool: name, outcome: outcome, args: args,
                       reply: TaintPolicy.untrusted.contains(name) ? nil : reply)
    }

    static func outcome(_ outcome: ToolRunRecord.Outcome) -> JournalEntry.Outcome {
        switch outcome {
        case .ran: .ran
        case .gated: .gated
        case .blockedTaint, .blockedGuard: .blocked
        case .failed, .unknown: .failed
        }
    }
}
