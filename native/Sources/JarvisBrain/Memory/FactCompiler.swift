import Foundation
import JarvisCore
import Synchronization

/// Compiles facts about the user when a conversation ends (D-51 P2), beside P1's
/// personality distillation and written by the same two writers.
///
/// 1. Reads the archive from facts.json's `compiled_through` offset: the conversation since
///    the last compile. Nothing new from the user means no writer is asked.
/// 2. P6b: all of it, oldest first, in batches whose transcripts fit
///    `FactExtraction.transcriptLimit` (`FactExtraction.batches`), so no message is left out.
/// 3. For each batch, the collaborative writer (on-device draft, Claude improves,
///    `FactExtraction.passesCheck` decides) gets `FactExtraction.system` and its transcript.
/// 4. Every line of the reply goes through `FactExtraction.dropReason`; each kept line gets
///    its `by` from which writer wrote it.
/// 5. `FactMerge` folds them in (a duplicate refreshes `updated` and `by`), and the offset
///    moves to the end of the batch, in one atomic write under the lease.
///
/// A batch whose writers both fail writes nothing and ends the compile: the batches before it
/// stay compiled, and the next compile starts at that batch. One compile runs at a time. Logs
/// carry counts only.
///
/// W1 part 7b: a long compile yields to the user. Given a `TurnActivity`, each batch first
/// waits while a turn runs, with the same wait the file scan uses (`waitUntilIdle`); cancelled
/// while it waits, the compile stops there with the batches before it saved.
public final class FactCompiler: Sendable {
    /// Embedding cosine at or above which two facts are the same fact.
    public static let duplicateSimilarity = 0.9

    public enum Outcome: Sendable, Equatable {
        case nothingNew                      // no new user message since the last compile
        case busy                            // a compile is already running
        case unreadable                      // facts.json exists and does not parse
        case writersFailed                   // both writers failed: nothing written
        case cancelled                       // stopped while the writers worked: nothing written
        case notSaved                        // the write was refused (no lease) or failed
        case compiled(added: Int, updated: Int, dropped: Int)
    }

    private let memory: MemoryStore
    private let writer: any AttributedWriting
    private let vectors: FactVectors
    private let clock: any JarvisClock
    private let makeID: @Sendable () -> String
    private let log: @Sendable (String) -> Void
    private let running = Mutex(false)
    private let turns: TurnActivity?
    private let sleep: TurnActivity.Sleep

    public init(memory: MemoryStore, writer: any AttributedWriting, vectors: FactVectors,
                turns: TurnActivity? = nil,
                sleep: @escaping TurnActivity.Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                clock: any JarvisClock = SystemClock(),
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.memory = memory
        self.writer = writer
        self.vectors = vectors
        self.turns = turns
        self.sleep = sleep
        self.clock = clock
        self.makeID = makeID
        self.log = log
    }

    /// Compiles every batch past `compiled_through`, oldest first. `.compiled` totals them all;
    /// when a batch fails, its outcome is returned and the batches before it stay saved.
    @discardableResult
    public func compile() async -> Outcome {
        guard acquire() else {
            log("memory: a fact compile is already running")
            return .busy
        }
        defer { running.withLock { $0 = false } }

        guard let start = memory.loadFacts() else {
            log("memory: facts.json unreadable; not compiled")
            return .unreadable
        }
        let read = memory.archiveLines(after: start.compiledThrough)
        guard read.entries.contains(where: { $0.role == .user }) else { return .nothingNew }
        let batches = FactExtraction.batches(read.entries)
        var totals = (added: 0, updated: 0, dropped: 0)
        for (k, range) in batches.enumerated() {
            // The last batch's offset also passes any torn or foreign line after it.
            let end = k == batches.count - 1 ? read.end : read.ends[range.upperBound - 1]
            let outcome = await compileBatch(Array(read.entries[range]), source: MemoryFact.conversationSource,
                                             writer: writer, through: end, failure: "memory: facts not compiled")
            guard case .compiled(let added, let updated, let dropped) = outcome else {
                if outcome == .notSaved { log("memory: facts not saved") }
                if k > 0 {
                    log("memory: compiled \(k) of \(batches.count) batches (\(totals.added) new fact(s), "
                        + "\(totals.updated) updated); the next compile resumes at batch \(k + 1)")
                }
                return outcome
            }
            totals.added += added
            totals.updated += updated
            totals.dropped += dropped
        }
        let inBatches = batches.count > 1 ? " in \(batches.count) batches" : ""
        log("memory: compiled \(read.entries.count) message(s)\(inBatches): \(totals.added) new fact(s), "
            + "\(totals.updated) updated, \(totals.dropped) line(s) dropped")
        return .compiled(added: totals.added, updated: totals.updated, dropped: totals.dropped)
    }

