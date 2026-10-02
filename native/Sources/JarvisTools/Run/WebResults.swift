import Foundation
import JarvisCore

/// W1 part 4: DuckDuckGo's HTML results page (html.duckduckgo.com), for the deep search and the
/// background reading's topics. No key and no account: one GET. The result links are read from
/// the markup: each `<a class="result__a" href=...>` is a result, its href either the page itself
/// or DuckDuckGo's `/l/?uddg=<page>` redirect; ads (`/y.js` links) are skipped, and so is
/// anything that is not http(s) or that came before.
public enum WebResults {
    public struct Result: Sendable, Equatable {
        public let url: String
        public let title: String

        public init(url: String, title: String) {
            self.url = url
            self.title = title
        }
    }

    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Safari/605.1.15 JARVIS/1.0"
    public static let timeout: Double = 10

    /// The results page for `query`.
    public static func url(_ query: String) -> String {
        "https://html.duckduckgo.com/html/?" + PyURL.urlencode([("q", query)])
    }

    /// The results for `query`, in order, at most `limit`. Throws when the page cannot be fetched.
    public static func search(_ query: String, limit: Int, web: any WebFetching) async throws -> [Result] {
        let body = try await web.get(url(query), headers: [("User-Agent", userAgent)], timeout: timeout)
        return Array(parse(String(decoding: body, as: UTF8.self)).prefix(limit))
    }

    private static let anchor = try! NSRegularExpression(pattern: #"<a\b([^>]*)>(.*?)</a>"#,
                                                         options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let href = try! NSRegularExpression(pattern: #"\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
                                                       options: [.caseInsensitive])
    private static let classes = try! NSRegularExpression(pattern: #"\bclass\s*=\s*(?:"([^"]*)"|'([^']*)')"#,
                                                          options: [.caseInsensitive])
    private static let tags = try! NSRegularExpression(pattern: "<[^>]*>")

    /// The result links of a results page, in order, each once.
    public static func parse(_ html: String) -> [Result] {
        let ns = html as NSString
        var seen = Set<String>(), out: [Result] = []
        for m in anchor.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let attributes = ns.substring(with: m.range(at: 1))
            guard let names = attribute(classes, in: attributes),
                  names.split(separator: " ").contains("result__a"),
                  let raw = attribute(href, in: attributes),
                  let target = destination((try? PyHTML.unescape(raw)) ?? raw),
                  seen.insert(target).inserted
            else { continue }
            let inner = ns.substring(with: m.range(at: 2))
            let text = tags.stringByReplacingMatches(in: inner, range: NSRange(location: 0, length: (inner as NSString).length),
                                                     withTemplate: "")
            let title = Py.split((try? PyHTML.unescape(text)) ?? text).joined(separator: " ")
            out.append(Result(url: target, title: title))
        }
        return out
    }

    private static func attribute(_ regex: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1...2 where m.range(at: i).location != NSNotFound { return ns.substring(with: m.range(at: i)) }
        return nil
    }

    /// The page a result link leads to: its `uddg` parameter when it is DuckDuckGo's redirect,
    /// else itself; nil for an ad or anything that is not an http(s) page.
    static func destination(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard let components = URLComponents(string: absolute), let host = components.host?.lowercased() else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            if components.path.hasPrefix("/y.js") { return nil }                   // an ad
            guard components.path.hasPrefix("/l/"),
                  let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
            else { return nil }
            return WebReading.isWebURL(target) ? target : nil
        }
        return WebReading.isWebURL(absolute) ? absolute : nil
    }
}
