import Foundation
import JarvisCore

/// `web_search(query)` (plan: M05-M06 T6.8, G11), Python's `_web_search` step for step:
///
/// 1. Offline (`is_online`): `kb_lookup(query)`, or "I'm offline, sir, so I cannot search the
///    web right now."
/// 2. DuckDuckGo's Instant Answer JSON: `AbstractText`, else `str(Answer)`, else the first
///    `RelatedTopics` entry that is an object with a `Text`. A hit is `kb_remember`ed and
///    returned cut to 800 code points.
/// 3. Wikipedia: opensearch for one title, then its REST summary's `extract`, the same way.
/// 4. `kb_lookup(query)`, or "I found nothing definitive, sir."
///
/// Any failure inside step 2 or 3 (the network, a body that is not the JSON expected, a
/// knowledge-base write that throws) moves on to the next step, as Python's `except Exception`
/// does. Untrusted: the gateway taints the turn after it runs (`TaintPolicy.untrusted`).
/// W1 part 4 adds the deep mode beside this one; this is the quick lookup.
struct WebSearch: ToolImpl {
    static let name = "web_search"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let userAgent = "JARVIS/1.0 (personal assistant)"
    static let timeout: Double = 8
    static let cut = 800
    static let offline = "I'm offline, sir, so I cannot search the web right now."
    static let nothing = "I found nothing definitive, sir."

    let core: CoreState
    let web: any WebFetching
    let online: @Sendable () async -> Bool
    let log: @Sendable (String) -> Void

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(try await reply(Query(args["query"])))
    }

    /// `args.get("query", "")` as each use reads it: the URL takes `str(query)`; the knowledge
    /// base takes `(query or "").strip()`, which is "" for a falsy value and raises
    /// AttributeError for any other non-str (`kbError`). Inside a step that raise moves on, as
    /// any failure does; in the last `kb_lookup`, outside every `try`, it ends the tool.
    struct Query {
        let url: String
        let kb: String?
        let kbError: PyError?

        init(_ value: JSONValue?) {
            switch value {
            case nil:
                (url, kb, kbError) = ("", "", nil)
            case let v? where v.stringValue != nil:
                (url, kb, kbError) = (v.stringValue!, v.stringValue!, nil)
            case let v? where !v.pyTruthy:
                (url, kb, kbError) = (PyArgs.str(v), "", nil)
            case let v?:
                (url, kb, kbError) = (PyArgs.str(v), nil, PyError.noAttribute(v, "strip"))
            }
        }
    }

    func reply(_ query: Query) async throws -> String {
        guard await online() else {
            return try await lookup(query) ?? Self.offline
        }
        if let found = await duckDuckGo(query) { return found }
        if let found = await wikipedia(query) { return found }
        return try await lookup(query) ?? Self.nothing
    }

    /// `kb_lookup(query)`.
    private func lookup(_ query: Query) async throws -> String? {
        guard let kb = query.kb else { throw query.kbError ?? PyError(description: "no query") }
        return try await core.kbLookup(kb)
    }

    /// Step 2, nil when it found nothing or failed.
    private func duckDuckGo(_ query: Query) async -> String? {
        let url = "https://api.duckduckgo.com/?" + PyURL.urlencode([
            ("q", query.url), ("format", "json"), ("no_html", "1"), ("skip_disambig", "1"),
        ])
        do {
            guard case .object(let data) = try await json(url) else { throw PyError(description: "not a dict") }
            // `data.get("AbstractText") or (str(data["Answer"]) if data.get("Answer") else None)`
            var result: String?
            if let abstract = data["AbstractText"], abstract.pyTruthy {
                result = try Self.str(abstract)
            } else if let answer = data["Answer"], answer.pyTruthy {
                result = PyArgs.str(answer)
            }
            if result == nil {
                result = try Self.firstRelatedText(data["RelatedTopics"])
            }
            guard let result else { return nil }
            try await remember(query, result)
            return Py.prefix(result, Self.cut)
        } catch {
            log("DDG search: \(Self.describe(error))")
            return nil
        }
    }

    /// Step 3, nil when it found nothing or failed.
    private func wikipedia(_ query: Query) async -> String? {
        let search = "https://en.wikipedia.org/w/api.php?" + PyURL.urlencode([
            ("action", "opensearch"), ("search", query.url), ("limit", "1"), ("format", "json"),
        ])
        do {
            guard case .array(let arr) = try await json(search) else { throw PyError(description: "not a list") }
            guard arr.count >= 2, arr[1].pyTruthy else { return nil }
            guard case .array(let titles) = arr[1], let first = titles.first?.stringValue else {
                throw PyError(description: "no title")
            }
            let title = first.replacingOccurrences(of: " ", with: "_")
            let summary = "https://en.wikipedia.org/api/rest_v1/page/summary/" + PyURL.quote(title)
            guard case .object(let data) = try await json(summary) else { throw PyError(description: "not a dict") }
            guard let value = data["extract"], value.pyTruthy else { return nil }
            let extract = try Self.str(value)
            try await remember(query, extract)
            return Py.prefix(extract, Self.cut)
        } catch {
            log("Wiki search: \(Self.describe(error))")
            return nil
        }
    }

    private func json(_ url: String) async throws -> JSONValue {
        let body = try await web.get(url, headers: [("User-Agent", Self.userAgent)], timeout: Self.timeout)
        return try PyJSON.loads(body)
    }

    /// `kb_remember(query, result)`; a throw is Python's exception inside the step's `try`.
    private func remember(_ query: Query, _ summary: String) async throws {
        guard let kb = query.kb else { throw query.kbError ?? PyError(description: "no query") }
        try await core.kbRemember(topic: kb, summary: summary)
    }

    /// A truthy field used as `result`. Python takes any truthy value and then fails on
    /// `summary[:800]` (an int, a bool, a dict) inside the step's `try`, so it moves on: here a
    /// non-str throws. A list, which Python can slice, is the one value whose reply differs
    /// (Python returns the list itself).
    static func str(_ value: JSONValue) throws -> String {
        guard let s = value.stringValue else { throw PyError(description: "the result is not a str") }
        return s
    }

    /// `for t in data.get("RelatedTopics", [])`: the first object with a truthy `Text`. A
    /// missing key is no topics; a value Python cannot iterate (null, a number) raises.
    static func firstRelatedText(_ topics: JSONValue?) throws -> String? {
        switch topics {
        case nil: return nil
        case .array(let list)?:
            for t in list {
                guard case .object(let o) = t, let text = o["Text"], text.pyTruthy else { continue }
                guard let s = text.stringValue else { throw PyError(description: "Text is not a str") }
                return s
            }
            return nil
        case .string?, .object?: return nil        // iterates characters or keys: none is a dict
        default: throw PyError(description: "RelatedTopics is not iterable")
        }
    }

    /// An error for the log: its kind, never the URL (which holds the query).
    static func describe(_ error: Error) -> String {
        if let e = error as? WebFetchError, case .status = e { return e.description }
        return String(describing: type(of: error))
    }
}
