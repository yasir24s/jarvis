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

/// One compiled fact: a single line of at most `MemoryFact.maxLength` characters.
public struct MemoryFact: Sendable, Equatable {
    public static let maxLength = 200
    public static let conversationSource = "conversation"

    public var id: String
    public var text: String
    public var source: String        // "conversation", or "file:<digest>" (P3)
    public var created: Double       // epoch seconds
    public var updated: Double       // epoch seconds
    public var by: FactWriter

    public init(id: String, text: String, source: String, created: Double, updated: Double,
                by: FactWriter) {
        self.id = id
        self.text = text
        self.source = source
        self.created = created
        self.updated = updated
        self.by = by
    }

    var json: JSONValue {
        .object(JSONObject([
            .init(key: "id", value: .string(id)),
            .init(key: "text", value: .string(text)),
            .init(key: "source", value: .string(source)),
            .init(key: "created", value: .double(created)),
            .init(key: "updated", value: .double(updated)),
            .init(key: "by", value: .string(by.rawValue)),
        ]))
    }

    init?(json: JSONValue) {
        guard let o = json.objectValue,
              let id = o["id"]?.stringValue,
              let text = o["text"]?.stringValue,
              let source = o["source"]?.stringValue,
              let created = o["created"]?.pyFloat,
              let updated = o["updated"]?.pyFloat,
              let by = o["by"]?.stringValue.flatMap(FactWriter.init(rawValue:))
        else { return nil }
        self.init(id: id, text: text, source: source, created: created, updated: updated, by: by)
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

    /// nil unless `data` is a facts file. A fact entry of the wrong shape is dropped.
    public init?(data: Data) {
        guard let value = try? PyJSON.loads(data), let o = value.objectValue,
              case .int(let through)? = o["compiled_through"], through >= 0,
              let facts = o["facts"]?.arrayValue
        else { return nil }
        self.init(compiledThrough: Int(through), facts: facts.compactMap(MemoryFact.init(json:)))
    }
}
