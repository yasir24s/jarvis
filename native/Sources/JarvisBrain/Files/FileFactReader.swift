import Foundation
import FoundationModels
import JarvisCore
import Synchronization

// D-51 P3, piece 4: one document's text, redacted, read for facts about the user by the
// on-device model alone when it fits, else by Claude in parts (at most ten files an hour),
// then validated and merged into facts.json with `source: file:<digest>`. Logs carry counts
// and a digest prefix, never a path, text or fact.

/// What the on-device budget needs from the model. `SystemLanguageModel` in production; tests
/// inject their own counts and context sizes.
public protocol FileTokenCounting: Sendable {
    var contextSize: Int { get async }
    /// The tokenizer's count; nil where there is none (below macOS 26.4).
    func tokenCount(instructions: String) async throws -> Int?
    func tokenCount(prompt: String) async throws -> Int?
}

/// `SystemLanguageModel` as a `FileTokenCounting`. `contextSize` is back-deployed and reads
/// 4096 before macOS 27; `tokenCount(for:)` needs macOS 26.4.
struct SystemFileTokenCounter: FileTokenCounting {
    let model: SystemLanguageModel

    var contextSize: Int { model.contextSize }

    func tokenCount(instructions: String) async throws -> Int? {
        if #available(macOS 26.4, *) { return try await model.tokenCount(for: Instructions(instructions)) }
        return nil
    }

    func tokenCount(prompt: String) async throws -> Int? {
        if #available(macOS 26.4, *) { return try await model.tokenCount(for: prompt) }
        return nil
    }
}

/// Whether a document fits the on-device model: the reading instructions and the prompt may
/// use `share` of its context together, which leaves the rest for the reply. Counted with
/// the model's tokenizer; where there is none (or it fails), the text may be
/// `FileReading.localCharacterEstimate` characters.
///
/// Measured by `FileBudgetLiveProbeTests` on macOS 27.2 with the real tokenizer: contextSize
/// 8192, so a limit of 4915 tokens; the instructions 226 tokens (799 characters); prose 4.79
/// characters a token. About 22,400 characters of text fit there, and about 10,600 where
/// contextSize reads its back-deployed 4096 (before macOS 27).
public final class LocalFileBudget: Sendable {
    /// The share LocalToolset gives tools and instructions, for the same reason.
    public static let share = 0.6
    /// No prompt longer than this many characters per token of the limit can fit, so it is
    /// not worth counting.
    public static let maxCharactersPerToken = 8

    public struct Measure: Sendable, Equatable {
        public let contextSize: Int
        public let limit: Int                 // tokens for the instructions and the prompt
        public let instructionTokens: Int?    // nil: no tokenizer, the estimate decided
        public let promptTokens: Int?
        public let fits: Bool
    }

    private let counter: any FileTokenCounting
    private let instructionTokens = Mutex<(instructions: String, tokens: Int)?>(nil)   // counted once

    public init(counter: any FileTokenCounting) {
        self.counter = counter
    }

    public static func system(_ model: SystemLanguageModel = .default) -> LocalFileBudget {
        LocalFileBudget(counter: SystemFileTokenCounter(model: model))
    }

    /// Whether `prompt` (which holds `text`) fits with `instructions`, the reader's system text.
    public func measure(text: String, prompt: String,
                        instructions system: String = FileReading.system(userName: "")) async -> Measure {
        let context = await counter.contextSize
        let limit = Int(Double(context) * Self.share)
        let estimate = Measure(contextSize: context, limit: limit, instructionTokens: nil, promptTokens: nil,
                               fits: text.count <= FileReading.localCharacterEstimate)
        guard let instructions = await countInstructions(system) else { return estimate }
        guard prompt.count <= limit * Self.maxCharactersPerToken else {
            return Measure(contextSize: context, limit: limit, instructionTokens: instructions,
                           promptTokens: nil, fits: false)
        }
        guard let tokens = try? await counter.tokenCount(prompt: prompt) else { return estimate }
        return Measure(contextSize: context, limit: limit, instructionTokens: instructions,
                       promptTokens: tokens, fits: instructions + tokens <= limit)
    }

