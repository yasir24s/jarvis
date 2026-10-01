import Foundation
import JarvisCore
import Synchronization

/// Compiles facts about the user when a conversation ends (D-51 P2), beside P1's
/// personality distillation and written by the same two writers.
///
/// 1. Reads the archive from facts.json's `compiled_through` offset: the conversation since
///    the last compile. Nothing new from the user means no writer is asked.
/// 2. The collaborative writer (on-device draft, Claude improves, `FactExtraction.passesCheck`
///    decides) gets `FactExtraction.system` and the transcript of the newest messages.
/// 3. Every line of the reply goes through `FactExtraction.dropReason`; each kept line gets
///    its `by` from which writer wrote it.
/// 4. `FactMerge` folds them in (a duplicate refreshes `updated` and `by`), and the offset
///    moves to the end of what was read, in one atomic write under the lease.
///
/// Both writers failing writes nothing, so the same conversation is read again next time.
/// One compile runs at a time. Logs carry counts only.
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

    public init(memory: MemoryStore, writer: any AttributedWriting, vectors: FactVectors,
                clock: any JarvisClock = SystemClock(),
                makeID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.memory = memory
        self.writer = writer
        self.vectors = vectors
        self.clock = clock
        self.makeID = makeID
        self.log = log
    }

    @discardableResult
    public func compile() async -> Outcome {
        let acquired = running.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard acquired else {
            log("memory: a fact compile is already running")
            return .busy
        }
        defer { running.withLock { $0 = false } }

        guard let start = memory.loadFacts() else {
            log("memory: facts.json unreadable; not compiled")
            return .unreadable
        }
        let (entries, end) = memory.archive(after: start.compiledThrough)
        guard entries.contains(where: { $0.role == .user }) else { return .nothingNew }
        let (transcript, omitted) = FactExtraction.transcript(entries)

        let written: AttributedText
        do {
            written = try await writer.write(system: FactExtraction.system, user: transcript,
                                             timeout: FactExtraction.timeout)
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch {
            log("memory: facts not compiled (\(PersonaWriterError.reason(error)))")
            return .writersFailed
        }

        let vectors = vectors
        let (candidates, dropped) = Self.candidates(from: written, isSimilar: { vectors.similar($0, $1) })
        let now = clock.now(), makeID = makeID
        var counts = (added: 0, updated: 0)
        let saved = memory.updateFacts { file in
            counts = FactMerge.merge(candidates, into: &file, source: MemoryFact.conversationSource, now: now,
                                     isSimilar: { vectors.similar($0, $1) }, makeID: makeID)
            file.compiledThrough = max(file.compiledThrough, end)
            return true
        }
        guard saved else {
            log("memory: facts not saved")
            return .notSaved
        }
        let skipped = omitted > 0 ? "; \(omitted) older message(s) were outside the window" : ""
        log("memory: compiled \(entries.count) message(s): \(counts.added) new fact(s), \(counts.updated) updated, "
            + "\(dropped) line(s) dropped\(skipped)")
        return .compiled(added: counts.added, updated: counts.updated, dropped: dropped)
    }

    /// P6 (the Python-era import): one batch of messages that are not in the archive, through
    /// the same transcript, validator and merge, with the facts tagged `source`. `writer`
    /// replaces this compiler's own (the import's Claude-alone route); `compiled_through` is
    /// left as it is. One compile runs at a time, shared with `compile()`.
    public func compile(entries: [ArchiveEntry], source: String,
                        writer override: (any AttributedWriting)? = nil) async -> Outcome {
        let acquired = running.withLock { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        }
        guard acquired else { return .busy }
        defer { running.withLock { $0 = false } }
        guard memory.loadFacts() != nil else { return .unreadable }
        guard entries.contains(where: { $0.role == .user }) else { return .nothingNew }
        let (transcript, _) = FactExtraction.transcript(entries)
        let written: AttributedText
        do {
            written = try await (override ?? writer).write(system: FactExtraction.system, user: transcript,
                                                           timeout: FactExtraction.timeout)
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch {
            log("memory: a batch was not compiled (\(PersonaWriterError.reason(error)))")
            return .writersFailed
        }
        let vectors = vectors
        let (candidates, dropped) = Self.candidates(from: written, isSimilar: { vectors.similar($0, $1) })
        let now = clock.now(), makeID = makeID
        var counts = (added: 0, updated: 0)
        let saved = memory.updateFacts { file in
            counts = FactMerge.merge(candidates, into: &file, source: source, now: now,
                                     isSimilar: { vectors.similar($0, $1) }, makeID: makeID)
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
