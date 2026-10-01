import Foundation

/// How `search_memory` and `forget_memory` find stored facts (P4): by keyword and by meaning
/// together. JarvisBrain's `MemoryRecall` is the app's; tests pass their own.
public protocol MemorySearching: Sendable {
    /// The facts that match `query`, best first. Only facts that pass the validator
    /// (`FactExtraction.dropReason`) are searched, as only they are ever recalled.
    func search(_ query: String) -> [MemoryFact]

    /// P6b: the archived messages (`MemoryStore.archivedMessages`) that match `query` by
    /// keyword, best first. They are what was said, word for word, so the caller shows them as
    /// information only.
    func searchConversations(_ query: String) -> [ArchiveEntry]

    /// P6b: the task journal's calls (`MemoryStore.journalEntries`) that match `query` by
    /// keyword, best first.
    func searchJournal(_ query: String) -> [JournalEntry]
}
