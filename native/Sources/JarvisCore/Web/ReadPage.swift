import Foundation

/// W1 part 2: a web page as JARVIS's reader read it: Safari's engine (WebKit) in JarvisApp, on
/// a private profile that keeps nothing. The brain and the tools only see this and
/// `PageReading`, never WebKit.
public struct ReadPage: Sendable, Equatable {
    /// What was asked for.
    public let requested: String
    /// Where the page ended up, after redirects.
    public let finalURL: String
    /// The page's canonical URL (`<link rel="canonical">`, else `og:url`), else `finalURL`.
    public let canonicalURL: String
    public let title: String
    /// The main text, at most `WebReading.textLimit` code points, secrets masked (`Redactor`).
    public let text: String
    /// Whether the text was cut to the limit.
    public let truncated: Bool

    public init(requested: String, finalURL: String, canonicalURL: String, title: String, text: String,
                truncated: Bool) {
        self.requested = requested
        self.finalURL = finalURL
        self.canonicalURL = canonicalURL
        self.title = title
        self.text = text
        self.truncated = truncated
    }

    /// The page from what the extraction script returned: the text cut to the limit, then
    /// redacted, then cut again (a mask can be longer than what it hides); the canonical URL
    /// kept only when it is http(s), else the final URL; the title on one line, at most 300
    /// code points.
    public static func from(requested: String, finalURL: String, title: String, canonical: String,
                            text: String) -> ReadPage {
        let raw = Py.strip(text)
        let cut = Py.len(raw) > WebReading.textLimit
        var body = cut ? Py.prefix(raw, WebReading.textLimit) : raw
        body = Redactor.redact(body).text
        if Py.len(body) > WebReading.textLimit { body = Py.prefix(body, WebReading.textLimit) }
        let oneLine = Py.split(title).joined(separator: " ")
        return ReadPage(requested: requested, finalURL: finalURL,
                        canonicalURL: WebReading.isWebURL(canonical) ? canonical : finalURL,
                        title: Py.prefix(Redactor.redact(oneLine).text, 300), text: body, truncated: cut)
    }
}

/// What reads pages: JarvisApp's WebKit reader, or a test's fake.
public protocol PageReading: Sendable {
    /// Loads `url` in a fresh private tab, waits for it to settle (at most
    /// `WebReading.settleLimit`), and returns its main text. Throws when the page cannot be
    /// loaded or shows nothing readable.
    func read(_ url: String) async throws -> ReadPage
}

public enum WebReading {
    /// The text kept from one page, in code points.
    public static let textLimit = 200_000
    /// How long a page may take to settle, from the start of the load.
    public static let settleLimit: Duration = .seconds(15)
    /// Tabs open at once, at most.
    public static let maxTabs = 2

    /// An absolute http or https URL with a host.
    public static func isWebURL(_ s: String) -> Bool {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty
        else { return false }
        return scheme == "https" || scheme == "http"
    }
}

public enum PageReadError: Error, Equatable, CustomStringConvertible {
    case notWeb                 // not an http(s) URL
    case failed(String)         // the load failed (WebKit's reason)
    case refused                // a download or a non-web navigation, cancelled
    case nothingReadable        // the page settled with no text
    case timedOut               // nothing loaded within the settle limit

    public var description: String {
        switch self {
        case .notWeb: "not an http(s) URL"
        case .failed(let why): "the page did not load (\(why))"
        case .refused: "the page was a download, which the reader refuses"
        case .nothingReadable: "the page has no readable text"
        case .timedOut: "the page did not load in time"
        }
    }
}
