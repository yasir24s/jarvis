import Foundation
import JarvisChat
import Testing

/// Links in finished replies open only for http and https (M4 C2 item 4).
@Suite("M4 reply links (plan 3.12)")
struct ChatLinksTests {
    @Test("http and https links open, in any case, and nothing is logged",
          arguments: ["http://example.com/a", "https://example.com/b?q=1", "HTTPS://EXAMPLE.COM", "Http://example.com"])
    func webLinksOpen(link: String) throws {
        let url = try #require(URL(string: link))
        var logged: [String] = []
        #expect(ChatLinks.opens(url, log: { logged.append($0) }))
        #expect(logged.isEmpty)
    }

    @Test("any other scheme is ignored and logged by its scheme alone",
          arguments: [("file:///tmp/private/secret-token.txt", "file"), ("javascript:alert('secret-token')", "javascript"),
                      ("mailto:sam@example.com?body=secret-token", "mailto"), ("jarvis://confirm/secret-token", "jarvis"),
                      ("x-apple.systempreferences:com.apple.secret-token", "x-apple.systempreferences"),
                      ("ftp://example.com/secret-token", "ftp"), ("ssh://example.com/secret-token", "ssh"),
                      ("tel:+15550100", "tel"), ("data:text/html,secret-token", "data")])
    func otherSchemesAreIgnored(link: String, scheme: String) throws {
        let url = try #require(URL(string: link))
        var logged: [String] = []
        #expect(!ChatLinks.opens(url, log: { logged.append($0) }))
        #expect(logged == ["chat: a \(scheme): link was not opened (only http and https open)"])
        #expect(!logged.joined().contains("secret-token"))
        #expect(!logged.joined().contains("example.com"))
    }

    @Test("a link with no scheme is ignored and logged")
    func noScheme() throws {
        let url = try #require(URL(string: "notes/secret-token.txt"))
        var logged: [String] = []
        #expect(!ChatLinks.opens(url, log: { logged.append($0) }))
        #expect(logged == ["chat: a link with no scheme was not opened"])
    }

    @Test("a markdown link in a reply gets the same rule")
    func markdownLinks() throws {
        let text = ChatMarkdown.attributed("See [the notes](file:///tmp/private/notes.txt) or [the site](https://example.com).")
        let links = text.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(links.map { ChatLinks.opens($0, log: { _ in }) } == [false, true])
    }
}