    /// Counted once for the instructions in use (the user's name does not change while the
    /// app runs).
    private func countInstructions(_ instructions: String) async -> Int? {
        if let known = instructionTokens.withLock({ $0 }), known.instructions == instructions { return known.tokens }
        guard let counted = try? await counter.tokenCount(instructions: instructions) else { return nil }
        instructionTokens.withLock { $0 = (instructions, counted) }
        return counted
    }
}

/// Claude's allowance of file reads: at most `limit` in any `window`, on the SuspendingClock.
public final class ClaudeReadQuota: Sendable {
    public typealias Now = @Sendable () -> SuspendingClock.Instant

    private let limit: Int
    private let window: Duration
    private let now: Now
    private let reads = Mutex<[SuspendingClock.Instant]>([])

    public init(limit: Int = FileReading.claudeFilesPerHour, window: Duration = FileReading.claudeWindow,
                now: @escaping Now = { SuspendingClock().now }) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Takes one read when the window has room for it.
    public func take() -> Bool {
        let t = now(), window = window, limit = limit
        return reads.withLock { r in
            r.removeAll { $0.duration(to: t) >= window }
            guard r.count < limit else { return false }
            r.append(t)
            return true
        }
    }

    /// Gives back the newest read taken (Claude never started).
    public func refund() {
        reads.withLock { r in _ = r.popLast() }
    }

    /// How long until the window has room again: zero when it has now.
    public func untilRoom() -> Duration {
        let t = now(), window = window, limit = limit
        return reads.withLock { r in
            r.removeAll { $0.duration(to: t) >= window }
            guard r.count >= limit, let oldest = r.first else { return .zero }
            return window - oldest.duration(to: t)
        }
    }
}

