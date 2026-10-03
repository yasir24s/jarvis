import Foundation

// Batch C parts 2 and 5b: the local media catalogue, memory/media-catalogue.json. What JARVIS
// knows about the user's music library (ITLibrary), TV and movie library (the TV app) and media
// folders, with the play counts it has seen over time, so "what did I play on repeat last week"
// and "what Ted Lasso episodes do I have left" can be answered on this Mac. Pure logic here;
// the readers and the tools are in JarvisTools. It stays on-device: the tools hand a brain titles,
// never file paths.

/// One thing the user can play.
public struct MediaItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case song, musicVideo, movie, tvEpisode, homeVideo, audioFile, videoFile
    }
    public enum Source: String, Codable, Sendable { case music, tv, folder }
    public enum WatchState: String, Codable, Sendable { case unwatched, inProgress, watched, unknown }

    public var id: String                 // "music:<persistent id>", "tv:<persistent id>", "file:<path>"
    public var kind: Kind
    public var source: Source
    public var title: String
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var show: String?
    public var season: Int?
    public var episode: Int?
    public var playCount: Int
    public var lastPlayed: Double?
    public var loved: Bool
    public var purchased: Bool
    public var watch: WatchState
    public var duration: Double?          // seconds
    public var released: Double?
    public var added: Double?
    /// The file, for folder items and library items with a local file; never shown to a brain.
    public var location: String?

    public init(id: String, kind: Kind, source: Source, title: String, artist: String? = nil, album: String? = nil,
                genre: String? = nil, show: String? = nil, season: Int? = nil, episode: Int? = nil, playCount: Int = 0,
                lastPlayed: Double? = nil, loved: Bool = false, purchased: Bool = false, watch: WatchState = .unknown,
                duration: Double? = nil, released: Double? = nil, added: Double? = nil, location: String? = nil) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.show = show
        self.season = season
        self.episode = episode
        self.playCount = playCount
        self.lastPlayed = lastPlayed
        self.loved = loved
        self.purchased = purchased
        self.watch = watch
        self.duration = duration
        self.released = released
        self.added = added
        self.location = location
    }

    public var isMusic: Bool { kind == .song || kind == .musicVideo || kind == .audioFile }
    public var isVideo: Bool { !isMusic }

    /// How a brain sees it: titles and numbers only, no path.
    public var line: String {
        var s: String
        switch kind {
        case .tvEpisode:
            s = (show.map { "\($0) " } ?? "") + episodeCode + " \"\(title)\""
        case .song, .musicVideo, .audioFile:
            s = "\"\(title)\"" + (artist.map { " by \($0)" } ?? "") + (album.map { ", from \($0)" } ?? "")
        default:
            s = "\"\(title)\""
        }
        s += " [\(kind.rawValue)]"
        if playCount > 0 { s += ", played \(playCount) time\(playCount == 1 ? "" : "s")" }
        if isVideo, watch != .unknown { s += ", \(watch == .inProgress ? "in progress" : watch.rawValue)" }
        if loved { s += ", loved" }
        return s
    }

    public var episodeCode: String {
        guard let season, let episode else { return "" }
        return String(format: "S%02dE%02d", season, episode)
    }
}

public struct MediaPlaylist: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var itemIDs: [String]

    public init(id: String, name: String, itemIDs: [String]) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
    }
}

/// The whole catalogue file.
public struct MediaCatalogue: Codable, Sendable, Equatable {
    public static let version = 1
    /// How long the day-by-day play counts are kept.
    public static let historyDays = 90

    public var version = MediaCatalogue.version
    public var refreshed: Double = 0
    public var items: [MediaItem] = []
    public var playlists: [MediaPlaylist] = []
    /// Plays gained per day: "YYYY-MM-DD" → item id → plays seen since the previous refresh.
    public var plays: [String: [String: Int]] = [:]
    /// The media folders the user picked.
    public var folders: [String] = []

    public init() {}

    public var data: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    public init?(data: Data) {
        guard let decoded = try? JSONDecoder().decode(MediaCatalogue.self, from: data) else { return nil }
        self = decoded
    }

