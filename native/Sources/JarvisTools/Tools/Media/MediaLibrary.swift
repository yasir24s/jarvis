@preconcurrency import AVFoundation
import Foundation
import iTunesLibrary
import JarvisCore

// Batch C parts 2 and 5b: the readers behind the media catalogue, the catalogue's store and
// refresh, and the play routes. The catalogue is memory/media-catalogue.json (`MediaCatalogue`),
// under JARVIS's memory folder and so inside its 10% storage cap.

/// Reads the Music library: items and playlists. The app's is ITLibrary (iTunesLibrary.framework,
/// which needs no entitlement outside the sandbox; macOS may ask for Media & Apple Music access).
public protocol MusicLibraryReading: Sendable {
    func read() -> (items: [MediaItem], playlists: [MediaPlaylist])?
}

/// Reads the TV app's library (shows, episodes, movies, home videos, watch state).
public protocol TVLibraryReading: Sendable {
    func read() async -> [MediaItem]?
}

/// Reads the media folders the user picked.
public protocol MediaFolderReading: Sendable {
    func read(_ folders: [String]) async -> [MediaItem]
}

/// Runs an AppleScript and returns its output (or an error text), as the data tools do.
public protocol ScriptRunning: Sendable {
    func run(_ script: String) async -> String
}

/// Opens a file or URL in an app (`open -a <app> <target>`); false when it could not.
public protocol MediaOpening: Sendable {
    func open(_ target: String, app: String) async -> Bool
}

// MARK: - The live readers

/// ITLibrary, read once per refresh.
public struct ITunesLibraryReader: MusicLibraryReading {
    public init() {}

    public func read() -> (items: [MediaItem], playlists: [MediaPlaylist])? {
        guard let library = try? ITLibrary(apiVersion: "1.0") else { return nil }
        let lovedIDs: Set<String> = Set(library.allPlaylists.filter { $0.distinguishedKind == .kindLovedSongs }
            .flatMap(\.items).map { Self.id($0) })
        var items: [MediaItem] = []
        for i in library.allMediaItems {
            let kind: MediaItem.Kind
            switch i.mediaKind {
            case .kindSong: kind = .song
            case .kindMusicVideo: kind = .musicVideo
            case .kindMovie: kind = .movie
            case .kindTVShow: kind = .tvEpisode
            case .kindHomeVideo: kind = .homeVideo
            default: continue
            }
            let id = Self.id(i)
            let watch: MediaItem.WatchState
            if !i.isVideo {
                watch = .unknown
            } else {
                switch i.playStatus {
                case .unplayed: watch = .unwatched
                case .partiallyPlayed: watch = .inProgress
                default: watch = i.playCount > 0 ? .watched : .unknown
                }
            }
            items.append(MediaItem(id: id, kind: kind, source: .music, title: i.title, artist: i.artist?.name,
                                   album: i.album.title, genre: i.genre.isEmpty ? nil : i.genre,
                                   show: i.videoInfo?.series, season: i.videoInfo.map { Int($0.season) },
                                   episode: i.videoInfo.map { $0.episodeOrder }, playCount: Int(i.playCount),
                                   lastPlayed: i.lastPlayedDate?.timeIntervalSince1970, loved: lovedIDs.contains(id),
                                   purchased: i.isPurchased, watch: watch, duration: Double(i.totalTime) / 1000,
                                   released: i.releaseDate?.timeIntervalSince1970, added: i.addedDate?.timeIntervalSince1970,
                                   location: i.location?.path(percentEncoded: false)))
        }
        let playlists = library.allPlaylists.filter { $0.isVisible && !$0.isPrimary && $0.distinguishedKind == .kindNone }
            .map { MediaPlaylist(id: "music:" + $0.persistentID.stringValue, name: $0.name, itemIDs: $0.items.map { Self.id($0) }) }
        return (items, playlists)
    }

    static func id(_ item: ITLibMediaItem) -> String { "music:" + String(format: "%016llX", item.persistentID.uint64Value) }
}

/// The TV app's library through its AppleScript dictionary: every track of the library playlist,
/// one line each (persistent ID | name | show | season | episode | media kind | played count |
/// unplayed | bookmark | duration). Launching the TV app is avoided: an app that is not running
/// is not read.
public struct TVAppLibraryReader: TVLibraryReading {
    let scripts: any ScriptRunning

