import Foundation

// memory/forgotten.json (P6, DEV-P6-03, proposed): the facts forget_memory removed, each with the
// time it went, kept for 30 days so restore_memory can bring them back. Native-only, written
// atomically through `StateStore` like facts.json.

/// The whole of forgotten.json: `{"forgotten": [{<the fact's own fields>, "forgotten": t}]}`.
public struct ForgottenFile: Sendable, Equatable {
    /// How long a forgotten fact is kept.
    public static let keptFor: Double = 30 * 86_400

    public struct Entry: Sendable, Equatable {
        public var fact: MemoryFact
        public var forgotten: Double     // epoch seconds

        public init(fact: MemoryFact, forgotten: Double) {
            self.fact = fact
            self.forgotten = forgotten
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }

    /// Indent 1, non-ASCII kept, as facts.json is.
    public var data: Data {
        let rows: [JSONValue] = entries.map { e in
            guard case .object(var o) = e.fact.json else { return e.fact.json }
            o["forgotten"] = .double(e.forgotten)
            return .object(o)
        }
        let object = JSONObject([.init(key: "forgotten", value: .array(rows))])
        return Data(PyJSON.dumps(.object(object), indent: 1, ensureASCII: false).utf8)
    }

    /// nil unless `data` is a forgotten file. An entry of the wrong shape is dropped.
    public init?(data: Data) {
        guard let value = try? PyJSON.loads(data), let rows = value.objectValue?["forgotten"]?.arrayValue else {
            return nil
        }
        self.init(entries: rows.compactMap { row in
            guard let fact = MemoryFact(json: row), let t = row.objectValue?["forgotten"]?.pyFloat else { return nil }
            return Entry(fact: fact, forgotten: t)
        })
    }

    /// The entries forgotten less than `keptFor` ago (or stamped in the future).
    public func purged(now: Double) -> ForgottenFile {
        ForgottenFile(entries: entries.filter { now - $0.forgotten < Self.keptFor })
    }
}
