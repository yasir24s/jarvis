import Foundation
import JarvisCore

/// Batch C part 5: the TV feasibility probe. Read-only and silent: it reads the TV app's scripting
/// dictionary, the public tv.apple.com pages (no login) and, only if the TV app is already running,
/// what it is playing. It never starts playback, never launches the TV app and never sends
/// anything to an Apple TV. `JARVIS --probe-tv "<show>"` prints its findings.
public enum TVProbe {
    // MARK: - tv.apple.com, public pages

    /// The show pages a search page links to, in page order, without repeats.
    public static func showURLs(inSearchPage html: String) -> [String] {
        unique(matches(#"https://tv\.apple\.com/[a-z]{2}/show/[a-z0-9-]+/umc\.cmc\.[a-z0-9]+"#, in: html))
    }

    /// The show page for `show`: the first link whose slug is the show's name, else nil.
    public static func showURL(for show: String, inSearchPage html: String) -> String? {
        let slug = show.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
        return showURLs(inSearchPage: html).first { $0.contains("/show/\(slug)/") }
    }

    /// A season the show page lists: its number, catalogue id and episode count.
    public struct Season: Equatable, Sendable {
        public let number: Int
        public let id: String
        public let episodes: Int

        public init(number: Int, id: String, episodes: Int) {
            self.number = number
            self.id = id
            self.episodes = episodes
        }
    }

    /// The seasons in a show page's server data (`"seasons":[{"episodeCount":10,"id":"umc.cmc…",
    /// "seasonNumber":1,…}]`).
    public static func seasons(inShowPage html: String) -> [Season] {
        let re = #"\{"episodeCount":(\d+),"id":"(umc\.cmc\.[a-z0-9]+)","seasonNumber":(\d+),"title":"[^"]*"\}"#
        guard let regex = try? NSRegularExpression(pattern: re) else { return [] }
        var seen = Set<Int>()
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { m in
            func g(_ i: Int) -> String { Range(m.range(at: i), in: html).map { String(html[$0]) } ?? "" }
            guard let n = Int(g(3)), let count = Int(g(1)), seen.insert(n).inserted else { return nil }
            return Season(number: n, id: g(2), episodes: count)
        }.sorted { $0.number < $1.number }
    }

    /// The episode pages a show page links to (the server renders one season's: the first).
    public static func episodeURLs(inShowPage html: String) -> [String] {
        unique(matches(#"https://tv\.apple\.com/[a-z]{2}/episode/[a-z0-9-]+/umc\.cmc\.[a-z0-9]+"#, in: html))
    }

    public static func searchURL(_ show: String, storefront: String) -> URL? {
        var c = URLComponents(string: "https://tv.apple.com/\(storefront)/search")
        c?.queryItems = [URLQueryItem(name: "term", value: show)]
        return c?.url
    }

    // MARK: - The TV app

    /// The dictionary terms the play and now-playing routes need.
    public static let neededTerms = ["play", "open location", "current track", "player state", "unplayed", "bookmark",
                                     "season number", "episode number", "show"]

    /// Which needed terms an `sdef` dump lacks.
    public static func missingTerms(inDictionary sdef: String) -> [String] {
        neededTerms.filter { !sdef.contains("name=\"\($0)\"") }
    }

    /// Now playing in the TV app, only when it is running (the script never launches it).
    public static let nowPlayingScript = """
        if application "TV" is not running then return "not running"
        tell application "TV"
          if player state is stopped then return "stopped"
          set t to current track
          return (player state as text) & "|" & (name of t) & "|" & (show of t) & "|" & (season number of t) & "|" & (episode number of t)
        end tell
        """

    // MARK: - Accessibility (TV tools)

    /// What the TV app's window, as Accessibility shows it, offers the search route: the search
    /// field (and how it was matched), a control that opens search, the episode rows and their
    /// watch marks, and a Play button. Read-only: the caller only takes a snapshot.
    public static func accessibilityReport(_ root: TVAXNode?, titles: TVUITitles = .table) -> [String] {
        guard let root else { return ["tv-app window: none (no window to read)"] }
        var out: [String] = []
        let nodes = root.all
        out.append("tv-app window: \(nodes.count) elements")
        if let field = TVUIReader.searchField(in: root, titles: titles) {
            let how = field.subrole == "AXSearchField" ? "subrole AXSearchField"
                : (field.identifier.map { "identifier \($0)" } ?? "title")
            out.append("tv-app search field: exposed (\(how)) at \(field.path)")
        } else if let tab = TVUIReader.searchTab(in: root, titles: titles) {
            out.append("tv-app search field: not on this screen; a search control is (\(tab.role)) at \(tab.path)")
        } else {
            out.append("tv-app search field: not exposed on this screen")
        }
        let page = TVUIReader.showPage(in: root, titles: titles)
        out.append("tv-app banner: " + (page.banner.map { "names S\($0.season.map(String.init) ?? "?")E\($0.episode)" } ?? "none"))
        out.append("tv-app season picker: " + (page.picker.map { _ in "exposed" + (page.season.map { ", showing season \($0)" } ?? "") } ?? "none"))
        out.append("tv-app episode cells: \(page.cells.count) exposed (by identifier)")
        let rows = TVUIReader.episodes(in: root, titles: titles)
        if rows.isEmpty {
            out.append("tv-app episode list: none on this screen (open a show page in the TV app and run again)")
        } else {
            let marks = rows.filter { $0.watch != .unknown }.count
            let ownPlay = rows.filter { $0.playPath != nil }.count
            out.append("tv-app episode list: \(rows.count) rows (\(rows.map(\.code).prefix(6).joined(separator: ", "))), "
                       + "\(marks) with watch marks, \(ownPlay) with their own Play button")
        }
        out.append("tv-app play button: " + (TVUIReader.playButton(in: root, titles: titles).map { "exposed at \($0.path)" } ?? "none on this screen"))
        let ids = unique(nodes.compactMap(\.identifier).filter { !$0.isEmpty })
        out.append("tv-app identifiers: " + (ids.isEmpty ? "none" : ids.prefix(30).joined(separator: ", ")))
        return out
    }

    // MARK: - Helpers

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