    /// P6 (the Python-era import): messages that are not in the archive, through the same
    /// batches, transcript, validator and merge, with the facts tagged `source`. `writer`
    /// replaces this compiler's own (the import's Claude-alone route); `compiled_through` is
    /// left as it is. The import's batches fit one transcript; one that does not is compiled in
    /// turn, stopping at the first that fails. One compile runs at a time, shared with `compile()`.
    public func compile(entries: [ArchiveEntry], source: String,
                        writer override: (any AttributedWriting)? = nil) async -> Outcome {
        guard acquire() else { return .busy }
        defer { running.withLock { $0 = false } }
        guard memory.loadFacts() != nil else { return .unreadable }
        guard entries.contains(where: { $0.role == .user }) else { return .nothingNew }
        var totals = (added: 0, updated: 0, dropped: 0)
        for range in FactExtraction.batches(entries) {
            let outcome = await compileBatch(Array(entries[range]), source: source, writer: override ?? writer,
                                             through: nil, failure: "memory: a batch was not compiled")
            guard case .compiled(let added, let updated, let dropped) = outcome else { return outcome }
            totals.added += added
            totals.updated += updated
            totals.dropped += dropped
        }
        return .compiled(added: totals.added, updated: totals.updated, dropped: totals.dropped)
    }

    private func acquire() -> Bool {
        running.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
    }

    /// One batch: the writers read its transcript, and the facts are merged in one atomic write
    /// that also moves `compiled_through` on to `through`, when given. A batch with nothing from
    /// the user asks no writer: it only moves the offset. On a writer failure nothing is written,
    /// and `failure` is logged with the reason.
    private func compileBatch(_ entries: [ArchiveEntry], source: String, writer: any AttributedWriting,
                              through: Int?, failure: String) async -> Outcome {
        if Task.isCancelled { return .cancelled }
        if let turns {                                 // W1 part 7b: yield while a turn runs
            do { try await turns.waitUntilIdle(sleep: sleep) } catch { return .cancelled }
        }
        guard entries.contains(where: { $0.role == .user }) else {
            guard let through else { return .compiled(added: 0, updated: 0, dropped: 0) }
            let saved = memory.updateFacts { file in
                file.compiledThrough = max(file.compiledThrough, through)
                return true
            }
            return saved ? .compiled(added: 0, updated: 0, dropped: 0) : .notSaved
        }
        let (transcript, _) = FactExtraction.transcript(entries)
        let written: AttributedText
        do {
            written = try await writer.write(system: FactExtraction.system, user: transcript,
                                             timeout: FactExtraction.timeout)
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch {
            log("\(failure) (\(PersonaWriterError.reason(error)))")
            return .writersFailed
        }
        let vectors = vectors
        let (candidates, dropped) = Self.candidates(from: written, isSimilar: { vectors.similar($0, $1) })
        let now = clock.now(), makeID = makeID
        var counts = (added: 0, updated: 0)
        let saved = memory.updateFacts { file in
            counts = FactMerge.merge(candidates, into: &file, source: source, now: now,
                                     isSimilar: { vectors.similar($0, $1) }, makeID: makeID)
            if let through { file.compiledThrough = max(file.compiledThrough, through) }
            return true
        }
        guard saved else { return .notSaved }
        return .compiled(added: counts.added, updated: counts.updated, dropped: dropped)
    }

    /// The reply's fact lines with their writer: all `local` for the on-device draft, all
    /// `claude` for Claude alone, and for Claude's improvement `both` where the draft had the
    /// same fact (normalised, or `isSimilar`) and `claude` where it did not.
    static func candidates(from written: AttributedText, isSimilar: (String, String) -> Bool)
        -> (candidates: [FactMerge.Candidate], dropped: Int) {
        let parsed = FactExtraction.facts(fromReply: written.text)
        switch written.author {
        case .local:
            return (parsed.facts.map { FactMerge.Candidate(text: $0, by: .local) }, parsed.dropped.count)
        case .claude:
            return (parsed.facts.map { FactMerge.Candidate(text: $0, by: .claude) }, parsed.dropped.count)
        case .improved(let draft):
            let drafted = FactExtraction.facts(fromReply: draft).facts
            let keys = Set(drafted.map(FactExtraction.normalized))
            let candidates = parsed.facts.map { line in
                let inDraft = keys.contains(FactExtraction.normalized(line)) || drafted.contains { isSimilar($0, line) }
                return FactMerge.Candidate(text: line, by: inDraft ? .both : .claude)
            }
            return (candidates, parsed.dropped.count)
        }
    }
}
