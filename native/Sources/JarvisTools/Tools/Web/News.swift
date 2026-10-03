import Foundation
import JarvisCore

/// `get_news()` (plan: M05-M06 T6.8, G11), Python's `_get_news(4)`: the RSS feed
/// (`JARVIS_NEWS_FEED`, default BBC News, User-Agent `JARVIS/1.0`, 8 s), decoded as UTF-8 with
/// replacement, its item titles found by Python's own pattern (CDATA or not), stripped, the empty
/// ones dropped, `html.unescape`d, and the first four read out. Untrusted: the gateway taints the
/// turn after it runs.
struct GetNews: ToolImpl {
    static let name = "get_news"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let defaultFeed = "https://feeds.bbci.co.uk/news/rss.xml"
    static let userAgent = "JARVIS/1.0"
    static let timeout: Double = 8
    static let count = 4
    static let offline = "I'm offline, sir — I can't fetch the headlines."
    static let none = "I couldn't fetch the headlines, sir."
    static let failed = "I couldn't reach the news service, sir."
    /// `re.findall(r"<item>\s*<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>", xml, re.DOTALL)`.
    static let titlePattern = #"<item>\s*<title>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>"#

    let web: any WebFetching
    let online: @Sendable () async -> Bool
    let feed: String
    let log: @Sendable (String) -> Void

    /// `NEWS_FEED`: the environment's `JARVIS_NEWS_FEED`, else BBC News.
    static func feed(_ environment: [String: String]) -> String {
        environment["JARVIS_NEWS_FEED"] ?? defaultFeed
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard await online() else { return .text(Self.offline) }
        do {
            let body = try await web.get(feed, headers: [("User-Agent", Self.userAgent)], timeout: Self.timeout)
            // PR2: the briefing asks for three (`_get_news(3)`); only the fast path may pass a count.
            var count = Self.count
            if ctx.origin == .fastPath, case .int(let n)? = args["count"] { count = Int(n) }
            return .text(try Self.reply(String(decoding: body, as: UTF8.self), count: count))
        } catch {
            log("news failed: \(WebSearch.describe(error))")
            return .text(Self.failed)
        }
    }

    /// The first `count` headlines of a feed, as Python reads them.
    static func titles(_ xml: String, count: Int) throws -> [String] {
        let found = try PyRegex(titlePattern, dotAll: true).findall(xml)
        return Array(try found.filter { !Py.strip($0).isEmpty }.map { try PyHTML.unescape(Py.strip($0)) }
            .prefix(max(1, count)))
    }

    static func reply(_ xml: String, count: Int) throws -> String {
        let titles = try titles(xml, count: count)
        return titles.isEmpty ? none : "Top headlines. " + titles.joined(separator: " ... ") + "."
    }
}
