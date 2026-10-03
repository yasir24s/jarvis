import Foundation
import JarvisCore
import Testing

/// Batch C parts 2 and 5b: the catalogue's pure logic, on invented items.
@Suite("Batch C media catalogue")
struct MediaCatalogueTests {
    static func song(_ id: String, _ title: String, artist: String, album: String, genre: String = "Invented Pop",
                     plays: Int, loved: Bool = false) -> MediaItem {
        MediaItem(id: "music:\(id)", kind: .song, source: .music, title: title, artist: artist, album: album, genre: genre,
                  playCount: plays, loved: loved)
    }

    static func episode(_ id: String, _ s: Int, _ e: Int, watch: MediaItem.WatchState, released: Double = 0) -> MediaItem {
        MediaItem(id: "tv:\(id)", kind: .tvEpisode, source: .tv, title: "Episode \(e)", show: "Invented Lasso",
                  season: s, episode: e, watch: watch, released: released)
    }

    static let base: MediaCatalogue = {
        var c = MediaCatalogue()
        c.items = [song("A", "Glass Harbour", artist: "The Inventions", album: "Tides", plays: 40, loved: true),
                   song("B", "Paper Moon Drive", artist: "The Inventions", album: "Tides", plays: 30),
                   song("C", "Slow Lantern", artist: "Mara Quill", album: "Embers", genre: "Invented Folk", plays: 12)]
        return c
    }()

    @Test("a refresh credits play-count rises to the day and keeps other sources")
    func refresh() {
        var c = Self.base
        c.items.append(Self.episode("E1", 1, 1, watch: .watched))
        var fresh = Self.base.items
        fresh[2].playCount = 20                     // +8 plays
        fresh.append(Self.song("D", "New Song", artist: "X", album: "Y", plays: 99))   // new: no credit
        let next = c.refreshed(with: fresh, playlists: nil, replacing: [.music], now: 100, day: "2026-10-03", cutoffDay: "2026-07-05")
        #expect(next.plays["2026-10-03"] == ["music:C": 8])
        #expect(next.items.contains { $0.id == "tv:E1" })
        #expect(next.items.count == 5 && next.refreshed == 100)
        var old = next
        old.plays["2026-01-01"] = ["music:A": 1]
        #expect(old.refreshed(with: fresh, playlists: nil, replacing: [.music], now: 200, day: "2026-10-04",
                              cutoffDay: "2026-07-05").plays["2026-01-01"] == nil)
    }

    @Test("search, top artists and genres, most played album")
    func questions() {
        let c = Self.base
        #expect(c.search("invent glass").map(\.title) == ["Glass Harbour"])
        #expect(c.search("").first?.title == "Glass Harbour")
        #expect(c.top({ $0.artist }, n: 5).map(\.name) == ["The Inventions", "Mara Quill"])
        #expect(c.top({ $0.genre }, n: 5).first?.plays == 70)
        #expect(c.mostPlayedAlbum()?.album == "Tides")
    }

    @Test("plays over a week, most first")
    func repeats() {
        var c = Self.base
        c.plays = ["2026-09-28": ["music:B": 9], "2026-09-30": ["music:B": 6, "music:C": 2], "2026-10-05": ["music:A": 50]]
        let week = c.plays(from: "2026-09-28", to: "2026-10-04")
        #expect(week.map(\.item.title) == ["Paper Moon Drive", "Slow Lantern"])
        #expect(week.first?.plays == 15)
    }

    @Test("the latest episode: the next unwatched when watch state is known, else the newest")
    func latestEpisode() {
        var c = MediaCatalogue()
        c.items = [Self.episode("3", 1, 3, watch: .unwatched), Self.episode("1", 1, 1, watch: .watched),
                   Self.episode("2", 1, 2, watch: .inProgress), Self.episode("4", 2, 1, watch: .unwatched)]
        #expect(c.latestEpisode(of: "invented lasso")?.episodeCode == "S01E02")
        #expect(c.remainingEpisodes(of: "Invented Lasso").map(\.episodeCode) == ["S01E02", "S01E03", "S02E01"])
        var unknown = MediaCatalogue()
        unknown.items = [Self.episode("1", 1, 1, watch: .unknown, released: 10), Self.episode("2", 1, 2, watch: .unknown, released: 20)]
        #expect(unknown.latestEpisode(of: "Invented Lasso")?.episodeCode == "S01E02")
        #expect(c.latestEpisode(of: "Nothing") == nil)
    }

    @Test("a brain sees titles, never paths")
    func line() {
        var item = MediaItem(id: "file:/x/y.mkv", kind: .tvEpisode, source: .folder, title: "Pilot", show: "Invented Lasso",
                             season: 1, episode: 1, watch: .unwatched, location: "/private/media/Invented.Lasso.S01E01.mkv")
        #expect(item.line == "Invented Lasso S01E01 \"Pilot\" [tvEpisode], unwatched")
        item.location = nil
        #expect(!item.line.contains("/"))
        let data = Self.base.data
        #expect(MediaCatalogue(data: data) == Self.base)
    }

    @Test("music facts are short, deterministic and dated")
    func distillation() {
        var c = Self.base
        c.plays = ["2026-09-30": ["music:B": 7], "2026-10-02": ["music:C": 3]]
        let facts = MusicDistillation.facts(c, today: "2026-10-03", weekStart: "2026-09-28", lastWeekStart: "2026-09-21")
        #expect(facts.contains("The user's most played artists are The Inventions and Mara Quill."))
        #expect(facts.contains("The user's most played album is Tides by The Inventions."))
        #expect(facts.contains("Songs the user loves include Glass Harbour by The Inventions."))
        #expect(facts.contains { $0.hasPrefix("In the week from 2026-09-28 the user has mostly been playing Paper Moon Drive") })
        #expect(facts.allSatisfy { $0.count <= MemoryFact.maxLength })
        let lastWeek = MusicDistillation.facts(c, today: "2026-10-06", weekStart: "2026-10-05", lastWeekStart: "2026-09-28")
        #expect(lastWeek.contains("In the week from 2026-09-28 the user played Paper Moon Drive by The Inventions on repeat (7 plays)."))
    }

    @Test("file names give show, season and episode", arguments: [
        ("Invented.Lasso.S01E02.The.Diamond.Dogs.mkv", "Invented Lasso", 1, 2, "The Diamond Dogs"),
        ("Invented Lasso - 2x10 - Finale.mp4", "Invented Lasso", 2, 10, "Finale"),
        ("Invented Lasso S3 E4.m4v", "Invented Lasso", 3, 4, "Invented Lasso"),
    ])
    func fileNames(_ name: String, _ show: String, _ season: Int, _ episode: Int, _ title: String) {
        let p = MediaFileName.parse(name)
        #expect(p.show == show && p.season == season && p.episode == episode && p.title == title)
    }

    @Test("a film's name is its title")
    func film() {
        #expect(MediaFileName.parse("An_Invented_Film (2024).mov") == .init(title: "An Invented Film (2024)", show: nil, season: nil, episode: nil))
    }
}
