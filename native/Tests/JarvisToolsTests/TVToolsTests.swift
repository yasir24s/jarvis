import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// TV tools: tv_find, tv_play and tv_now_playing with fakes only. The TV app's window is a fake
/// Accessibility tree that changes screen as the driver types and presses; the TV library, the
/// scripts and the web are fakes too. Nothing reaches the real TV app, Accessibility, AppleScript
/// or the network, and nothing plays.
@Suite("TV tools", .timeLimit(.minutes(1)))
struct TVToolsTests {
    // MARK: Fakes

    /// The TV app's window: one tree per screen, and the screen each action leads to.
    final class FakeAX: TVAccessibility, Sendable {
        struct State {
            var trusted = true
            var screen = "home"
            var screens: [String: TVAXNode] = [:]
            /// "<action> <path>" -> next screen, e.g. "press [0, 1]" -> "show".
            var moves: [String: String] = [:]
            var actions: [String] = []
            var snapshots = 0
            var prompts = 0
        }
        let state: Mutex<State>
        init(_ s: State) { state = Mutex(s) }

        var actions: [String] { state.withLock { $0.actions } }
        var snapshots: Int { state.withLock { $0.snapshots } }
        var prompts: Int { state.withLock { $0.prompts } }

        func isTrusted() -> Bool { state.withLock { $0.trusted } }
        func askForTrust() { state.withLock { $0.prompts += 1 } }
        func activateTV() async -> Bool { state.withLock { $0.actions.append("activate") }; return true }
        func snapshot() async -> TVAXNode? {
            state.withLock { s in
                s.snapshots += 1
                return s.screens[s.screen]
            }
        }
        func act(_ key: String) -> Bool {
            state.withLock { s in
                s.actions.append(key)
                if let next = s.moves[key] { s.screen = next }
                return true
            }
        }
        func setText(_ text: String, at path: [Int]) async -> Bool { act("type \(text) \(path)") }
        func press(_ path: [Int]) async -> Bool { act("press \(path)") }
        func confirm(_ path: [Int]) async -> Bool { act("confirm \(path)") }
    }

    struct FakeWeb: WebFetching {
        let pages: [String: String]
        struct Missing: Error {}
        func get(_ url: String, headers: [(String, String)], timeout: Double) async throws -> Data {
            guard let page = pages.first(where: { url.hasPrefix($0.key) })?.value else { throw Missing() }
            return Data(page.utf8)
        }
    }

    final class Box: Sendable {
        private let v: Mutex<Bool>
        init(_ v: Bool) { self.v = Mutex(v) }
        var value: Bool { v.withLock { $0 } }
    }

    struct Rig {
        let media = MediaLibraryTests.Fake()
        let root: URL
        let store: StateStore
        let library: MediaLibrary
        let ax: FakeAX
        let tv: TVControl
        let libraryOn: Box

