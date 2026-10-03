import Foundation
import JarvisCore
import Synchronization

/// Batch C parts 2 and 5b: the media catalogue's keeper. It refreshes at most daily (or when the
/// picked folders change, or when asked), distils the music into memory facts tagged `music`
/// while "Learn From My Music" is on, and forgets on request. Nothing is read while both
/// switches are off.
public final class MediaLibrary: Sendable {
    public static let refreshEvery: Double = 86_400
    public static let queuePlaylist = "JARVIS Up Next"

    public struct Switches: Sendable {
        /// "Learn From My Music": the music library is read and distilled into memory.
        public var music: @Sendable () -> Bool
        /// "Media Library": the music, TV and folder catalogue, for the media tools.
        public var library: @Sendable () -> Bool
        public init(music: @escaping @Sendable () -> Bool, library: @escaping @Sendable () -> Bool) {
            self.music = music
            self.library = library
        }
    }

    let store: StateStore
    let memory: MemoryStore?
    let music: any MusicLibraryReading
    let tv: any TVLibraryReading
    let folders: any MediaFolderReading
    let scripts: any ScriptRunning
    let opener: any MediaOpening
    let clock: any JarvisClock
    let timeZone: TimeZone
    let switches: Switches
    let log: @Sendable (String) -> Void
    private let lock = Mutex(())

    public init(store: StateStore, memory: MemoryStore?, music: any MusicLibraryReading = ITunesLibraryReader(),
                tv: any TVLibraryReading = TVAppLibraryReader(scripts: LiveScripts()),
                folders: any MediaFolderReading = MediaFolderReader(), scripts: any ScriptRunning = LiveScripts(),
                opener: any MediaOpening = LiveOpener(), clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .autoupdatingCurrent, switches: Switches,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.store = store
        self.memory = memory
        self.music = music
        self.tv = tv
        self.folders = folders
        self.scripts = scripts
        self.opener = opener
        self.clock = clock
        self.timeZone = timeZone
        self.switches = switches
        self.log = log
    }

    /// The catalogue on disk; empty when there is none or it cannot be read.
    public func load() -> MediaCatalogue {
        store.read(.mediaCatalogue).flatMap(MediaCatalogue.init(data:)) ?? MediaCatalogue()
    }