    public init(scripts: any ScriptRunning) {
        self.scripts = scripts
    }

    public static let script = """
        if application "TV" is not running then return "not running"
        set out to ""
        tell application "TV"
          repeat with t in (every track of library playlist 1)
            set out to out & (persistent ID of t) & "|" & (name of t) & "|" & (show of t) & "|" & (season number of t) & "|" & (episode number of t) & "|" & (media kind of t as text) & "|" & (played count of t) & "|" & (unplayed of t) & "|" & (bookmark of t) & "|" & (duration of t) & linefeed
          end repeat
        end tell
        return out
        """

    public func read() async -> [MediaItem]? {
        let out = await scripts.run(Self.script)
        guard out != "not running", !out.lowercased().contains("error") else { return nil }
        return Self.parse(out)
    }

    public static func parse(_ out: String) -> [MediaItem] {
        out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 10, !f[0].isEmpty else { return nil }
            let kind: MediaItem.Kind
            switch f[5].lowercased() {
            case "movie": kind = .movie
            case "tv show": kind = .tvEpisode
            case "home video": kind = .homeVideo
            default: return nil
            }
            let plays = Int(f[6]) ?? 0
            let unplayed = f[7] == "true"
            let bookmark = Double(f[8]) ?? 0
            let watch: MediaItem.WatchState = unplayed ? (bookmark > 0 ? .inProgress : .unwatched)
                : (bookmark > 0 ? .inProgress : (plays > 0 ? .watched : .unknown))
            let season = Int(f[3]).flatMap { $0 > 0 ? $0 : nil }
            let episode = Int(f[4]).flatMap { $0 > 0 ? $0 : nil }
            return MediaItem(id: "tv:" + f[0], kind: kind, source: .tv, title: f[1], show: f[2].isEmpty ? nil : f[2],
                             season: season, episode: episode, playCount: plays, watch: watch, duration: Double(f[9]))
        }
    }
}

/// The picked folders, walked for audio and video files; titles from the file's metadata when it
/// has one, else from the name (`MediaFileName`), durations from AVFoundation.
public struct MediaFolderReader: MediaFolderReading {
    public static let limit = 5000
    public init() {}

    public func read(_ folders: [String]) async -> [MediaItem] {
        var out: [MediaItem] = []
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: URL(filePath: folder, directoryHint: .isDirectory),
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL, out.count < Self.limit {
                let ext = url.pathExtension.lowercased()
                let video = MediaFileName.videoExtensions.contains(ext)
                guard video || MediaFileName.audioExtensions.contains(ext) else { continue }
                let parsed = MediaFileName.parse(url.lastPathComponent)
                let asset = AVURLAsset(url: url)
                let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) }.flatMap { $0.isFinite ? $0 : nil }
                var title = parsed.title
                if parsed.show == nil, let meta = try? await asset.load(.commonMetadata),
                   let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: .commonIdentifierTitle).first,
                   let t = try? await item.load(.stringValue), !t.isEmpty {
                    title = t
                }
                let path = url.path(percentEncoded: false)
                out.append(MediaItem(id: "file:" + path, kind: video ? (parsed.show != nil ? .tvEpisode : .videoFile) : .audioFile,
                                     source: .folder, title: title, show: parsed.show, season: parsed.season,
                                     episode: parsed.episode, duration: duration, location: path))
            }
        }
        return out
    }
}

/// osascript through the bounded runner the data tools use.
public struct LiveScripts: ScriptRunning {
    public init() {}
    public func run(_ script: String) async -> String {
        await AppleScriptRunner(runner: BoundedRunner(environment: BoundedRunner.agentEnvironment())).run(script)
    }
}

/// `/usr/bin/open -a <app> <target>`.
public struct LiveOpener: MediaOpening {
    public init() {}
    public func open(_ target: String, app: String) async -> Bool {
        let out = await BoundedRunner(environment: BoundedRunner.agentEnvironment())
            .run(["/usr/bin/open", "-a", app, target], input: Data(), timeout: 15)
        return out?.status == 0
    }
}