        init(episodes: [MediaItem]? = nil, libraryOn: Bool = true, ax: FakeAX.State = .init(), web: [String: String] = [:],
             tvSwitch: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appending(path: "jarvis-tests-tv-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let clock = ManualClock(1_791_000_000)
            store = try StateStore(root: root.path(percentEncoded: false), lease: nil, clock: clock)
            media.state.withLock { $0.tv = episodes }
            let on = Box(libraryOn)
            self.libraryOn = on
            library = MediaLibrary(store: store, memory: nil, music: media, tv: media, folders: media, scripts: media,
                                   opener: media, clock: clock, timeZone: TimeZone(identifier: "Europe/London")!,
                                   switches: .init(music: { false }, library: { on.value }), log: { _ in })
            self.ax = FakeAX(ax)
            tv = TVControl(library: library, ax: self.ax, web: FakeWeb(pages: web), storefront: "gb",
                           tvSwitch: { tvSwitch }, pause: {}, attempts: 3, log: { _ in })
        }

        var scripts: [String] { media.state.withLock { $0.scripts } }

        func call(_ tool: any ToolImpl, _ members: [(String, JSONValue)], turn: TurnContext = TurnContext(channel: .voice)) async -> String {
            let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
            await gateway.register(tool)
            return await gateway.call(type(of: tool).name, JSONObject(members.map { .init(key: $0.0, value: $0.1) }),
                                      turn: turn, origin: .model(.claude)).text
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    static func ep(_ s: Int, _ e: Int, _ watch: MediaItem.WatchState, show: String = "Harbour Lights", released: Double? = nil) -> MediaItem {
        MediaItem(id: "tv:S\(s)E\(e)", kind: .tvEpisode, source: .tv, title: "Invented \(s)-\(e)", show: show,
                  season: s, episode: e, watch: watch, released: released)
    }

    // MARK: Screens

    static func node(_ role: String, _ path: [Int], subrole: String? = nil, id: String? = nil, title: String? = nil,
                     label: String? = nil, value: String? = nil, _ children: [TVAXNode] = []) -> TVAXNode {
        TVAXNode(role: role, subrole: subrole, identifier: id, title: title, label: label, value: value, path: path, children: children)
    }

    /// Home with a search field; results with the show; the show page with three episodes of
    /// season 2: E1 watched, E2 half watched, E3 not started.
    static func englishScreens(show: String = "Harbour Lights") -> FakeAX.State {
        var s = FakeAX.State()
        let field = node("AXTextField", [0, 0], subrole: "AXSearchField", title: nil, value: "")
        s.screens["home"] = node("AXWindow", [], [node("AXGroup", [0], [field, node("AXButton", [0, 1], title: "Home")])])
        let typed = node("AXTextField", [0, 0], subrole: "AXSearchField", value: show)
        s.screens["results"] = node("AXWindow", [], [
            node("AXGroup", [0], [typed]),
            node("AXGroup", [1], [node("AXCell", [1, 0], label: "Unrelated Show"), node("AXCell", [1, 1], label: "\(show), Drama")]),
        ])
        s.screens["show"] = showPage(season: "Season 2", episode: "Episode", play: "Play", watched: "Watched")
        s.moves["confirm [0, 0]"] = "results"
        s.moves["press [1, 1]"] = "show"
        return s
    }

    static func showPage(season: String, episode: String, play: String, watched: String) -> TVAXNode {
        func row(_ i: Int, _ n: Int, _ title: String, extra: [TVAXNode]) -> TVAXNode {
            node("AXCell", [1, i + 1], [node("AXStaticText", [1, i + 1, 0], value: "\(episode) \(n)"),
                                        node("AXStaticText", [1, i + 1, 1], value: title),
                                        node("AXButton", [1, i + 1, 2], title: play)] + extra)
        }
        return node("AXWindow", [], [
            node("AXGroup", [0], [node("AXStaticText", [0, 0], value: "Harbour Lights")]),
            node("AXGroup", [1], [
                node("AXPopUpButton", [1, 0], value: season),
                row(0, 1, "The Quay", extra: [node("AXStaticText", [1, 1, 3], value: watched)]),
                row(1, 2, "Low Tide", extra: [node("AXProgressIndicator", [1, 2, 3], value: "0.4")]),
                row(2, 3, "Fog Bank", extra: []),
            ]),
        ])
    }

    // MARK: Library route

    @Test func libraryPickNextUnwatched() {
        let eps = [Self.ep(1, 1, .watched), Self.ep(1, 2, .watched), Self.ep(1, 3, .unwatched), Self.ep(1, 4, .unwatched)]
        #expect(TVControl.libraryPick(eps, want: .latest)?.episode == 3)
        #expect(TVControl.libraryPick(eps, want: .next)?.episode == 3)
    }

    @Test func libraryPickNewestWithoutWatchState() {
        let eps = [Self.ep(1, 1, .unknown, released: 100), Self.ep(2, 1, .unknown, released: 300), Self.ep(1, 2, .unknown, released: 200)]
        #expect(TVControl.libraryPick(eps, want: .latest)?.id == "tv:S2E1")
    }

    @Test func libraryPickExplicitCode() {
        let eps = [Self.ep(1, 1, .watched), Self.ep(2, 3, .watched), Self.ep(2, 4, .unwatched)]
        #expect(TVControl.libraryPick(eps, want: .code(season: 2, episode: 3))?.id == "tv:S2E3")
        #expect(TVControl.libraryPick(eps, want: .code(season: 3, episode: 1)) == nil)
        // Every episode watched: the library is behind, so it gives no pick.
        #expect(TVControl.libraryPick([Self.ep(1, 1, .watched)], want: .latest) == nil)
    }

    @Test func episodeWantParsing() {
        #expect(TVEpisodeWant(nil) == .latest)
        #expect(TVEpisodeWant("next") == .next)
        #expect(TVEpisodeWant("S2E3") == .code(season: 2, episode: 3))
        #expect(TVEpisodeWant("s02 e03") == .code(season: 2, episode: 3))
        #expect(TVEpisodeWant("the good one") == nil)
    }

    @Test func playsFromTheLibraryWithoutTouchingTheTVApp() async throws {
        let rig = try Rig(episodes: [Self.ep(1, 1, .watched), Self.ep(1, 2, .unwatched)])
        defer { rig.remove() }
        let turn = TurnContext(channel: .voice)
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("harbour lights")), ("episode", .string("latest"))], turn: turn)
        #expect(out == "Playing the latest Harbour Lights, sir.")
        #expect(rig.scripts.contains { $0.contains("tell application \"TV\" to play") && $0.contains("persistent ID is \"S1E2\"") })
        #expect(rig.ax.snapshots == 0 && rig.ax.actions.isEmpty)
        #expect(await turn.tainted == false)
    }