    func day(_ t: Double) -> String {
        PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: t), timeZone: timeZone)
    }

    /// Picks the media folders (the catalogue's folder items follow at the next refresh).
    @discardableResult
    public func setFolders(_ paths: [String]) -> Bool {
        lock.withLock { _ in
            var c = load()
            c.folders = paths
            return store.write(c.data, to: .mediaCatalogue)
        }
    }

    /// Refreshes when due (a day since the last, or `force`); nil when nothing was read.
    @discardableResult
    public func refresh(force: Bool = false) async -> MediaCatalogue? {
        let learnMusic = switches.music(), library = switches.library()
        guard learnMusic || library else { return nil }
        let current = load()
        let now = clock.now()
        guard force || now - current.refreshed >= Self.refreshEvery else { return nil }
        var fresh: [MediaItem] = []
        var replacing: Set<MediaItem.Source> = []
        var lists: [MediaPlaylist]?
        if let read = music.read() {
            fresh += read.items
            lists = read.playlists
            replacing.insert(.music)
        } else {
            log("media: the music library could not be read (no access, or no library)")
        }
        if library {
            if let shows = await tv.read() {
                fresh += shows
                replacing.insert(.tv)
            }
            fresh += await folders.read(current.folders)
            replacing.insert(.folder)
        }
        let cutoff = day(now - Double(MediaCatalogue.historyDays) * 86_400)
        let next: MediaCatalogue = lock.withLock { _ in
            let latest = load()
            var updated = latest.refreshed(with: fresh, playlists: lists, replacing: replacing, now: now, day: day(now), cutoffDay: cutoff)
            if !library {   // music learning alone keeps only the music
                updated.items = updated.items.filter { $0.source == .music }
            }
            if !store.write(updated.data, to: .mediaCatalogue) { log("media: media-catalogue.json not saved") }
            return updated
        }
        log("media: catalogue refreshed, \(next.items.count) item(s), \(next.playlists.count) playlist(s)")
        if learnMusic { distil(next, now: now) }
        return next
    }

    /// The music facts, replacing the last ones (they are this source's own, so the guard lets
    /// them go).
    func distil(_ catalogue: MediaCatalogue, now: Double) {
        guard let memory else { return }
        let weekday = Calendar(identifier: .gregorian).component(.weekday, from: Date(timeIntervalSince1970: now))
        let sinceMonday = Double((weekday + 5) % 7) * 86_400
        let lines = MusicDistillation.facts(catalogue, today: day(now), weekStart: day(now - sinceMonday),
                                            lastWeekStart: day(now - sinceMonday - 7 * 86_400))
        let old = Set((memory.loadFacts()?.facts ?? []).filter { $0.source == MusicDistillation.source }.map(\.id))
        let outcome = memory.writeFacts(allowingRemovalOf: old) { file in
            file.facts.removeAll { $0.source == MusicDistillation.source }
            for line in lines {
                file.facts.append(MemoryFact(id: UUID().uuidString.lowercased(), text: line, source: MusicDistillation.source,
                                             created: now, updated: now, by: .local))
            }
            return true
        }
        log("media: \(lines.count) music fact(s) written (\(outcome == .saved ? "saved" : "not saved"))")
    }

    /// "Forget my music": the music facts go to the forgotten bin, and the music leaves the
    /// catalogue with its play history. The TV and folder items stay.
    @discardableResult
    public func forgetMusic() -> Bool {
        var ok = true
        if let memory {
            let outcome = memory.forget(byIDs: true) { file in
                Set(file.facts.indices.filter { file.facts[$0].source == MusicDistillation.source })
            }
            if case .moved = outcome {} else if outcome != .nothing { ok = false }
        }
        lock.withLock { _ in
            var c = load()
            let musicIDs = Set(c.items.filter { $0.source == .music }.map(\.id))
            c.items.removeAll { $0.source == .music }
            c.playlists = []
            c.plays = c.plays.mapValues { $0.filter { !musicIDs.contains($0.key) } }.filter { !$0.value.isEmpty }
            c.refreshed = 0
            ok = store.write(c.data, to: .mediaCatalogue) && ok
        }
        return ok
    }

    /// "Forget" for Media Library: the whole catalogue, folders included.
    @discardableResult
    public func forgetLibrary() -> Bool {
        lock.withLock { _ in store.write(MediaCatalogue().data, to: .mediaCatalogue) }
    }

    // MARK: - Playing

    public enum Route: String, Sendable { case musicApp = "Music", tvApp = "TV", quickTime = "QuickTime Player" }

    /// Plays one item through its route: songs and library videos in Music (by persistent ID), TV
    /// app items in the TV app, and folder files in the TV app, or QuickTime when TV refuses them.
    public func play(_ item: MediaItem) async -> Route? {
        switch item.source {
        case .music:
            let pid = String(item.id.dropFirst("music:".count))
            if item.isVideo, let path = item.location, await opener.open(path, app: Route.tvApp.rawValue) { return .tvApp }
            let out = await scripts.run("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"\(pid)\")")
            return out.lowercased().contains("error") ? nil : .musicApp
        case .tv:
            let pid = String(item.id.dropFirst("tv:".count))
            let out = await scripts.run("tell application \"TV\" to play (first track of library playlist 1 whose persistent ID is \"\(pid)\")")
            return out.lowercased().contains("error") ? nil : .tvApp
        case .folder:
            guard let path = item.location else { return nil }
            if await opener.open(path, app: Route.tvApp.rawValue) { return .tvApp }
            return await opener.open(path, app: Route.quickTime.rawValue) ? .quickTime : nil
        }
    }

    /// An album or playlist in Music: a playlist is played by name; an album is queued in
    /// "JARVIS Up Next" (deleted and made again each time: Music's scripting cannot remove a
    /// track from a playlist) and played.
    public func playCollection(album: String?, playlist: String?) async -> Bool {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script: String
        if let playlist {
            script = "tell application \"Music\" to play user playlist \"\(esc(playlist))\""
        } else if let album {
            let q = esc(Self.queuePlaylist)
            script = """
                tell application "Music"
                  if exists user playlist "\(q)" then delete user playlist "\(q)"
                  set p to make new user playlist with properties {name:"\(q)"}
                  duplicate (every track of library playlist 1 whose album is "\(esc(album))") to p
                  play p
                end tell
                """
        } else { return false }
        return !(await scripts.run(script)).lowercased().contains("error")
    }
}

/// `media_search`: questions about the catalogue. Titles only, never file paths.
public struct MediaSearch: ToolImpl {
    public static let name = "media_search"
    public static let schema = ToolSchema(
        name: name,
        description: "Look in the user's own media catalogue on this Mac: their Music library (play counts, loved songs, playlists), their TV app library and their media folders. question: 'search' (with query), 'top_artists', 'top_genres', 'most_played_album', 'repeats' (what they played most in the last 7 days, or the 7 days before with weeks_ago 1), 'remaining_episodes' or 'next_episode' (with query = the show). Only works while Media Library or Learn From My Music is on.",
        parametersJSON: #"{"type": "object", "properties": {"question": {"type": "string", "enum": ["search", "top_artists", "top_genres", "most_played_album", "repeats", "remaining_episodes", "next_episode"]}, "query": {"type": "string"}, "kind": {"type": "string", "enum": ["music", "tv", "movie", "any"]}, "weeks_ago": {"type": "integer"}}, "required": ["question"]}"#)

    public static let off = "My media catalogue is switched off, sir. Turn on Media Library or Learn From My Music in Learning Sources."

    let library: MediaLibrary

    public init(library: MediaLibrary) {
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

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
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
public struct MediaPlay: ToolImpl {
    public static let name = "media_play"
    public static let schema = ToolSchema(
        name: name,
        description: "Play something from the user's own media catalogue on this Mac. what: 'item' (best match for query), 'latest_episode' (query = the show: the next unwatched episode, or the newest), 'album' (query = album), 'most_played_album', or 'playlist' (query = playlist name). Songs and albums play in Music; TV and movies in the TV app; files from media folders in the TV app or QuickTime.",
        parametersJSON: #"{"type": "object", "properties": {"what": {"type": "string", "enum": ["item", "latest_episode", "album", "most_played_album", "playlist"]}, "query": {"type": "string"}, "kind": {"type": "string", "enum": ["music", "tv", "movie", "any"]}}, "required": ["what"]}"#)

    let library: MediaLibrary

    public init(library: MediaLibrary) {
        self.library = library
    }

    public func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
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