    /// The catalogue after a refresh: the sources' fresh items replace those sources' old ones
    /// (sources not in `replacing` are kept), and every play-count rise since the last refresh is
    /// credited to `day`. Old days fall out after `historyDays`.
    public func refreshed(with fresh: [MediaItem], playlists newLists: [MediaPlaylist]?, replacing: Set<MediaItem.Source>,
                          now: Double, day: String, cutoffDay: String) -> MediaCatalogue {
        var next = self
        let before = Dictionary(items.map { ($0.id, $0.playCount) }, uniquingKeysWith: max)
        next.items = items.filter { !replacing.contains($0.source) } + fresh
        if let newLists { next.playlists = newLists }
        var gained = next.plays[day] ?? [:]
        for item in fresh {
            guard let old = before[item.id] else { continue }   // a new item: its count is history we did not see
            let rise = item.playCount - old
            if rise > 0 { gained[item.id, default: 0] += rise }
        }
        if !gained.isEmpty { next.plays[day] = gained }
        next.plays = next.plays.filter { $0.key >= cutoffDay }
        next.refreshed = now
        return next
    }

    // MARK: - Questions

    /// Items matching every word of `query` (title, artist, album, show, genre), best first.
    public func search(_ query: String, kinds: Set<MediaItem.Kind>? = nil, limit: Int = 15) -> [MediaItem] {
        let words = Self.words(query)
        let pool = items.filter { kinds?.contains($0.kind) ?? true }
        let hits = words.isEmpty ? pool : pool.filter { item in
            let hay = Self.words([item.title, item.artist, item.album, item.show, item.genre].compactMap { $0 }.joined(separator: " "))
            return words.allSatisfy { w in hay.contains { $0.hasPrefix(w) } }
        }
        return Array(hits.sorted { ($0.playCount, $0.lastPlayed ?? 0) > ($1.playCount, $1.lastPlayed ?? 0) }.prefix(limit))
    }

    public var music: [MediaItem] { items.filter(\.isMusic) }

    /// The top `n` values of `key` over songs, by total plays.
    public func top(_ key: (MediaItem) -> String?, n: Int) -> [(name: String, plays: Int)] {
        var totals: [String: Int] = [:]
        for item in music { if let k = key(item), !k.isEmpty { totals[k, default: 0] += item.playCount } }
        return totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(n).map { ($0.key, $0.value) }
    }

    /// The album with the most plays, and its artist.
    public func mostPlayedAlbum() -> (album: String, artist: String?)? {
        guard let best = top({ $0.album }, n: 1).first else { return nil }
        return (best.name, music.first { $0.album == best.name }?.artist)
    }

    /// Plays per item over the days in `from...to` ("YYYY-MM-DD", inclusive), most first.
    public func plays(from: String, to: String) -> [(item: MediaItem, plays: Int)] {
        var totals: [String: Int] = [:]
        for (day, counts) in plays where day >= from && day <= to {
            for (id, n) in counts { totals[id, default: 0] += n }
        }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return totals.compactMap { id, n in byID[id].map { ($0, n) } }
            .sorted { ($0.plays, $1.item.title) > ($1.plays, $0.item.title) }
    }

    /// A show's episodes in order (season, then episode; unnumbered last by release date).
    public func episodes(of show: String) -> [MediaItem] {
        let key = Self.words(show)
        return items.filter { $0.kind == .tvEpisode && $0.show.map { Self.words($0) == key } == true }
            .sorted { ($0.season ?? .max, $0.episode ?? .max, $0.released ?? 0) < ($1.season ?? .max, $1.episode ?? .max, $1.released ?? 0) }
    }

    /// "The latest episode": the first one not watched (an episode in progress counts) when the
    /// watch state is known, otherwise the newest released (the last in order).
    public func latestEpisode(of show: String) -> MediaItem? {
        let list = episodes(of: show)
        if list.contains(where: { $0.watch != .unknown }) {
            if let next = list.first(where: { $0.watch == .unwatched || $0.watch == .inProgress }) { return next }
        }
        return list.max { ($0.released ?? 0, $0.season ?? 0, $0.episode ?? 0) < ($1.released ?? 0, $1.season ?? 0, $1.episode ?? 0) }
    }