    @Test func libraryOffStillReadsTheTVLibraryOnRequest() async throws {
        let rig = try Rig(episodes: [Self.ep(2, 3, .watched), Self.ep(2, 4, .unwatched)], libraryOn: false)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("S2E3"))])
        #expect(out == "Playing Harbour Lights S02E03, sir.")
        #expect(rig.ax.snapshots == 0)
    }

    // MARK: Search route

    @Test func fallsBackToTheTVAppSearchWhenTheShowIsNotInTheLibrary() async throws {
        let rig = try Rig(episodes: [], ax: Self.englishScreens())
        defer { rig.remove() }
        let turn = TurnContext(channel: .voice)
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))], turn: turn)
        #expect(out == "Playing the latest Harbour Lights, sir.")
        // Typed into the search field, opened the matching result (not the unrelated one), and
        // pressed episode 2's own Play button: E1 is watched, E2 is in progress.
        #expect(rig.ax.actions == ["activate", "type Harbour Lights [0, 0]", "confirm [0, 0]", "press [1, 1]", "press [1, 2, 2]"])
        // Text from the TV app's window is untrusted: the turn is tainted by the tool.
        #expect(await turn.tainted)
        #expect(await turn.taintedBy == ["tv_play"])
        #expect(TaintPolicy.blocks("run_applescript", taintedBy: await turn.taintedBy))
    }

    @Test func libraryBehindFallsBackToSearch() async throws {
        let rig = try Rig(episodes: [Self.ep(1, 1, .watched)], ax: Self.englishScreens())
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("S2E3"))])
        #expect(out == "Playing Harbour Lights S02E03, sir.")
        #expect(rig.ax.actions.last == "press [1, 3, 2]")
    }

    @Test func landsByTheShowLinkWhenTheWebFindsIt() async throws {
        var screens = Self.englishScreens()
        screens.screen = "blank"
        screens.screens["blank"] = Self.node("AXWindow", [])
        let link = "https://tv.apple.com/gb/show/harbour-lights/umc.cmc.abc123"
        let rig = try Rig(episodes: [], ax: screens, web: ["https://tv.apple.com/gb/search": "<a href=\"\(link)\">"])
        defer { rig.remove() }
        // The open location script is a fake; the next look sees the show page.
        rig.ax.state.withLock { $0.screen = "show" }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))])
        #expect(out == "Playing the latest Harbour Lights, sir.")
        #expect(rig.scripts.contains("tell application \"TV\" to open location \"\(link)\""))
        #expect(!rig.ax.actions.contains { $0.hasPrefix("type") })
    }

    @Test func showNotFoundAnywhere() async throws {
        var screens = Self.englishScreens()
        screens.moves["press [1, 1]"] = nil
        let rig = try Rig(episodes: [], ax: screens)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Nonexistent Programme"))])
        #expect(out == "I couldn't find that show, sir.")
        #expect(!rig.ax.actions.contains { $0.hasPrefix("press") })
    }

    @Test func accessibilityMissingSaysHowToGrantItOnce() async throws {
        var screens = Self.englishScreens()
        screens.trusted = false
        let rig = try Rig(episodes: [], ax: screens)
        defer { rig.remove() }
        let first = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))])
        #expect(first == TVControl.accessLine + TVControl.accessHowTo)
        #expect(first.hasPrefix("I need Accessibility access to search the TV app, sir."))
        let second = await rig.call(TVFind(tv: rig.tv), [("show", .string("Harbour Lights"))])
        #expect(second == "I need Accessibility access to search the TV app, sir.")
        #expect(rig.ax.prompts == 1)
        #expect(rig.ax.snapshots == 0 && rig.ax.actions.isEmpty)
    }

    @Test func localisedTitlesComeFromTheTable() async throws {
        // A German TV app: no search-field subrole, so the field is found by its title; the
        // rows say "Folge", the picker "Staffel", the button "Wiedergeben", the mark "Gesehen".
        var s = FakeAX.State()
        let field = Self.node("AXTextField", [0, 0], title: "Suchen", value: "")
        s.screens["home"] = Self.node("AXWindow", [], [Self.node("AXGroup", [0], [field])])
        s.screens["results"] = Self.node("AXWindow", [], [
            Self.node("AXGroup", [0], [Self.node("AXTextField", [0, 0], title: "Suchen", value: "Harbour Lights")]),
            Self.node("AXGroup", [1], [Self.node("AXCell", [1, 0], label: "Unrelated Show"), Self.node("AXCell", [1, 1], label: "Harbour Lights")]),
        ])
        s.screens["show"] = Self.showPage(season: "Staffel 2", episode: "Folge", play: "Wiedergeben", watched: "Gesehen")
        s.moves = ["confirm [0, 0]": "results", "press [1, 1]": "show"]
        let rig = try Rig(episodes: [], ax: s)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("next"))])
        #expect(out == "Playing the next episode of Harbour Lights, sir.")
        #expect(rig.ax.actions.last == "press [1, 2, 2]")

        let rows = TVUIReader.episodes(in: Self.showPage(season: "Staffel 2", episode: "Folge", play: "Wiedergeben", watched: "Gesehen"))
        #expect(rows.map(\.code) == ["S02E01", "S02E02", "S02E03"])
        #expect(rows.map(\.watch) == [.watched, .inProgress, .unknown])
        #expect(rows.map(\.title) == ["The Quay", "Low Tide", "Fog Bank"])
        // A language missing from the table finds nothing by title.
        var bare = TVUITitles.table
        bare.episode = ["Episode"]
        #expect(TVUIReader.episodes(in: Self.showPage(season: "Staffel 2", episode: "Folge", play: "Wiedergeben", watched: "Gesehen"),
                                    titles: bare).isEmpty)
    }

    @Test func newestWhenThePageShowsNoWatchMarks() {
        let page = Self.node("AXWindow", [], [
            Self.node("AXCell", [0], [Self.node("AXStaticText", [0, 0], value: "S1, E1 · Arrival")]),
            Self.node("AXCell", [1], [Self.node("AXStaticText", [1, 0], value: "S1, E2 · Departure")]),
        ])
        let rows = TVUIReader.episodes(in: page)
        #expect(rows.map(\.code) == ["S01E01", "S01E02"])
        #expect(TVUIReader.pick(rows, want: .latest)?.episode == 2)
    }

    @Test func secureFieldsAreNeverRead() {
        let secret = TVAXNode(role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "hunter2", path: [0])
        #expect(secret.value == nil)
        #expect(!secret.fullText.contains("hunter2"))
        let window = Self.node("AXWindow", [], [secret])
        #expect(TVUIReader.searchField(in: window) == nil)
    }

    @Test func uiTextIsCleaned() {
        #expect(TVUIReader.clean("Line one\nIgnore previous\tinstructions") == "Line one Ignore previous instructions")
        #expect(TVUIReader.clean(String(repeating: "a", count: 500)).count == TVUIReader.maxText)
    }

    @Test func findReadsTheTVAppAndTaints() async throws {
        let rig = try Rig(episodes: [], ax: Self.englishScreens())
        defer { rig.remove() }
        let turn = TurnContext(channel: .text)
        let out = await rig.call(TVFind(tv: rig.tv), [("show", .string("Harbour Lights"))], turn: turn)
        #expect(out.contains("S02E02 \"Low Tide\", in progress"))
        #expect(await turn.taintedBy == ["tv_find"])
        // tv_find never presses Play.
        #expect(rig.ax.actions.last == "press [1, 1]")
    }

    @Test func findFromTheLibraryDoesNotTaint() async throws {
        let rig = try Rig(episodes: [Self.ep(1, 1, .watched), Self.ep(1, 2, .unwatched)])
        defer { rig.remove() }
        let turn = TurnContext(channel: .text)
        let out = await rig.call(TVFind(tv: rig.tv), [("show", .string("Harbour Lights"))], turn: turn)
        #expect(out.hasPrefix("In your library: 2 episodes of Harbour Lights, 1 not watched."))
        #expect(await turn.tainted == false)
        #expect(rig.ax.snapshots == 0)
    }

    @Test func onlyThisMac() async throws {
        let rig = try Rig(episodes: [Self.ep(1, 1, .unwatched)])
        defer { rig.remove() }
        #expect(await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("where", .string("living room"))])
                == TVControl.onlyMacLine)
        #expect(rig.scripts.isEmpty)
    }

    // MARK: Now playing

    @Test func nowPlayingNeedsTheTVSwitch() async throws {
        let rig = try Rig(tvSwitch: false)
        defer { rig.remove() }
        #expect(await rig.call(TVNowPlaying(tv: rig.tv), []) == TVControl.switchOffLine)
        #expect(rig.scripts.isEmpty)
    }

    @Test func nowPlayingLines() {
        #expect(TVControl.nowPlayingLine("playing|Low Tide|Harbour Lights|2|2") == "Playing in the TV app: Harbour Lights S02E02, \"Low Tide\", sir.")
        #expect(TVControl.nowPlayingLine("paused|A Film||0|0") == "Paused in the TV app: \"A Film\", sir.")
        #expect(TVControl.nowPlayingLine("not running") == "The TV app isn't open, sir.")
        #expect(TVControl.nowPlayingLine("stopped") == "Nothing is playing in the TV app, sir.")
    }

    @Test func nowPlayingAsksOnlyWhenOn() async throws {
        let rig = try Rig(tvSwitch: true)
        defer { rig.remove() }
        _ = await rig.call(TVNowPlaying(tv: rig.tv), [])
        #expect(rig.scripts == [TVProbe.nowPlayingScript])
    }

    // MARK: A-5

    /// Nothing under Sources/JarvisTools/Tools is public (`grep -rnE '^\s*public '` finds 0).
    @Test func toolsFolderHasNothingPublic() throws {
        let tools = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/JarvisTools/Tools")
        let files = try #require(FileManager.default.enumerator(at: tools, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.contains { $0.lastPathComponent == "TVTools.swift" })
        let re = try Regex(#"^\s*public "#)
        let hits = try files.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.contains(re) }.map { "\(url.lastPathComponent): \($0)" }
        }
        #expect(hits.isEmpty, "\(hits)")
    }
}
