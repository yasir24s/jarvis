import Foundation
import JarvisCore
import Observation

/// Batch C part 3: the "JARVIS Memory" window's logic, kept here so it tests headless (D-13; the
/// view is in JarvisApp). It lists the facts with search and filters, adds, edits and deletes
/// them, shows the forgotten bin with restore, and browses the archive read-only.
///
/// Every change goes through `MemoryStore`: the lease, the mass-deletion guard, the forgotten
/// bin and the backups all apply, and nothing here writes a memory file itself. A fact the user
/// adds or edits is stamped `by: "user"`; one the user adds has the source `manual`.
@MainActor
@Observable
public final class MemoryEditor {
    /// The source of a fact the user typed in the Memory window.
    public static let manualSource = "manual"
    /// The window's title, also the Desktop shortcut's name.
    public static let windowTitle = "JARVIS Memory"
    /// The menus' item.
    public static let menuTitle = "Memory…"

    /// Which facts the list shows. Every filter left at nil shows everything.
    public struct Filter: Equatable, Sendable {
        public var query = ""
        /// `MemoryFact.about`: "user", or a person's name.
        public var about: String?
        /// A source kind (`MemoryEditor.sourceKind`): "conversation", "file", "manual", ...
        public var source: String?
        public var writer: FactWriter?
        /// Only facts updated within this many days of now.
        public var withinDays: Int?

        public init(query: String = "", about: String? = nil, source: String? = nil, writer: FactWriter? = nil,
                    withinDays: Int? = nil) {
            self.query = query
            self.about = about
            self.source = source
            self.writer = writer
            self.withinDays = withinDays
        }

        public func admits(_ fact: MemoryFact, now: Double) -> Bool {
            if let about, fact.about != about { return false }
            if let source, MemoryEditor.sourceKind(fact.source) != source { return false }
            if let writer, fact.by != writer { return false }
            if let withinDays, fact.updated < now - Double(withinDays) * 86_400 { return false }
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return true }
            let hay = [fact.text, fact.about, fact.relation ?? "", fact.source]
            return hay.contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The kind of a fact's source: the part before the first colon ("file:<digest>" is "file").
    public nonisolated static func sourceKind(_ source: String) -> String {
        source.split(separator: ":", maxSplits: 1).first.map(String.init) ?? source
    }

    public private(set) var facts: [MemoryFact] = []
    public private(set) var forgotten: [ForgottenFile.Entry] = []
    public private(set) var archive: [ArchiveEntry] = []
    /// The last change's outcome, in plain words, for the window's status line.
    public private(set) var status = ""
    public var filter = Filter()
    public var archiveQuery = ""

    @ObservationIgnored private var store: MemoryStore?
    @ObservationIgnored private let clock: any JarvisClock
    @ObservationIgnored private let makeID: () -> String

    public init(store: MemoryStore? = nil, clock: any JarvisClock = SystemClock(),
                makeID: @escaping () -> String = { UUID().uuidString.lowercased() }) {
        self.store = store
        self.clock = clock
        self.makeID = makeID
    }

    /// Set once the brain has built its memory store (the window may open before that).
    public func attach(_ store: MemoryStore) {
        self.store = store
        reload()
    }

    public var isAvailable: Bool { store != nil }

    /// The facts the filter admits, newest first.
    public var shown: [MemoryFact] {
        let now = clock.now()
        return facts.filter { filter.admits($0, now: now) }.sorted { $0.updated > $1.updated }
    }

