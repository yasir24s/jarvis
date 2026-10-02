import Foundation

/// W1: one HTTP GET, as Python's `urllib.request.urlopen(Request(url, headers), timeout).read()`
/// is used by the web tools. Tests inject a fake, so no test reaches the network.
public protocol WebFetching: Sendable {
    /// The body of a GET of `url` with `headers`, waiting at most `timeout` seconds for the
    /// server. Throws on a transport failure and on a status outside 200-299 (urllib raises
    /// HTTPError for those).
    func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data
}

public enum WebFetchError: Error, Equatable, CustomStringConvertible {
    case badURL
    case status(Int)
    case tooLarge(Int)
    case transport(String)

    public var description: String {
        switch self {
        case .badURL: "not an http(s) URL"
        case .status(let code): "HTTP Error \(code)"
        case .tooLarge(let n): "the response is larger than \(n) bytes"
        case .transport(let why): why
        }
    }
}

/// URLSession on an ephemeral configuration: no cookies are sent or kept, nothing is cached on
/// disk, and no credentials are stored. Python reads any size; this stops at `maxBytes`, far
/// above what the four feeds send.
public struct LiveWebFetch: WebFetching {
    public static let maxBytes = 16 << 20

    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
        guard let target = URL(string: url), let scheme = target.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { throw WebFetchError.badURL }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw WebFetchError.transport((error as NSError).localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw WebFetchError.status(http.statusCode)
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maxBytes { throw WebFetchError.tooLarge(Self.maxBytes) }
            }
        } catch let error as WebFetchError {
            throw error
        } catch {
            throw WebFetchError.transport((error as NSError).localizedDescription)
        }
        return data
    }
}

/// What a platform has before the app gives it the network: every fetch fails, and the tools
/// read as offline. Fakes for tests replace both.
struct NoWebFetch: WebFetching {
    func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
        throw WebFetchError.transport("no network in this platform")
    }
}
