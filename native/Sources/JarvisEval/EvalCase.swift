import Foundation

// OD-EVAL: the labelled synthetic test set (Tests/Fixtures/od-eval/cases.json). Every request
// in it is made up: invented names ("Priya", "Mum"), example.com and 07700 900xxx numbers.

/// One labelled request.
public struct EvalCase: Codable, Sendable, Equatable {
    /// Unique within the fixture, e.g. "music_play-03".
    public var id: String
    public var request: String
    /// The tool a correct turn calls, or "none" when no tool should run.
    public var tool: String
    /// Other tools that also count as a correct choice (find_files for search_files, say).
    public var accept: [String]?
    /// Key arguments, matched loosely: the call's value for the key, lower-cased, must contain
    /// one of the `|`-separated alternatives ("ted lasso", "7|seven").
    public var args: [String: String]?
    /// The reply must contain each of these (case-insensitive; `|` separates alternatives).
    public var mustMention: [String]?
    /// The reply must not claim an action was done. Defaults to true when `tool` is "none".
    public var noClaim: Bool?
    /// What the case exercises: plain, british, typo, indirect, multi, none, confirm, taint,
    /// destructive.
    public var kind: String
    /// "text" (default) or "voice".
    public var channel: String?
    /// The turn starts tainted, as a pasted message does.
    public var tainted: Bool?

    public init(id: String, request: String, tool: String, accept: [String]? = nil,
                args: [String: String]? = nil, mustMention: [String]? = nil, noClaim: Bool? = nil,
                kind: String = "plain", channel: String? = nil, tainted: Bool? = nil) {
        self.id = id
        self.request = request
        self.tool = tool
        self.accept = accept
        self.args = args
        self.mustMention = mustMention
        self.noClaim = noClaim
        self.kind = kind
        self.channel = channel
        self.tainted = tainted
    }

    public static let noTool = "none"

    public var expectsTool: Bool { tool != Self.noTool }
    /// Every tool name that counts as the right choice.
    public var acceptable: Set<String> { Set([tool] + (accept ?? [])).subtracting([Self.noTool]) }
    public var forbidsClaim: Bool { noClaim ?? !expectsTool }
}

/// The fixture file: a version and the cases.
public struct EvalFixture: Codable, Sendable {
    public var version: Int
    public var cases: [EvalCase]

    public init(version: Int = 1, cases: [EvalCase]) {
        self.version = version
        self.cases = cases
    }

    public static func load(_ url: URL) throws -> EvalFixture {
        try JSONDecoder().decode(EvalFixture.self, from: Data(contentsOf: url))
    }

    /// Problems that make the fixture unusable: duplicate ids, unknown tool names.
    public func problems(knownTools: Set<String>) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for c in cases {
            if !seen.insert(c.id).inserted { out.append("duplicate id \(c.id)") }
            for name in [c.tool] + (c.accept ?? []) where name != EvalCase.noTool && !knownTools.contains(name) {
                out.append("\(c.id): unknown tool \(name)")
            }
            if let channel = c.channel, channel != "text", channel != "voice" {
                out.append("\(c.id): channel \(channel)")
            }
        }
        return out
    }
}