    /// The archive's messages matching `archiveQuery`, newest first; at most `limit`.
    public func shownArchive(limit: Int = 500) -> [ArchiveEntry] {
        let q = archiveQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let hits = q.isEmpty ? archive : archive.filter { $0.text.range(of: q, options: .caseInsensitive) != nil }
        return Array(hits.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
    }

    /// The filter pickers' choices, from the facts there are.
    public var aboutChoices: [String] { Array(Set(facts.map(\.about))).sorted() }
    public var sourceChoices: [String] { Array(Set(facts.map { Self.sourceKind($0.source) })).sorted() }

    /// Reads the facts, the bin and the archive again.
    public func reload() {
        guard let store else {
            status = "Memory is not available yet: JARVIS is still starting."
            return
        }
        guard let file = store.loadFacts() else {
            facts = []
            status = "facts.json could not be read, so it was left as it is."
            return
        }
        facts = file.facts
        forgotten = store.loadForgotten()?.entries ?? []
        archive = store.archivedMessages()
    }

    // MARK: - Changes

    /// Adds a fact the user typed. False (with `status` saying why) when it is empty, too long,
    /// already there, or the store would not save.
    @discardableResult
    public func add(_ text: String, about: String = MemoryFact.user, relation: String? = nil) -> Bool {
        guard let store, let line = validated(text) else { return false }
        let now = clock.now(), id = makeID()
        let who = MemoryFact.normalizedAbout(about)
        let rel = relation.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let outcome = store.writeFacts { file in
            guard !file.facts.contains(where: { $0.text == line && $0.about == who }) else { return false }
            file.facts.append(MemoryFact(id: id, text: line, about: who, relation: who == MemoryFact.user ? nil : rel,
                                         source: Self.manualSource, created: now, updated: now, by: .user))
            return true
        }
        return finish(outcome, saved: "Added.", declined: "That fact is already there.")
    }

    /// Changes a fact's text, subject and relation, keeping its id, source and creation time.
    @discardableResult
    public func edit(id: String, text: String, about: String, relation: String?) -> Bool {
        guard let store, let line = validated(text) else { return false }
        let now = clock.now()
        let who = MemoryFact.normalizedAbout(about)
        let rel = relation.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        let outcome = store.writeFacts { file in
            guard let i = file.facts.firstIndex(where: { $0.id == id }) else { return false }
            var f = file.facts[i]
            guard f.text != line || f.about != who || f.relation != rel else { return false }
            f.text = line
            f.about = who
            f.relation = who == MemoryFact.user ? nil : rel
            f.updated = now
            f.by = .user
            file.facts[i] = f
            return true
        }
        return finish(outcome, saved: "Saved.", declined: "Nothing changed, or that fact is gone.")
    }

    /// Moves the facts with these ids to the forgotten bin (kept 30 days). A pick of up to
    /// `MemoryStore.dropLimit` facts is exempt from the mass-deletion guard, as forget_memory's
    /// ids are; a larger pick is not, so the guard refuses it and nothing moves.
    @discardableResult
    public func delete(ids: Set<String>) -> Bool {
        guard let store else { return false }
        let outcome = store.forget(byIDs: ids.count <= MemoryStore.dropLimit) { file in
            Set(file.facts.indices.filter { ids.contains(file.facts[$0].id) })
        }
        return finishMove(outcome, verb: "Forgotten", hint: " They are in the forgotten bin for 30 days.")
    }

    /// Puts the bin's facts with these ids back.
    @discardableResult
    public func restore(ids: Set<String>) -> Bool {
        guard let store else { return false }
        let outcome = store.restore { bin in
            Set(bin.entries.indices.filter { ids.contains(bin.entries[$0].fact.id) })
        }
        return finishMove(outcome, verb: "Restored", hint: "")
    }

    // MARK: - Helpers

    private func validated(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else {
            status = "A fact needs some text."
            return nil
        }
        guard line.count <= MemoryFact.maxLength else {
            status = "A fact is at most \(MemoryFact.maxLength) characters; that one is \(line.count)."
            return nil
        }
        return line
    }

    private func finish(_ outcome: MemoryStore.FactsWrite, saved: String, declined: String) -> Bool {
        switch outcome {
        case .saved: status = saved
        case .declined: status = declined
        case .unreadable: status = "facts.json could not be read, so nothing was changed."
        case .refused(let d, let n): status = "Refused: that would remove \(d) of \(n) facts at once."
        case .notSaved: status = "Not saved: JARVIS does not hold his state lock, or the write failed."
        }
        reload()
        return outcome == .saved
    }

    private func finishMove(_ outcome: MemoryStore.MoveOutcome, verb: String, hint: String) -> Bool {
        var ok = false
        switch outcome {
        case .moved(let facts):
            status = "\(verb) \(facts.count) fact\(facts.count == 1 ? "" : "s").\(hint)"
            ok = true
        case .nothing: status = "Nothing was selected."
        case .unreadable: status = "A memory file could not be read, so nothing was changed."
        case .refused(let d, let n):
            status = "Refused: that would remove \(d) of \(n) facts at once. Delete at most \(MemoryStore.dropLimit) at a time."
        case .notSaved: status = "Not saved: JARVIS does not hold his state lock, or the write failed."
        }
        reload()
        return ok
    }
}

/// Batch C part 3: JARVIS's own URL scheme, `jarvis://`. `jarvis://memory` opens the Memory
/// window; anything else is ignored (and logged by the app).
public enum JarvisURLRoute: Equatable, Sendable {
    public static let scheme = "jarvis"
    case memory

    /// The route for `url`, or nil when it is not one of JARVIS's.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        // `jarvis://memory` has the host "memory"; `jarvis:memory` has it as the path.
        let target = (url.host() ?? url.path(percentEncoded: false))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch target {
        case "memory": self = .memory
        default: return nil
        }
    }
}
