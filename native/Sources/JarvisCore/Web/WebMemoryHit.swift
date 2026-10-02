import Foundation

/// W1 part 3: a page in JARVIS's web memory that matches a search, as search_memory lists it.
/// Everything here came from the web: callers show it as untrusted information.
public struct WebMemoryHit: Sendable, Equatable {
    /// The page's canonical URL.
    public let url: String
    public let title: String
    /// When it was read (epoch seconds) and that day's local date, "YYYY-MM-DD".
    public let readAt: Double
    public let date: String
    /// The on-device summary, or while there is none yet, the start of the text.
    public let summary: String
    /// Up to five key points (none until summarised).
    public let points: [String]
    /// "background" or "search".
    public let source: String

    public init(url: String, title: String, readAt: Double, date: String, summary: String, points: [String],
                source: String) {
        self.url = url
        self.title = title
        self.readAt = readAt
        self.date = date
        self.summary = summary
        self.points = points
        self.source = source
    }
}
