import Foundation
import JarvisCore
import Synchronization

/// `media_search`: questions about the catalogue. Titles only, never file paths.
struct MediaSearch: ToolImpl {
    static let name = "media_search"
    static let schema = ToolSchema(
        name: name,
        description: "Look in the user's own media catalogue on this Mac: their Music library (play counts, loved songs, playlists), their TV app library and their media folders. question: 'search' (with query), 'top_artists', 'top_genres', 'most_played_album', 'repeats' (what they played most in the last 7 days, or the 7 days before with weeks_ago 1), 'remaining_episodes' or 'next_episode' (with query = the show). Only works while Media Library or Learn From My Music is on.",
        parametersJSON: #"{"type": "object", "properties": {"question": {"type": "string", "enum": ["search", "top_artists", "top_genres", "most_played_album", "repeats", "remaining_episodes", "next_episode"]}, "query": {"type": "string"}, "kind": {"type": "string", "enum": ["music", "tv", "movie", "any"]}, "weeks_ago": {"type": "integer"}}, "required": ["question"]}"#)

    static let off = "My media catalogue is switched off, sir. Turn on Media Library or Learn From My Music in Learning Sources."

    let library: MediaLibrary

    init(library: MediaLibrary) {
        self.library = library
    }

    static func int(_ v: JSONValue?) -> Int? {
        switch v {
        case .int(let n)?: Int(n)
        case .double(let d)?: Int(d)
        default: nil
        }
    }

    static func kinds(_ raw: String?) -> Set<MediaItem.Kind>? {
        switch raw {
        case "music": [.song, .musicVideo, .audioFile]
        case "tv": [.tvEpisode]
        case "movie": [.movie, .homeVideo, .videoFile]
        default: nil
        }
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard library.switches.library() || library.switches.music() else { return .text(Self.off) }
        await library.refresh()
        let c = library.load()
        let query = args["query"]?.stringValue ?? ""
        switch args["question"]?.stringValue ?? "search" {
        case "top_artists":
            let top = c.top({ $0.artist }, n: 10)
            return .text(top.isEmpty ? "No play counts yet." : top.map { "\($0.name) (\($0.plays) plays)" }.joined(separator: "\n"))
        case "top_genres":
            let top = c.top({ $0.genre }, n: 5)
            return .text(top.isEmpty ? "No play counts yet." : top.map { "\($0.name) (\($0.plays) plays)" }.joined(separator: "\n"))
        case "most_played_album":
            guard let a = c.mostPlayedAlbum() else { return .text("No play counts yet.") }
            return .text("\(a.album)" + (a.artist.map { " by \($0)" } ?? ""))
        case "repeats":
            let weeksAgo = max(0, MediaSearch.int(args["weeks_ago"]) ?? 0)
            let now = library.clock.now()
            let to = library.day(now - Double(weeksAgo * 7) * 86_400)
            let from = library.day(now - Double(weeksAgo * 7 + 6) * 86_400)
            let hits = c.plays(from: from, to: to).prefix(10)
            return .text(hits.isEmpty ? "I have no plays recorded from \(from) to \(to)."
                         : "From \(from) to \(to):\n" + hits.map { "\($0.item.line) — \($0.plays) plays that week" }.joined(separator: "\n"))
        case "remaining_episodes":
            let left = c.remainingEpisodes(of: query)
            return .text(left.isEmpty ? "No unwatched episodes of \(query) in the catalogue." : left.map(\.line).joined(separator: "\n"))
        case "next_episode":
            return .text(c.latestEpisode(of: query)?.line ?? "No episodes of \(query) in the catalogue.")
        default:
            let hits = c.search(query, kinds: Self.kinds(args["kind"]?.stringValue))
            return .text(hits.isEmpty ? "Nothing in the catalogue matches \"\(query)\"." : hits.map(\.line).joined(separator: "\n"))
        }
    }
}

/// `media_play`: plays from the catalogue through the routes in `MediaLibrary.play`.
struct MediaPlay: ToolImpl {
    static let name = "media_play"
    static let schema = ToolSchema(
        name: name,
        description: "Play something from the user's own media catalogue on this Mac. what: 'item' (best match for query), 'latest_episode' (query = the show: the next unwatched episode, or the newest), 'album' (query = album), 'most_played_album', or 'playlist' (query = playlist name). Songs and albums play in Music; TV and movies in the TV app; files from media folders in the TV app or QuickTime.",
        parametersJSON: #"{"type": "object", "properties": {"what": {"type": "string", "enum": ["item", "latest_episode", "album", "most_played_album", "playlist"]}, "query": {"type": "string"}, "kind": {"type": "string", "enum": ["music", "tv", "movie", "any"]}}, "required": ["what"]}"#)

    let library: MediaLibrary

    init(library: MediaLibrary) {
        self.library = library
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        guard library.switches.library() || library.switches.music() else { return .text(MediaSearch.off) }
        await library.refresh()
        let c = library.load()
        let query = args["query"]?.stringValue ?? ""
        switch args["what"]?.stringValue ?? "item" {
        case "latest_episode":
            guard let ep = c.latestEpisode(of: query) else { return .text("I don't have \(query) in your library, sir.") }
            guard await library.play(ep) != nil else { return .text("I couldn't start \(ep.show ?? query), sir.") }
            return .text("Playing \(ep.show ?? query) \(ep.episodeCode), \"\(ep.title)\", sir.")
        case "most_played_album":
            guard let a = c.mostPlayedAlbum() else { return .text("I have no play counts yet, sir.") }
            return .text(await library.playCollection(album: a.album, playlist: nil)
                         ? "Playing \(a.album)" + (a.artist.map { " by \($0)" } ?? "") + ", sir." : "I couldn't start \(a.album), sir.")
        case "album":
            guard let a = c.search(query, kinds: [.song]).first?.album else { return .text("I can't find that album, sir.") }
            return .text(await library.playCollection(album: a, playlist: nil) ? "Playing \(a), sir." : "I couldn't start \(a), sir.")
        case "playlist":
            guard let p = c.playlists.first(where: { $0.name.localizedCaseInsensitiveCompare(query) == .orderedSame })
                    ?? c.playlists.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
                return .text("I can't find a playlist called \(query), sir.")
            }
            return .text(await library.playCollection(album: nil, playlist: p.name) ? "Playing \(p.name), sir." : "I couldn't start \(p.name), sir.")
        default:
            guard let item = c.search(query, kinds: MediaSearch.kinds(args["kind"]?.stringValue), limit: 1).first else {
                return .text("Nothing in your library matches \"\(query)\", sir.")
            }
            guard await library.play(item) != nil else { return .text("I couldn't start \(item.title), sir.") }
            return .text("Playing \(item.title)" + (item.artist.map { " by \($0)" } ?? "") + ", sir.")
        }
    }
}
