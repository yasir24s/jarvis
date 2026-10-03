import Foundation
import JarvisTools
import Testing

/// Batch C part 5: the probe's parsers on page snippets shaped like tv.apple.com's server HTML
/// (invented ids), and the dictionary check. No network.
@Suite("Batch C TV probe")
struct TVProbeTests {
    static let search = """
        <a href="https://tv.apple.com/gb/show/invented-chemistry/umc.cmc.aaa111">x</a>
        <a href="https://tv.apple.com/gb/show/invented-lasso/umc.cmc.bbb222">y</a>
        <a href="https://tv.apple.com/gb/show/invented-lasso/umc.cmc.bbb222">y again</a>
        """
    static let show = """
        "seasons":[{"episodeCount":10,"id":"umc.cmc.s1","seasonNumber":1,"title":"Season 1"},\
        {"episodeCount":12,"id":"umc.cmc.s2","seasonNumber":2,"title":"Season 2"}],
        <a href="https://tv.apple.com/gb/episode/pilot/umc.cmc.ep1?showId=umc.cmc.bbb222">
        <a href="https://tv.apple.com/gb/episode/biscuits/umc.cmc.ep2?showId=umc.cmc.bbb222">
        """

    @Test func searchPage() {
        #expect(TVProbe.showURLs(inSearchPage: Self.search).count == 2)
        #expect(TVProbe.showURL(for: "Invented Lasso", inSearchPage: Self.search) == "https://tv.apple.com/gb/show/invented-lasso/umc.cmc.bbb222")
        #expect(TVProbe.showURL(for: "Nothing Here", inSearchPage: Self.search) == nil)
        #expect(TVProbe.searchURL("Invented Lasso", storefront: "gb")?.absoluteString == "https://tv.apple.com/gb/search?term=Invented%20Lasso")
    }

    @Test func showPage() {
        #expect(TVProbe.seasons(inShowPage: Self.show) == [.init(number: 1, id: "umc.cmc.s1", episodes: 10),
                                                            .init(number: 2, id: "umc.cmc.s2", episodes: 12)])
        #expect(TVProbe.episodeURLs(inShowPage: Self.show).count == 2)
    }

    @Test func dictionary() {
        let all = TVProbe.neededTerms.map { "<command name=\"\($0)\"/>" }.joined()
        #expect(TVProbe.missingTerms(inDictionary: all).isEmpty)
        #expect(TVProbe.missingTerms(inDictionary: "<command name=\"play\"/>").contains("open location"))
    }
}
