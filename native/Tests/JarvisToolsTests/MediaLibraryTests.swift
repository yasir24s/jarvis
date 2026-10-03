import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// Batch C parts 2 and 5b: the catalogue's keeper and the media tools, with fake readers, a fake
/// script runner and a fake opener in a temp state folder. Nothing touches the real Music or TV
/// library, and nothing plays.
@Suite("Batch C media library", .timeLimit(.minutes(1)))
struct MediaLibraryTests {
    final class Fake: MusicLibraryReading, TVLibraryReading, MediaFolderReading, ScriptRunning, MediaOpening, Sendable {
        let state = Mutex<(music: [MediaItem], tv: [MediaItem]?, files: [MediaItem], scripts: [String],
                           opened: [String], refuseTV: Bool, reads: Int)>(([], nil, [], [], [], false, 0))
        func read() -> (items: [MediaItem], playlists: [MediaPlaylist])? {
            state.withLock { s in
                s.reads += 1
                return (s.music, [MediaPlaylist(id: "music:P", name: "Invented Road Trip", itemIDs: s.music.map(\.id))])
            }
        }
        func read() async -> [MediaItem]? { state.withLock { $0.tv } }
        func read(_ folders: [String]) async -> [MediaItem] { state.withLock { folders.isEmpty ? [] : $0.files } }
        func run(_ script: String) async -> String { state.withLock { $0.scripts.append(script) }; return "" }
        func open(_ target: String, app: String) async -> Bool {
            state.withLock { s in
                s.opened.append("\(app): \(target)")
                return !(s.refuseTV && app == "TV")
            }
        }
    }

    struct Rig {
        let root: URL
        let store: StateStore
        let memory: MemoryStore
        let fake = Fake()
        let clock = ManualClock(1_791_000_000)
        let music = SharedFlagBox(false)
        let library = SharedFlagBox(false)
        let media: MediaLibrary

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-media-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try StateStore(root: root.path(percentEncoded: false), lease: nil, clock: clock)
            memory = MemoryStore(store: store, clock: clock)
            let m = music, l = library
            media = MediaLibrary(store: store, memory: memory, music: fake, tv: fake, folders: fake, scripts: fake, opener: fake,
                                 clock: clock, timeZone: TimeZone(identifier: "Europe/London")!,
                                 switches: .init(music: { m.value }, library: { l.value }), log: { _ in })
        }

        func call(_ tool: any ToolImpl, _ members: [(String, JSONValue)]) async -> String {
            let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
            await gateway.register(tool)
            return await gateway.call(type(of: tool).name, JSONObject(members.map { .init(key: $0.0, value: $0.1) }),
                                      turn: TurnContext(channel: .text), origin: .model(.claude)).text
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    final class SharedFlagBox: Sendable {
        private let v: Mutex<Bool>
        init(_ v: Bool) { self.v = Mutex(v) }
        var value: Bool { v.withLock { $0 } }
        func set(_ on: Bool) { v.withLock { $0 = on } }
    }

    static let songs = [
        MediaItem(id: "music:00000000000000A1", kind: .song, source: .music, title: "Glass Harbour", artist: "The Inventions",
                  album: "Tides", genre: "Invented Pop", playCount: 40, loved: true),
        MediaItem(id: "music:00000000000000B2", kind: .song, source: .music, title: "Slow Lantern", artist: "Mara Quill",
                  album: "Embers", genre: "Invented Folk", playCount: 12),
    ]
    static let episodes = [
        MediaItem(id: "tv:EP1", kind: .tvEpisode, source: .tv, title: "Pilot", show: "Invented Lasso", season: 1, episode: 1, watch: .watched),
        MediaItem(id: "tv:EP2", kind: .tvEpisode, source: .tv, title: "Biscuits", show: "Invented Lasso", season: 1, episode: 2, watch: .unwatched),
    ]

    @Test("with both switches off nothing is read and the tools say how to turn them on")
    func off() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.fake.state.withLock { $0.music = Self.songs }
        #expect(await rig.media.refresh(force: true) == nil)
        #expect(rig.fake.state.withLock { $0.reads } == 0)
        #expect(await rig.call(MediaSearch(library: rig.media), [("question", .string("top_artists"))]) == MediaSearch.off)
        #expect(await rig.call(MediaPlay(library: rig.media), [("what", .string("item")), ("query", .string("glass"))]) == MediaSearch.off)
        #expect(rig.fake.state.withLock { $0.scripts.isEmpty })
    }