    /// The episodes not yet watched (unknown counts as not watched).
    public func remainingEpisodes(of show: String) -> [MediaItem] {
        episodes(of: show).filter { $0.watch != .watched }
    }

    static func words(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Batch C part 2: what the music library says about the user, as short facts for memory. Written
/// from the numbers (deterministic, on-device), tagged with `source` so "forget my music" removes
/// exactly these.
public enum MusicDistillation {
    public static let source = "music"

    public static func facts(_ catalogue: MediaCatalogue, today: String, weekStart: String, lastWeekStart: String) -> [String] {
        var out: [String] = []
        let artists = catalogue.top({ $0.artist }, n: 5).map(\.name)
        if !artists.isEmpty { out.append("The user's most played artists are \(list(artists)).") }
        let genres = catalogue.top({ $0.genre }, n: 3).map(\.name)
        if !genres.isEmpty { out.append("The user's favourite music genres are \(list(genres)).") }
        if let album = catalogue.mostPlayedAlbum() {
            out.append("The user's most played album is \(album.album)" + (album.artist.map { " by \($0)" } ?? "") + ".")
        }
        let loved = catalogue.music.filter(\.loved).sorted { $0.playCount > $1.playCount }.prefix(5)
        if !loved.isEmpty {
            out.append("Songs the user loves include " + list(loved.map { "\($0.title)" + ($0.artist.map { " by \($0)" } ?? "") }) + ".")
        }
        let rotation = catalogue.plays(from: weekStart, to: today).filter { $0.item.isMusic }.prefix(3)
        if !rotation.isEmpty {
            out.append("In the week from \(weekStart) the user has mostly been playing "
                       + list(rotation.map { "\($0.item.title)" + ($0.item.artist.map { " by \($0)" } ?? "") + " (\($0.plays) plays)" }) + ".")
        }
        if let repeatSong = catalogue.plays(from: lastWeekStart, to: weekStart).first(where: { $0.item.isMusic && $0.plays >= 5 }) {
            out.append("In the week from \(lastWeekStart) the user played \(repeatSong.item.title)"
                       + (repeatSong.item.artist.map { " by \($0)" } ?? "") + " on repeat (\(repeatSong.plays) plays).")
        }
        return out.map { String($0.prefix(MemoryFact.maxLength)) }
    }

    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        default: return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        }
    }
}

/// Batch C part 5b: a media file's name read as a show, season and episode where it has one:
/// "Show.Name.S01E02.Title.mkv", "Show Name - 1x02 - Title.mp4", "Show Name S1 E2.m4v".
public enum MediaFileName {
    public struct Parsed: Equatable, Sendable {
        public var title: String
        public var show: String?
        public var season: Int?
        public var episode: Int?

        public init(title: String, show: String?, season: Int?, episode: Int?) {
            self.title = title
            self.show = show
            self.season = season
            self.episode = episode
        }
    }

    public static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac"]

    public static func parse(_ fileName: String) -> Parsed {
        let base = (fileName as NSString).deletingPathExtension
        let spaced = base.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        let patterns = [#"(?i)^(.*?)[\s\-]*s(\d{1,2})\s*e(\d{1,3})(.*)$"#, #"(?i)^(.*?)[\s\-]*(\d{1,2})x(\d{2,3})(.*)$"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: spaced, range: NSRange(spaced.startIndex..., in: spaced)) else { continue }
            func group(_ i: Int) -> String {
                Range(m.range(at: i), in: spaced).map { String(spaced[$0]) } ?? ""
            }
            let show = clean(group(1))
            let rest = clean(group(4))
            return Parsed(title: rest.isEmpty ? (show.isEmpty ? clean(spaced) : show) : rest,
                          show: show.isEmpty ? nil : show, season: Int(group(2)), episode: Int(group(3)))
        }
        return Parsed(title: clean(spaced), show: nil, season: nil, episode: nil)
    }

    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—").union(.whitespaces))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
