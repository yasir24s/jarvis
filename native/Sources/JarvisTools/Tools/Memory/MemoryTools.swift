import Foundation
import JarvisCore

// P4: JARVIS's own memory tools. Native-only (Python has no memory tools), so the schemas are
// NativeToolCatalog's. They read and write memory/facts.json through `MemoryStore`, so every
// write is atomic and holds the lease. forget_memory and correct_memory are executors
// (TaintPolicy): a turn that has read untrusted content never reaches them. Nothing here logs
// a fact's text.

/// What the three replies share.
enum MemoryToolText {
    static let unreadable = "My memory file can't be read just now, so nothing was changed."
    static let notSaved = "My memory could not be saved just now, so nothing was changed."

    /// "- <id>: <the note as recall shows it>"
    static func line(_ fact: MemoryFact) -> String {
        "- \(fact.id): \(fact.shown)"
    }

    static func notes(_ n: Int) -> String {
        n == 1 ? "1 note" : "\(n) notes"
    }

    /// The fact with id `id`, else the only fact whose id starts with it (8 characters or more).
    static func index(of id: String, in facts: [MemoryFact]) -> Int? {
        let id = Py.strip(id)
        guard !id.isEmpty else { return nil }
        if let i = facts.firstIndex(where: { $0.id == id }) { return i }
        guard id.count >= 8 else { return nil }
        let hits = facts.indices.filter { facts[$0].id.hasPrefix(id) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Why a corrected note is refused, for the reply.
    static func reason(_ drop: FactExtraction.Drop) -> String {
        switch drop {
        case .tooLong: "is over \(MemoryFact.maxLength) characters"
        case .notAboutTheUser: "about the user must be a sentence starting 'The user'"
        case .secret: "holds what looks like a password, key or account number"
        case .url: "holds a link"
        case .command: "holds a command"
        case .instruction: "reads as an instruction"
        case .notAboutThePerson: "must name the person it is about"
        case .badPerson: "needs a plain name and relation"
        case .privateDetail: "holds that person's health or identity details, or an identifier"
        case .userNotNamed: "comes from a document that does not name the user"
        }
    }
}

/// `search_memory(query)`: the notes that match, best first (`MemorySearching`: keyword and
/// meaning together), each with its id, at most `limit` of them; the reply says how many
/// matched. A blank query lists the newest notes. Only notes that pass the validator are
/// listed, as only they are ever recalled.
struct SearchMemory: ToolImpl {
    static let name = "search_memory"
    static let schema = NativeToolCatalog.schema(named: name)
    static let limit = 25

    let memory: MemoryStore
    let search: any MemorySearching

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let query = Py.strip(args["query"]?.stringValue ?? "")
        guard let file = memory.loadFacts() else { return .text("My memory file can't be read just now.") }
        let kept = file.facts.filter { FactExtraction.dropReason($0) == nil }
        guard !kept.isEmpty else { return .text("My memory holds no notes yet.") }
        if query.isEmpty {
            let newest = kept.sorted { $0.updated > $1.updated }.prefix(Self.limit)
            return .text("The newest \(newest.count) of \(MemoryToolText.notes(kept.count)) (id: note):\n"
                         + newest.map(MemoryToolText.line).joined(separator: "\n"))
        }
        let hits = search.search(query)
        guard !hits.isEmpty else {
            return .text("No notes match \"\(query)\". My memory holds \(MemoryToolText.notes(kept.count)).")
        }
        let listed = hits.prefix(Self.limit)
        let head = hits.count > listed.count
            ? "The best \(listed.count) of the \(hits.count) notes that match"
            : hits.count == 1 ? "1 note matches" : "\(hits.count) notes match"
        return .text("\(head) \"\(query)\", best first (id: note):\n"
                     + listed.map(MemoryToolText.line).joined(separator: "\n"))
    }
}

/// `forget_memory(ids or query)`: removes the notes with those ids (an id, or the only id that
/// starts with 8 or more of its characters), or, with no ids, the notes that hold `query` as a
/// whole phrase (`FactExtraction.normalized`, so case and punctuation do not matter), at most
/// `queryLimit`: more than that removes nothing. One atomic write. The reply lists exactly what
/// was removed, and any id that was not found.
struct ForgetMemory: ToolImpl {
    static let name = "forget_memory"
    static let schema = NativeToolCatalog.schema(named: name)
    static let queryLimit = 10