    @Test("Learn From My Music: music read, facts tagged music written, TV left alone; refresh at most daily")
    func musicLearning() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.fake.state.withLock { $0.music = Self.songs; $0.tv = Self.episodes }
        rig.music.set(true)
        let c = try #require(await rig.media.refresh())
        #expect(c.items.map(\.source).allSatisfy { $0 == .music })
        let facts = rig.memory.loadFacts()?.facts ?? []
        #expect(facts.contains { $0.text == "The user's most played artists are The Inventions and Mara Quill." && $0.source == "music" })
        #expect(await rig.media.refresh() == nil)                     // not due yet
        rig.clock.advance(MediaLibrary.refreshEvery)
        rig.fake.state.withLock { $0.music[1].playCount = 20 }
        let next = try #require(await rig.media.refresh())
        #expect(next.plays.values.first?["music:00000000000000B2"] == 8)
        // The second distillation replaced the first (its new rotation fact included): none of the old ids stay.
        let again = rig.memory.loadFacts()?.facts.filter { $0.source == "music" } ?? []
        #expect(Set(again.map(\.id)).isDisjoint(with: facts.map(\.id)))
        #expect(Set(again.map(\.text)).count == again.count)
        #expect(again.contains { $0.text.contains("Slow Lantern by Mara Quill (8 plays)") })
    }

    @Test("forget my music: facts to the bin, music out of the catalogue, TV kept")
    func forget() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.fake.state.withLock { $0.music = Self.songs; $0.tv = Self.episodes }
        rig.music.set(true)
        rig.library.set(true)
        #expect(await rig.media.refresh(force: true) != nil)
        #expect(rig.media.forgetMusic())
        #expect((rig.memory.loadFacts()?.facts ?? []).allSatisfy { $0.source != "music" })
        #expect((rig.memory.loadForgotten()?.entries ?? []).contains { $0.fact.source == "music" })
        #expect(rig.media.load().items.map(\.id) == ["tv:EP1", "tv:EP2"])
        #expect(rig.media.forgetLibrary())
        #expect(rig.media.load().items.isEmpty)
    }

    @Test("the media tools: search, next episode, and the play routes")
    func tools() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.fake.state.withLock {
            $0.music = Self.songs
            $0.tv = Self.episodes
            $0.files = [MediaItem(id: "file:/m/An.Invented.Film.mkv", kind: .videoFile, source: .folder, title: "An Invented Film",
                                  location: "/m/An.Invented.Film.mkv")]
        }
        rig.library.set(true)
        #expect(rig.media.setFolders(["/m"]))
        let search = MediaSearch(library: rig.media), play = MediaPlay(library: rig.media)
        #expect(await rig.call(search, [("question", .string("next_episode")), ("query", .string("invented lasso"))])
                == "Invented Lasso S01E02 \"Biscuits\" [tvEpisode], unwatched")
        #expect(await rig.call(search, [("question", .string("most_played_album"))]) == "Tides by The Inventions")
        let found = await rig.call(search, [("question", .string("search")), ("query", .string("film"))])
        #expect(found.contains("An Invented Film") && !found.contains("/m/"))

        #expect(await rig.call(play, [("what", .string("latest_episode")), ("query", .string("Invented Lasso"))])
                == "Playing Invented Lasso S01E02, \"Biscuits\", sir.")
        #expect(await rig.call(play, [("what", .string("item")), ("query", .string("glass harbour"))])
                == "Playing Glass Harbour by The Inventions, sir.")
        #expect(await rig.call(play, [("what", .string("playlist")), ("query", .string("road trip"))]) == "Playing Invented Road Trip, sir.")
        #expect(await rig.call(play, [("what", .string("most_played_album"))]) == "Playing Tides by The Inventions, sir.")
        rig.fake.state.withLock { $0.refuseTV = true }
        #expect(await rig.call(play, [("what", .string("item")), ("query", .string("invented film"))]) == "Playing An Invented Film, sir.")
        let (scripts, opened) = rig.fake.state.withLock { ($0.scripts, $0.opened) }
        #expect(scripts.contains("tell application \"TV\" to play (first track of library playlist 1 whose persistent ID is \"EP2\")"))
        #expect(scripts.contains("tell application \"Music\" to play (first track of library playlist 1 whose persistent ID is \"00000000000000A1\")"))
        #expect(scripts.contains("tell application \"Music\" to play user playlist \"Invented Road Trip\""))
        #expect(scripts.contains { $0.contains("whose album is \"Tides\"") && $0.contains(MediaLibrary.queuePlaylist) })
        #expect(opened == ["TV: /m/An.Invented.Film.mkv", "QuickTime Player: /m/An.Invented.Film.mkv"])
    }

    @Test("the TV app's AppleScript lines parse into episodes, films and watch state")
    func tvParse() {
        let out = "AB12|Pilot|Invented Lasso|1|1|TV show|1|false|0|1800\n"
            + "CD34|Biscuits|Invented Lasso|1|2|TV show|0|true|0|1800\n"
            + "EF56|Halfway|Invented Lasso|1|3|TV show|0|true|300|1800\n"
            + "GH78|An Invented Film||0|0|movie|0|false|0|6000\n"
            + "IJ90|A song|x|0|0|music|0|false|0|200\n"
        let items = TVAppLibraryReader.parse(out)
        #expect(items.map(\.watch) == [.watched, .unwatched, .inProgress, .unknown])
        #expect(items.map(\.kind) == [.tvEpisode, .tvEpisode, .tvEpisode, .movie])
        #expect(items[3].show == nil && items[3].season == nil)
    }
}
