import Foundation
import JarvisTools

// The per-turn choice of tools (D-7 amended, see DEVIATIONS). When the whole catalog does not
// fit the context, a turn is offered the tools that fit what the user just said, ranked with the
// sentence vectors long-term recall already uses (`SentenceEmbedding`, cached by `FactVectors`),
// rather than one fixed list.

/// What the choice of tools reads about a turn, besides the token budget.
public struct LocalToolRequest: Sendable, Equatable {
    /// The user's message this turn.
    public var text: String
    /// The user's message before it, so a follow-up such as "turn it up more" still matches.
    public var previousText: String?
    /// The tools the previous turn ran, in the order it ran them. They are offered again.
    public var previousTools: [String]

    public init(text: String = "", previousText: String? = nil, previousTools: [String] = []) {
        self.text = text
        self.previousText = previousText
        self.previousTools = previousTools
    }
}

/// Puts the catalog's tools in the order one turn should be offered them. Nothing is logged
/// here: what the user said, and which tools it ranked, stay out of the log.
public final class LocalToolRanker: Sendable {
    /// The most characters of a turn's text that are embedded. NLEmbedding costs about 0.09 ms
    /// a character (macOS 27: 3 ms for a short command, 454 ms for 5,040 characters), so this
    /// bounds a long paste at a few tens of milliseconds. The end is kept: it is where this
    /// turn's message sits, and usually where a pasted text's question is.
    public static let maxTextCharacters = 300

    /// The most keyword matches that count toward a tool's place (`LocalToolKeywords`).
    public static let maxKeywordHits = 2

    /// This ranker's own cache. Recall's `FactVectors` must not be shared: it forgets every
    /// vector that is not a fact (`retain`), which would drop the tools'.
    private let vectors: FactVectors

    /// - Parameter embedding: the instance recall uses, so there is one NLEmbedding in memory.
    public init(embedding: any SentenceEmbedding) {
        vectors = FactVectors(embedding: embedding)
    }

    /// What is embedded for a tool: its name read as words (`get weather`; the underscored form
    /// ranked worse in a probe of NLEmbedding on macOS 27), then its description.
    static func text(for tool: DynamicTool) -> String {
        tool.name.replacingOccurrences(of: "_", with: " ") + ". " + tool.description
    }

    /// What is embedded for a turn: the previous message and this one, the last
    /// `maxTextCharacters` of them.
    static func text(for request: LocalToolRequest) -> String {
        let joined = [request.previousText, request.text].compactMap { $0 }.joined(separator: " ")
        return String(joined.trimmingCharacters(in: .whitespacesAndNewlines).suffix(maxTextCharacters))
    }

    /// `all` in the order to offer it: `LocalToolset.pinned` first, then find_contact when the
    /// message is about a person (`PersonWords.mentionsPerson`), then the tools in
    /// `request.previousTools` (those in `all`, once each), then every other tool by the cosine
    /// between its text and the request's, highest first, catalog order among equals. nil when
    /// the request has no vector, or no tool does, and the caller then offers the fixed list.
    /// A tool's vector is computed the first time it is needed and kept; the request's is
    /// computed every turn.
    public func order(_ all: [DynamicTool], for request: LocalToolRequest) -> [DynamicTool]? {
        guard let query = vectors.vector(for: Self.text(for: request)) else { return nil }
        let pinned = LocalToolset.pinned.compactMap { name in all.first { $0.name == name } }
        var offered = Set(pinned.map(\.name))
        var carried: [DynamicTool] = []
        // Live fix 3: a message about a person ("find mum", "call Sarah") is always offered
        // find_contact, next after the pinned tools.
        if PersonWords.mentionsPerson(request.text), let contact = all.first(where: { $0.name == "find_contact" }),
           offered.insert(contact.name).inserted {
            carried.append(contact)
        }
        for name in request.previousTools {
            if let tool = all.first(where: { $0.name == name }), offered.insert(name).inserted {
                carried.append(tool)
            }
        }
        var scored = 0
        var rest: [(tool: DynamicTool, hits: Int, score: Double, index: Int)] = []
        let words = LocalToolKeywords.Request(request.text)
        for (index, tool) in all.enumerated() where !offered.contains(tool.name) {
            let score = vectors.vector(forFact: Self.text(for: tool)).flatMap { FactVectors.cosine($0, query) }
            if score != nil { scored += 1 }
            // od/phase2 item 3: tools the message names by keyword come first (up to two
            // keys count), then the cosine. A tool with no vector goes below any cosine.
            let hits = min(LocalToolKeywords.hits(tool.name, in: words), Self.maxKeywordHits)
            rest.append((tool, hits, score ?? -2, index))
        }
        guard scored > 0 || rest.isEmpty else { return nil }
        rest.sort {
            if $0.hits != $1.hits { return $0.hits > $1.hits }
            return $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index
        }
        return pinned + carried + rest.map { $0.tool }
    }
}
