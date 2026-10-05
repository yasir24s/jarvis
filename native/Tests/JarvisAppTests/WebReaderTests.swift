import Foundation
@testable import JarvisApp
import JarvisCore
import Testing

/// W1 part 2: the WebKit reader on pages from a loopback server (never the network): the main
/// text without the navigation, sidebar, comments and footer; the title and canonical URL; a page
/// that fills in late, one that never settles, a download, an error page, the 200,000-character
/// cap, secrets masked, no cookie carried from one tab to the next, at most two tabs at once,
/// and every tab closed after. One case prints what a tab costs in memory.
@Suite("W1 WebKit reader", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct WebReaderTests {
    static let story = (1...6).map { k in
        "<p>Paragraph \(k) of the invented story, which is long enough to count, with commas, clauses, and "
            + "a few more words to pass the hundred-character mark for scoring.</p>"
    }.joined()

    static let article = """
        <html><head><title>An invented story</title>
        <link rel="canonical" href="https://example.invalid/news/story-1"></head>
        <body><header><nav><a href="/">Home</a> <a href="/news">News</a> <a href="/sport">Sport</a></nav></header>
        <div class="layout">
          <div class="sidebar"><p>Sidebar text that should not be read, though it is long enough to count as one.</p></div>
          <div class="story-body"><h1>An invented story</h1>\(story)
            <p>The password: hunter2swordfish is not real.</p></div>
          <div id="comments"><p>Comment text, from a reader, that is long enough to count as a paragraph here.</p></div>
        </div>
        <footer><p>Footer text, copyright nobody, all rights reserved, long enough to count.</p></footer>
        </body></html>
        """

    func withServer(_ routes: [String: LoopbackServer.Response], _ body: (LoopbackServer) async throws -> Void) async throws {
        let server = try LoopbackServer(routes: routes)
        defer { server.stop() }
        try await body(server)
    }

    @Test func readsTheArticleAndNothingAroundIt() async throws {
        try await withServer(["/story": .init(Self.article)]) { server in
            let reader = WebReader(log: { _ in })
            let (page, stats) = try await reader.readWithStats(server.url("/story"))
            #expect(page.title == "An invented story")
            #expect(page.canonicalURL == "https://example.invalid/news/story-1")
            #expect(page.finalURL == server.url("/story") && page.requested == server.url("/story"))
            for k in 1...6 { #expect(page.text.contains("Paragraph \(k) of the invented story")) }
            for junk in ["Sidebar text", "Comment text", "Footer text", "Home", "Sport"] {
                #expect(!page.text.contains(junk), "\(junk)")
            }
            #expect(page.text.contains("The password: " + Redactor.mask) && !page.text.contains("hunter2swordfish"))
            #expect(!page.truncated && reader.openTabs == 0)
            print("W1-reader: one tab \(stats.tabFootprint.map(WebReader.megabytes) ?? "unknown") (WebContent), "
                  + "JARVIS \(WebReader.megabytes(stats.ownFootprintDelta)) more, \(WebReader.seconds(stats.elapsed))")
        }
    }

    @Test func waitsForTextThatArrivesLate() async throws {
        let late = """
            <html><head><title>Late</title></head><body><div id="a"><p>Only the first paragraph is here at load.</p></div>
            <script>setTimeout(() => { for (let k = 0; k < 5; k++) { const p = document.createElement('p');
            p.textContent = 'A late paragraph number ' + k + ', added after the load, long enough, with commas.';
            document.getElementById('a').appendChild(p); } }, 400);</script></body></html>
            """
        try await withServer(["/late": .init(late)]) { server in
            let page = try await WebReader(log: { _ in }).read(server.url("/late"))
            #expect(page.text.contains("A late paragraph number 4"))
            #expect(page.canonicalURL == server.url("/late"))           // no canonical link: the page itself
        }
    }

    @Test func aPageThatNeverSettlesIsReadAtTheLimit() async throws {
        let busy = """
            <html><head><title>Busy</title></head><body><p id="t">A ticking page that never stops changing at all.</p>
            <script>setInterval(() => { document.getElementById('t').textContent += ' tick'; }, 100);</script></body></html>
            """
        try await withServer(["/busy": .init(busy)]) { server in
            let reader = WebReader(settleLimit: .seconds(2), log: { _ in })
            let clock = ContinuousClock()
            let start = clock.now
            let page = try await reader.read(server.url("/busy"))
            #expect(clock.now - start < .seconds(5))
            #expect(page.text.hasPrefix("A ticking page that never stops changing"))
        }
    }

    /// V11 part 3: a read cancelled while the page is still loading stops at once and closes its
    /// tab, rather than holding on until the page answers or the settle limit passes.
    @Test func aCancelledReadStopsWhileThePageLoads() async throws {
        try await withServer(["/slow": .init(Self.article, delay: 8)]) { server in
            let reader = WebReader(settleLimit: .seconds(30), log: { _ in })
            let clock = ContinuousClock()
            let read = Task { try await reader.read(server.url("/slow")) }
            try await Task.sleep(for: .milliseconds(500))
            let cancelledAt = clock.now
            read.cancel()
            await #expect(throws: (any Error).self) { try await read.value }
            #expect(clock.now - cancelledAt < .seconds(3))
            #expect(reader.openTabs == 0)
        }
    }

    @Test func refusesDownloadsErrorPagesAndOtherSchemes() async throws {
        try await withServer([
            "/file.bin": .init("binary", type: "application/octet-stream",
                               headers: ["Content-Disposition: attachment; filename=\"invented.bin\""]),
        ]) { server in
            let reader = WebReader(log: { _ in })
            await #expect(throws: PageReadError.refused) { try await reader.read(server.url("/file.bin")) }
            await #expect(throws: PageReadError.failed("HTTP 404")) { try await reader.read(server.url("/missing")) }
            for url in ["file:///etc/hosts", "javascript:alert(1)", "ftp://example.invalid/x", "not a url"] {
                await #expect(throws: PageReadError.notWeb) { try await reader.read(url) }
            }
            #expect(reader.openTabs == 0)
        }
    }

    @Test func theTextIsCutAt200000Characters() async throws {
        let paragraph = "<p>" + String(repeating: "Invented words, many of them, go on. ", count: 100) + "</p>"
        let huge = "<html><head><title>Huge</title></head><body><article>"
            + String(repeating: paragraph, count: 80) + "</article></body></html>"
        try await withServer(["/huge": .init(huge)]) { server in
            let page = try await WebReader(log: { _ in }).read(server.url("/huge"))
            #expect(page.truncated && Py.len(page.text) == WebReading.textLimit)
        }
    }

    /// Each tab has its own private store: a cookie one page sets is never sent by the next.
    @Test func noCookieIsCarriedFromOneTabToTheNext() async throws {
        try await withServer([
            "/set": .init("<html><body><p>This page sets a cookie for the invented session, once only.</p></body></html>",
                          headers: ["Set-Cookie: session=invented; Path=/; Max-Age=3600"]),
            "/check": .init("<html><body><p>This page only checks what cookies the reader sent to it.</p></body></html>"),
        ]) { server in
            let reader = WebReader(log: { _ in })
            _ = try await reader.read(server.url("/set"))
            _ = try await reader.read(server.url("/check"))
            let check = try #require(server.requests.first { $0.path == "/check" })
            #expect(check.cookie == nil)
            #expect(WebReader.configuration().websiteDataStore.isPersistent == false)
        }
    }

    @Test func atMostTwoTabsAtOnceAndAllClosed() async throws {
        let slow = LoopbackServer.Response(
            "<html><body><p>A slow page, answered after a second, long enough to read as text.</p></body></html>", delay: 1)
        try await withServer(["/slow": slow]) { server in
            let reader = WebReader(log: { _ in })
            let url = server.url("/slow")
            let clock = ContinuousClock()
            let start = clock.now
            async let a = reader.read(url)
            async let b = reader.read(url)
            async let c = reader.read(url)
            async let d = reader.read(url)
            let pages = try await [a, b, c, d]
            #expect(pages.allSatisfy { $0.text.hasPrefix("A slow page") })
            #expect(reader.peakTabs == 2 && reader.openTabs == 0)
            #expect(clock.now - start >= .seconds(2))                   // two at a time: two rounds
        }
    }
}