    let memory: MemoryStore

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let ids = Self.ids(args["ids"])
        let query = Py.strip(args["query"]?.stringValue ?? "")
        guard !ids.isEmpty || !query.isEmpty else {
            return .text("Give the ids of the notes to forget (from search_memory), or a phrase they contain. "
                         + "Nothing was removed.")
        }
        guard memory.loadFacts() != nil else { return .text(MemoryToolText.unreadable) }
        var removed: [MemoryFact] = [], missing: [String] = [], refusal: String?
        let saved = memory.updateFacts { file in
            var remove = Set<Int>()
            if !ids.isEmpty {
                for id in ids {
                    if let i = MemoryToolText.index(of: id, in: file.facts) { remove.insert(i) } else { missing.append(id) }
                }
            } else {
                let phrase = " " + FactExtraction.normalized(query) + " "
                remove = Set(file.facts.indices.filter {
                    (" " + FactExtraction.normalized(file.facts[$0].shown) + " ").contains(phrase)
                })
                if remove.count > Self.queryLimit {
                    refusal = "\(MemoryToolText.notes(remove.count)) hold \"\(query)\", more than \(Self.queryLimit), "
                        + "so nothing was removed. Use search_memory, then forget them by id."
                    return false
                }
            }
            guard !remove.isEmpty else { return false }
            removed = remove.sorted().map { file.facts[$0] }
            file.facts = file.facts.indices.filter { !remove.contains($0) }.map { file.facts[$0] }
            return true
        }
        if let refusal { return .text(refusal) }
        let notFound = missing.isEmpty ? "" : "\nNo note has the id " + missing.map { "\"\($0)\"" }.joined(separator: ", ") + "."
        guard !removed.isEmpty else {
            return .text(ids.isEmpty ? "No note holds \"\(query)\", so nothing was removed. search_memory finds notes "
                                       + "and their ids."
                                     : "Nothing was removed." + notFound)
        }
        guard saved else { return .text(MemoryToolText.notSaved) }
        return .text("Removed \(MemoryToolText.notes(removed.count)):\n"
                     + removed.map(MemoryToolText.line).joined(separator: "\n") + notFound)
    }

    /// `ids` as a list of strings, or one string of ids split at commas and white space.
    static func ids(_ value: JSONValue?) -> [String] {
        switch value {
        case .array(let items)?:
            return items.compactMap { $0.stringValue }.map { Py.strip($0) }.filter { !$0.isEmpty }
        case .string(let s)?:
            return s.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        default:
            return []
        }
    }
}

/// `correct_memory(id, text?, about?, relation?)`: rewords one note, or says whose it is.
/// `about` "user" makes it the user's and clears its relation; an empty `relation` clears it.
/// The corrected note must pass the validator for its person (`FactExtraction.dropReason`), or
/// nothing changes. Its `updated` becomes now; its id, source and writer stay. The reply shows
/// the note before and after.
struct CorrectMemory: ToolImpl {
    static let name = "correct_memory"
    static let schema = NativeToolCatalog.schema(named: name)

    let memory: MemoryStore
    let clock: any JarvisClock

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let id = Py.strip(args["id"]?.stringValue ?? "")
        let text = args["text"]?.stringValue.map { Py.strip($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let about = args["about"]?.stringValue.map { Py.strip($0) }.flatMap { $0.isEmpty ? nil : $0 }
        let relation = args["relation"]?.stringValue
        guard !id.isEmpty else {
            return .text("Give the id of the note to correct (from search_memory). Nothing was changed.")
        }
        guard text != nil || about != nil || relation != nil else {
            return .text("Give the corrected text, or whose note it is. Nothing was changed.")
        }
        guard memory.loadFacts() != nil else { return .text(MemoryToolText.unreadable) }
        let now = clock.now()
        var reply = ""
        let saved = memory.updateFacts { file in
            guard let i = MemoryToolText.index(of: id, in: file.facts) else {
                reply = "No note has the id \"\(id)\". Nothing was changed."
                return false
            }
            let old = file.facts[i]
            var new = old
            if let text { new.text = text }
            if let about { new.about = MemoryFact.normalizedAbout(about) }
            if new.isAboutUser {
                new.relation = nil
            } else if let relation {
                new.relation = FactExtraction.relation(relation)
            }
            if let why = FactExtraction.dropReason(new) {
                reply = "Not changed: the corrected note \(MemoryToolText.reason(why))."
                return false
            }
            guard new != old else {
                reply = "That note already reads that way. Nothing was changed."
                return false
            }
            new.updated = now
            file.facts[i] = new
            reply = "Corrected \(old.id).\nWas: \(old.shown)\nNow: \(new.shown)"
            return true
        }
        if saved { return .text(reply) }
        return .text(reply.isEmpty || reply.hasPrefix("Corrected") ? MemoryToolText.notSaved : reply)
    }
}
