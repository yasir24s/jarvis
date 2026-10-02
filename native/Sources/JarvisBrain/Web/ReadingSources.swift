import Foundation
import JarvisCore

/// W1 part 5: where the background reading finds what to read. Feeds and the facts only: never
/// the words of the user's messages (Python's research queue read those literally, the
/// junk-topic quirk), so knowledge.json's "queue" is not read here.
public enum ReadingSources {
    /// One thing to read: its link, its title as the source gave it, and which source.
    public struct Item: Sendable, Equatable {
        public let url: String
        public let title: String
        public let source: String

        public init(url: String, title: String, source: String) {
            self.url = url
            self.title = title
            self.source = source
        }
    }

    /// A public RSS feed and the group it fills.
    public struct Feed: Sendable, Equatable {
        public let name: String
        public let url: String
        public let group: Group
    }

    public enum Group: String, Sendable, CaseIterable {
        case news            // top UK and world news
        case culture         // what is trending in pop culture
        case interests       // the user's own interests, from his facts
    }

    /// The feeds: BBC News (top stories, UK, world) and the Guardian (UK, world) for the news,
    /// the Guardian's culture feed for pop culture beside Wikipedia's most-read articles.
    public static let feeds: [Feed] = [
        Feed(name: "BBC News", url: "https://feeds.bbci.co.uk/news/rss.xml", group: .news),
        Feed(name: "BBC News UK", url: "https://feeds.bbci.co.uk/news/uk/rss.xml", group: .news),
        Feed(name: "BBC News World", url: "https://feeds.bbci.co.uk/news/world/rss.xml", group: .news),
        Feed(name: "The Guardian UK", url: "https://www.theguardian.com/uk-news/rss", group: .news),
        Feed(name: "The Guardian World", url: "https://www.theguardian.com/world/rss", group: .news),
        Feed(name: "The Guardian Culture", url: "https://www.theguardian.com/culture/rss", group: .culture),
    ]

    /// Wikipedia's most-read articles of a day (the REST "featured" feed), `day` in UTC.
    public static func mostReadURL(day: Date) -> String {
        "https://en.wikipedia.org/api/rest_v1/feed/featured/"
            + PyTime.strftime("%Y/%m/%d", day, timeZone: TimeZone(identifier: "UTC")!)
    }

    private static let item = try! NSRegularExpression(pattern: #"<item\b[^>]*>(.*?)</item>"#,
                                                       options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let title = try! NSRegularExpression(pattern: #"<title\b[^>]*>(.*?)</title>"#,
                                                        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let link = try! NSRegularExpression(pattern: #"<link\b[^>]*>(.*?)</link>"#,
                                                       options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// An RSS feed's items in order: each `<item>`'s link and title (CDATA or not, unescaped).
    public static func rss(_ xml: String, source: String) -> [Item] {
        let ns = xml as NSString
        return item.matches(in: xml, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let body = ns.substring(with: m.range(at: 1))
            guard let url = first(link, in: body).map(text), WebReading.isWebURL(url) else { return nil }
            return Item(url: url, title: first(title, in: body).map(text) ?? "", source: source)
        }
    }

    private static func first(_ regex: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// A field's text: CDATA unwrapped, tags dropped, entities unescaped, whitespace folded.
    private static func text(_ raw: String) -> String {
        var s = Py.strip(raw)
        if s.hasPrefix("<![CDATA["), s.hasSuffix("]]>") { s = String(s.dropFirst(9).dropLast(3)) }
        s = s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        return Py.split((try? PyHTML.unescape(s)) ?? s).joined(separator: " ")
    }

    /// The most-read articles of Wikipedia's featured feed, by rank, without the main page and
    /// the special, help and file pages.
    public static func mostRead(_ feed: JSONValue) -> [Item] {
        let articles = feed.objectValue?["mostread"]?.objectValue?["articles"]?.arrayValue ?? []
        let skipped = ["Main_Page", "Special:", "Wikipedia:", "Portal:", "File:", "Help:", "Talk:", "Category:"]
        return articles.compactMap { a -> Item? in
            guard let o = a.objectValue, let title = o["title"]?.stringValue,
                  !skipped.contains(where: { title.hasPrefix($0) }),
                  let url = o["content_urls"]?.objectValue?["desktop"]?.objectValue?["page"]?.stringValue,
                  WebReading.isWebURL(url)
            else { return nil }
            let shown = o["normalizedtitle"]?.stringValue ?? title.replacingOccurrences(of: "_", with: " ")
            return Item(url: url, title: shown, source: "Wikipedia most read")
        }
    }

    /// What the user is into, from his facts, read now: a fact about the user (one that passes
    /// the validator) saying he likes, loves or enjoys something, is a fan of it, supports or
    /// follows it, plays, watches or listens to it, collects or keeps it, or is interested in
    /// or into it. Newest facts first, each topic once, at most `limit`. Nothing is hard-coded:
    /// with no such fact there is no topic.
    public static func interests(_ facts: [MemoryFact], limit: Int = 6) -> [String] {
        let pattern = try! NSRegularExpression(pattern:
            #"^The user (?:really |also |still )?(?:likes|loves|enjoys|adores|is (?:a |an )?(?:big |huge |keen )?fan of"#
            + #"|supports|follows|plays|watches|listens to|collects|keeps|is (?:very )?interested in|is into)\s+(.+)$"#,
            options: [.caseInsensitive])
        var seen = Set<String>(), out: [String] = []
        for fact in facts.sorted(by: { $0.updated > $1.updated })
        where fact.about == MemoryFact.user && FactExtraction.dropReason(fact) == nil {
            let ns = fact.text as NSString
            guard let m = pattern.firstMatch(in: fact.text, range: NSRange(location: 0, length: ns.length)) else { continue }
            var topic = ns.substring(with: m.range(at: 1))
            for stop in [".", ",", ";", ":", "!", "?", " because ", " when ", " since ", " every ", " on weekends"] {
                if let r = topic.range(of: stop) { topic = String(topic[..<r.lowerBound]) }
            }
            topic = Py.strip(topic)
            for article in ["the ", "a ", "an ", "to "] where Py.lower(topic).hasPrefix(article) {
                topic = String(topic.dropFirst(article.count))
            }
            topic = Py.prefix(Py.strip(topic), 60)
            guard topic.count >= 3, seen.insert(Py.lower(topic)).inserted else { continue }
            out.append(topic)
            if out.count == limit { break }
        }
        return out
    }
}