/// Reads one document's text for facts and merges them (D-51 P3).
///
/// 1. The text is redacted (`Redactor`) before either model sees it.
/// 2. It goes to the on-device model alone when it fits `LocalFileBudget`, else to Claude in
///    parts of `FileReading.claudePartCharacters`, if `ClaudeReadQuota` has room.
/// 3. Every call first waits while a turn runs.
/// 4. Every reply line passes P2's validator; the kept lines are merged by `FactMerge` with
///    `source: file:<digest>`, in one atomic write under the lease.
/// 5. (P4) The readers are told the user's name and whose document counts as the user's. A
///    document by or about someone else gives only notes about that person (`about`), and only
///    when its redacted text names the user (`FileReading.namesUser`); otherwise nothing.
///
/// A reader failing, or any part failing, writes nothing, so the file is read again later.
public struct FileFactReader: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    public enum Route: Sendable, Equatable {
        case local
        case claude(parts: Int)
    }

    public enum Outcome: Sendable, Equatable {
        case read(Route, added: Int, updated: Int, dropped: Int)
        case nothingToRead          // no text once redacted and trimmed
        case overClaudeQuota        // needs Claude, and this hour's reads are used: not read
        case failed(String)         // a reader failed; the reason holds no text. Nothing written
        case notSaved               // facts.json unreadable, or the write was refused
        case cancelled
    }

    private let memory: MemoryStore
    private let local: any PersonaLLM
    private let claude: any PersonaLLM
    private let budget: LocalFileBudget
    private let quota: ClaudeReadQuota
    private let turns: TurnActivity
    private let vectors: FactVectors?
    private let clock: any JarvisClock
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    /// The Mac account's full name (the app passes `NSFullUserName()`); empty when unknown.
    private let userName: String

    public init(memory: MemoryStore, local: any PersonaLLM, claude: any PersonaLLM, budget: LocalFileBudget,
                quota: ClaudeReadQuota = ClaudeReadQuota(), turns: TurnActivity, vectors: FactVectors? = nil,
                userName: String = "", clock: any JarvisClock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .suspending) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.userName = userName
        self.memory = memory
        self.local = local
        self.claude = claude
        self.budget = budget
        self.quota = quota
        self.turns = turns
        self.vectors = vectors
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    /// Where `text` would go, once redacted.
    public func route(_ text: String, kind: DocumentKind) async -> Route {
        let clean = Redactor.redact(text).text
        return await route(clean: clean, kind: kind).route
    }

    public func read(_ text: String, kind: DocumentKind, digest: String) async -> Outcome {
        let tag = String(digest.prefix(12))
        let clean = Redactor.redact(text).text
        guard !Py.strip(clean).isEmpty else { return .nothingToRead }
        let (route, measure) = await route(clean: clean, kind: kind)
        let replies: [String]
        do {
            switch route {
            case .local:
                try await turns.waitUntilIdle(sleep: sleep)
                replies = [try await local.complete(system: FileReading.system(userName: userName),
                                                    user: FileReading.prompt(clean, kind: kind),
                                                    timeout: FileReading.timeout)]
            case .claude(let count):
                try await turns.waitUntilIdle(sleep: sleep)
                guard quota.take() else { return .overClaudeQuota }
                replies = try await readWithClaude(FileReading.parts(clean), kind: kind, count: count)
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            return .cancelled
        } catch {
            log("files: \(tag) not read (\(PersonaWriterError.reason(error)))")
            return .failed(PersonaWriterError.reason(error))
        }

        let by: FactWriter = route == .local ? .local : .claude
        let named = FileReading.namesUser(clean, userName: userName)
        var candidates: [FactMerge.Candidate] = []
        var dropped = 0
        for reply in replies {
            let parsed = FactExtraction.entries(fromReply: reply, userName: userName, documentNamesUser: named)
            candidates += parsed.entries.map {
                FactMerge.Candidate(text: $0.text, by: by, about: $0.about, relation: $0.relation)
            }
            dropped += parsed.dropped.count
        }
        var counts = (added: 0, updated: 0)
        if !candidates.isEmpty {
            let now = clock.now(), vectors = vectors
            let saved = memory.updateFacts { file in
                counts = FactMerge.merge(candidates, into: &file, source: FileReading.source(digest: digest),
                                         now: now, isSimilar: { vectors?.similar($0, $1) ?? false })
                return true
            }
            guard saved else {
                log("files: \(tag) facts not saved")
                return .notSaved
            }
        }
        let how: String
        switch route {
        case .local:
            let tokens = measure.promptTokens.map { "\($0 + (measure.instructionTokens ?? 0)) of \(measure.limit) tokens" }
                ?? "estimated"
            how = "on-device (\(tokens))"
        case .claude(let count): how = "by Claude in \(count) part(s)"
        }
        log("files: \(tag) read \(how): \(counts.added) new fact(s), \(counts.updated) updated, "
            + "\(dropped) line(s) dropped")
        return .read(route, added: counts.added, updated: counts.updated, dropped: dropped)
    }

    private func route(clean: String, kind: DocumentKind) async -> (route: Route, measure: LocalFileBudget.Measure) {
        let measure = await budget.measure(text: clean, prompt: FileReading.prompt(clean, kind: kind),
                                           instructions: FileReading.system(userName: userName))
        return (measure.fits ? .local : .claude(parts: FileReading.parts(clean).count), measure)
    }

    /// Each part in turn, each after any running turn. Claude never starting (off, offline)
    /// gives the hour's read back.
    private func readWithClaude(_ parts: [String], kind: DocumentKind, count: Int) async throws -> [String] {
        var replies: [String] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { try await turns.waitUntilIdle(sleep: sleep) }
            do {
                replies.append(try await claude.complete(
                    system: FileReading.system(userName: userName),
                    user: FileReading.prompt(part, kind: kind, part: index + 1, of: count),
                    timeout: FileReading.timeout))
            } catch let error as PersonaWriterError where index == 0 && (error == .claudeOff || error == .offline) {
                quota.refund()
                throw error
            }
        }
        return replies
    }
}
