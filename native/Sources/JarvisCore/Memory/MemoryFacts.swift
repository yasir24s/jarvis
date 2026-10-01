import Foundation

// `memory/facts.json` (D-51, P2): what JARVIS has compiled about the user. Native-only and
// written atomically through `StateStore`, like every other state file.

/// Which writer produced (or last confirmed) a fact.
public enum FactWriter: String, Sendable, CaseIterable {
    case local
    case claude
    case both

    /// The writer after `other` also produced the same fact.
    public func merged(with other: FactWriter) -> FactWriter {
        self == other ? self : .both
    }
}

/// One compiled fact: a single line of at most `MemoryFact.maxLength` characters. It is about
/// the user, or (P4) a relationship note about someone in the user's life.
public struct MemoryFact: Sendable, Equatable {
    public static let maxLength = 200
    public static let conversationSource = "conversation"
    /// `about` for a fact about the user, which is also what an entry without the field reads as.
    public static let user = "user"

    public var id: String
    public var text: String
    public var about: String         // "user", or the name of the person the note is about (P4)
    public var relation: String?     // how that person is related to the user ("mother"), if known
    public var source: String        // "conversation", or "file:<digest>" (P3)
    public var created: Double       // epoch seconds
    public var updated: Double       // epoch seconds
    public var by: FactWriter

    public init(id: String, text: String, about: String = MemoryFact.user, relation: String? = nil,
                source: String, created: Double, updated: Double, by: FactWriter) {
        self.id = id
        self.text = text
        self.about = Self.normalizedAbout(about)
        self.relation = relation.flatMap { Py.strip($0).isEmpty ? nil : Py.strip($0) }
        self.source = source
        self.created = created
        self.updated = updated
        self.by = by
    }

    /// True for a fact about the user; false for a note about someone else.
    public var isAboutUser: Bool { about == Self.user }

    /// The fact as recall and every listing show it: a fact about the user is its text, and a
    /// note about someone else is "About <name> (the user's <relation>): <text>".
    public var shown: String {
        guard !isAboutUser else { return text }
        return "About \(about)\(relation.map { " (the user's \($0))" } ?? ""): \(text)"
    }

    /// `about` as stored: trimmed, and "user" when empty or "user" in any case.
    public static func normalizedAbout(_ about: String) -> String {
        let s = Py.strip(about)
        return s.isEmpty || Py.lower(s) == user ? user : s
    }

    /// `about` is always written; `relation` only when it is known.
    var json: JSONValue {
        var members: [JSONObject.Member] = [
            .init(key: "id", value: .string(id)),
            .init(key: "text", value: .string(text)),
            .init(key: "about", value: .string(about)),
        ]
        if let relation { members.append(.init(key: "relation", value: .string(relation))) }
        members += [
            .init(key: "source", value: .string(source)),
            .init(key: "created", value: .double(created)),
            .init(key: "updated", value: .double(updated)),
            .init(key: "by", value: .string(by.rawValue)),
        ]
        return .object(JSONObject(members))
    }

    /// An entry without `about` (every fact written before P4), or with a null one, is about
    /// the user; an `about` or `relation` that is not a string is the wrong shape.
    init?(json: JSONValue) {
        guard let o = json.objectValue,
              let id = o["id"]?.stringValue,
              let text = o["text"]?.stringValue,
              let source = o["source"]?.stringValue,
              let created = o["created"]?.pyFloat,
              let updated = o["updated"]?.pyFloat,
              let by = o["by"]?.stringValue.flatMap(FactWriter.init(rawValue:)),
              let about = Self.optionalString(o["about"]),
              let relation = Self.optionalString(o["relation"])
        else { return nil }
        self.init(id: id, text: text, about: about ?? Self.user, relation: relation, source: source,
                  created: created, updated: updated, by: by)
    }

    /// `.some(nil)` for a missing or null member, `.some(s)` for a string, nil for anything else.
    private static func optionalString(_ value: JSONValue?) -> String?? {
        switch value {
        case nil, .null?: return .some(nil)
        case .string(let s)?: return .some(s)
        default: return nil
        }
    }
}

/// The whole of facts.json: the facts, and how far into archive.jsonl (a byte offset just past
/// the last whole line) the conversation compile has read.
public struct FactsFile: Sendable, Equatable {
    public var compiledThrough: Int
    public var facts: [MemoryFact]

    public init(compiledThrough: Int = 0, facts: [MemoryFact] = []) {
        self.compiledThrough = compiledThrough
        self.facts = facts
    }

    /// `{"compiled_through": n, "facts": [...]}`, indent 1, non-ASCII kept.
    public var data: Data {
        let object = JSONObject([
            .init(key: "compiled_through", value: .int(Int64(compiledThrough))),
            .init(key: "facts", value: .array(facts.map(\.json))),
        ])
        return Data(PyJSON.dumps(.object(object), indent: 1, ensureASCII: false).utf8)
    }

    /// The id of each entry in a facts file's bytes, nil for an entry without a string id
    /// (P6: what the mass-deletion guard counts, including entries `init?(data:)` drops).
    public static func entryIDs(_ data: Data) -> [String?] {
        guard let facts = (try? PyJSON.loads(data))?.objectValue?["facts"]?.arrayValue else { return [] }
        return facts.map { $0.objectValue?["id"]?.stringValue }
    }

    /// nil unless `data` is a facts file. A fact entry of the wrong shape is dropped.
    public init?(data: Data) {
        guard let value = try? PyJSON.loads(data), let o = value.objectValue,
              case .int(let through)? = o["compiled_through"], through >= 0,
              let facts = o["facts"]?.arrayValue
        else { return nil }
        self.init(compiledThrough: Int(through), facts: facts.compactMap(MemoryFact.init(json:)))
    }
}
