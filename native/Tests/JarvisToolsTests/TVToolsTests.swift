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
            /// "<action> <path>" (or "<screen>|<action> <path>") -> next screen,
            /// e.g. "AXPress [0, 1]" -> "show".
            /// The actions an element lists (AXPress when not given).
            var supported: [[Int]: [String]] = [:]
            /// The actions of an element not in `supported` (the real page's cells list none).
            var defaultActions = ["AXPress", "AXConfirm"]
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
                if let next = s.moves["\(s.screen)|\(key)"] ?? s.moves[key] { s.screen = next }
                return true
            }
        }
        func setText(_ text: String, at path: [Int]) async -> Bool { act("type \(text) \(path)") }
        func actions(_ path: [Int]) async -> [String] { state.withLock { $0.supported[path] ?? $0.defaultActions } }
        func perform(_ action: String, at path: [Int]) async -> Bool {
            guard state.withLock({ ($0.supported[path] ?? $0.defaultActions).contains(action) }) else {
                state.withLock { $0.actions.append("refused \(action) \(path)") }
                return false
            }
            return act("\(action) \(path)")
        }
        /// A click lands on the smallest element whose frame holds the point (a chevron sits on
        /// top of the cell under it): "click <path>".
        func click(x: Double, y: Double) async -> Bool {
            let hit = state.withLock { s in
                s.screens[s.screen]?.all.filter { $0.frame?.contains(x: x, y: y) == true }
                    .min { ($0.frame!.width * $0.frame!.height) < ($1.frame!.width * $1.frame!.height) }?.path
            }
            return act(hit.map { "click \($0)" } ?? "click nothing (\(Int(x)),\(Int(y)))")
        }
        func scroll(horizontal: Int, x: Double, y: Double) async -> Bool { act("scroll \(horizontal)") }
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

    final class Lines: Sendable {
        private let list = Mutex<[String]>([])
        func add(_ s: String) { list.withLock { $0.append(s) } }
        var all: [String] { list.withLock { $0 } }
    }

    struct Rig {
        let media = MediaLibraryTests.Fake()
        let root: URL
        let store: StateStore
        let library: MediaLibrary
        let ax: FakeAX
        let tv: TVControl
        let libraryOn: Box
        let logged = Lines()
        var logs: [String] { logged.all }

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
                           tvSwitch: { tvSwitch }, pause: {}, attempts: 3, log: { [logged] line in logged.add(line) })
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
                     label: String? = nil, value: String? = nil, frame: TVAXFrame? = nil, enabled: Bool? = nil,
                     _ children: [TVAXNode] = []) -> TVAXNode {
        TVAXNode(role: role, subrole: subrole, identifier: id, title: title, label: label, value: value, path: path, children: children,
                 frame: frame, enabled: enabled)
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
        s.moves["AXConfirm [0, 0]"] = "results"
        s.moves["AXPress [1, 1]"] = "show"
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
        #expect(rig.ax.actions == ["activate", "type Harbour Lights [0, 0]", "AXConfirm [0, 0]", "AXPress [1, 1]", "AXPress [1, 2, 2]"])
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
        #expect(rig.ax.actions.last == "AXPress [1, 3, 2]")
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
        screens.moves["AXPress [1, 1]"] = nil
        let rig = try Rig(episodes: [], ax: screens)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Nonexistent Programme"))])
        #expect(out == "I couldn't find that show, sir.")
        #expect(!rig.ax.actions.contains { $0.hasPrefix("AXPress") })
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
        s.moves = ["AXConfirm [0, 0]": "results", "AXPress [1, 1]": "show"]
        let rig = try Rig(episodes: [], ax: s)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("next"))])
        #expect(out == "Playing the next episode of Harbour Lights, sir.")
        #expect(rig.ax.actions.last == "AXPress [1, 2, 2]")

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
        #expect(rig.ax.actions.last == "AXPress [1, 1]")
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

    // MARK: The real show page (tv-ax-showpage.txt and the live checks)

    static let showID = "umc.cmc.harbour1"
    static func cellID(_ s: Int, _ e: Int, playable: Bool = true, parent: String = showID) -> String {
        "UIA.TV.Cell.episodeLockup.\(playable ? "play" : "episode").parentId=\"\(parent)\".id=\"umc.cmc.s\(s)e\(e)\""
    }
    static let trailerID = "UIA.TV.Cell.lockup.play.parentId=\"uts.col.Trailers.\(showID)\".id=\"umc.cmc.t1\""
    static let window = TVAXFrame(x: 0, y: 0, width: 1000, height: 800)
    static func f(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> TVAXFrame { TVAXFrame(x: x, y: y, width: w, height: h) }

    /// One episode cell in the row: its episode, its x, and whether it is the `.play` kind.
    struct Cell { let e: Int; let x: Double; var playable = true }

    /// The shape of the TV app's real show page, as checked live:
    /// - a banner whose text area names the latest or up-next episode;
    /// - an Episodes list of cells with identifiers, frames and no text or AX actions (each
    ///   holding a download indicator); `.play` cells and the `.episode` kind;
    /// - the season picker (value missing, title "Season N") and its menu when open;
    /// - the row's chevrons (rawValue 0 "right arrow" forward, rawValue 1 "left arrow" back),
    ///   dimmed unless `chevrons`; a Trailers list with another row's chevron (".id=2").
    /// Paths: banner [0, 0]; picker [0, 1, 0] and menu items [0, 1, 0, 0, j]; back chevron
    /// [0, 1, 1]; forward chevron [0, 1, 2]; cells [0, 1, 3 + i]; trailer [0, 2, 0].
    static func realPage(banner: String?, season: Int, cells: [Cell], menu: [Int]? = nil, chevrons: Bool = false) -> TVAXNode {
        let bannerNode = banner.map { text in
            node("AXGroup", [0, 0], id: "UIA.TV.Cell.canonicalBanner.none.id=\"CanonicalBanner\"", frame: f(0, 60, 1000, 300), [
                node("AXStaticText", [0, 0, 0], value: "New Episode Every Wednesday"),
                node("AXUnknown", [0, 0, 1], label: "Harbour Lights"),
                node("AXTextArea", [0, 0, 2], value: text),
                node("AXButton", [0, 0, 3], value: "MORE"),
                node("AXButton", [0, 0, 4], id: "UIA.TV.Button.canonical.upNext.id=\"\(showID)\".state=\"added\"", label: "Remove from Watchlist"),
            ])
        } ?? node("AXGroup", [0, 0])
        let open = menu.map { seasons in
            [node("AXMenu", [0, 1, 0, 0], seasons.enumerated().map { j, k in
                node("AXMenuItem", [0, 1, 0, 0, j], title: "Season \(k)", frame: f(40, 450 + Double(j) * 30, 150, 30))
            })]
        } ?? []
        var row = [
            node("AXPopUpButton", [0, 1, 0], id: "UIA.TV.Button.seasonPicker", title: "Season \(season)", label: "Choose Season",
                 frame: f(40, 420, 150, 30), open),
            node("AXButton", [0, 1, 1], id: "CollectionChevronIndicatorView.ChevronDirection(rawValue: 1)",
                 label: "left arrow", frame: f(0, 520, 20, 40), enabled: chevrons),
            node("AXButton", [0, 1, 2], id: "CollectionChevronIndicatorView.ChevronDirection(rawValue: 0)",
                 label: "right arrow", frame: f(978, 520, 20, 40), enabled: chevrons),
        ]
        row += cells.enumerated().map { i, c in
            node("AXGroup", [0, 1, 3 + i], id: cellID(season, c.e, playable: c.playable), frame: f(c.x, 470, 230, 140),
                 [node("AXMenuButton", [0, 1, 3 + i, 0], id: "UIA.TV.Indicator.DownloadState.id=\"umc.cmc.s\(season)e\(c.e)\"")])
        }
        return node("AXWindow", [], frame: window, [node("AXList", [0], label: "Harbour Lights", [
            bannerNode,
            node("AXList", [0, 1], label: "Episodes", row),
            node("AXList", [0, 2], label: "Trailers", [
                node("AXGroup", [0, 2, 0], id: trailerID, frame: f(25, 650, 230, 140)),
                node("AXButton", [0, 2, 1], id: "CollectionChevronIndicatorView.ChevronDirection(rawValue: 0).id=2", label: "right arrow",
                     frame: f(978, 700, 20, 40), enabled: true),
            ]),
        ])])
    }

    /// Season 2 has three episodes (the third the `.episode` kind), season 1 two. "s2mid" has
    /// the row scrolled so E1's centre is left of the window; a back scroll gives "s2start".
    static func realScreens(banner: String? = "S2, E3 · Fog Bank:  Season finale.", start: String = "s2mid",
                            chevrons: Bool = false) -> FakeAX.State {
        let s2mid = [Cell(e: 1, x: -220), Cell(e: 2, x: 25), Cell(e: 3, x: 270, playable: false)]
        let s2start = [Cell(e: 1, x: 25), Cell(e: 2, x: 270), Cell(e: 3, x: 515, playable: false)]
        let s1start = [Cell(e: 1, x: 25), Cell(e: 2, x: 270)]
        var s = FakeAX.State()
        s.defaultActions = []
        s.screens = [
            "s2mid": realPage(banner: banner, season: 2, cells: s2mid, chevrons: chevrons),
            "s2mid-menu": realPage(banner: banner, season: 2, cells: s2mid, menu: [1, 2], chevrons: chevrons),
            "s2start": realPage(banner: banner, season: 2, cells: s2start, chevrons: chevrons),
            "s1start": realPage(banner: banner, season: 1, cells: s1start, chevrons: chevrons),
            "s1-menu": realPage(banner: banner, season: 1, cells: s1start, menu: [1, 2], chevrons: chevrons),
        ]
        s.screen = start
        // The picker and its menu items have AX actions; cells and chevrons have none.
        s.supported = [[0, 1, 0]: ["AXPress", "AXShowMenu"], [0, 1, 0, 0, 0]: ["AXPress"], [0, 1, 0, 0, 1]: ["AXPress"]]
        s.moves = [
            "s2mid|scroll 400": "s2start",
            "s2mid|click [0, 1, 1]": "s2start",              // the back chevron, when lit
            "s2mid|AXPress [0, 1, 0]": "s2mid-menu",         // the season picker
            "s2mid-menu|AXPress [0, 1, 0, 0, 0]": "s1start",
            "s1start|AXPress [0, 1, 0]": "s1-menu",
            "s1-menu|AXPress [0, 1, 0, 0, 1]": "s2mid",
        ]
        return s
    }

    static let link = "https://tv.apple.com/gb/show/harbour-lights/umc.cmc.abc123"
    static let searchPage = ["https://tv.apple.com/gb/search": "<a href=\"\(link)\">"]

    @Test func latestClicksTheBannersEpisodeCellAfterScrollingBack() async throws {
        let rig = try Rig(episodes: [], ax: Self.realScreens(), web: Self.searchPage)
        defer { rig.remove() }
        let turn = TurnContext(channel: .voice)
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))], turn: turn)
        #expect(out == "Playing the latest Harbour Lights, sir.")
        // The chevrons are dimmed, so the row is scrolled back with the wheel until it stops;
        // cells are numbered by x (E3 is the `.episode` kind); E3 lists no AX actions, so the
        // window is brought forward and E3's centre clicked. Never the banner or the trailer.
        #expect(rig.ax.actions == ["activate", "scroll 400", "scroll 400", "activate", "click [0, 1, 5]"])
        #expect(rig.logs.contains("tv: episode cell S02E03 (id=umc.cmc.s2e3) actions []"))
        #expect(rig.logs.contains("tv: clicked cell at (630,540) (no AX actions)"))
        #expect(await turn.taintedBy == ["tv_play"])
    }

    @Test func litChevronsAreClickedToScroll() async throws {
        let rig = try Rig(episodes: [], ax: Self.realScreens(chevrons: true), web: Self.searchPage)
        defer { rig.remove() }
        _ = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))])
        // The back chevron is rawValue 1 at [0, 1, 1]; it has no AX actions, so it is clicked.
        #expect(Array(rig.ax.actions.prefix(3)) == ["activate", "activate", "click [0, 1, 1]"])
        #expect(rig.logs.contains("tv: clicked back chevron at (10,540) (no AX actions)"))
        #expect(rig.ax.actions.last == "click [0, 1, 5]")
    }

    @Test func chevronsByRawValueAndOnlyThisRows() {
        let page = Self.realPage(banner: nil, season: 2, cells: [Cell(e: 1, x: 25)])
        #expect(TVUIReader.chevron(in: page, forward: true)?.path == [0, 1, 2])
        #expect(TVUIReader.chevron(in: page, forward: false)?.path == [0, 1, 1])
        // Another row's chevron first in the tree (".id=2") is never taken.
        let other = Self.node("AXWindow", [], [
            Self.node("AXButton", [0], id: "CollectionChevronIndicatorView.ChevronDirection(rawValue: 0).id=2", label: "right arrow"),
            Self.node("AXButton", [1], label: "right arrow"),
        ])
        #expect(TVUIReader.chevron(in: other, forward: true)?.path == [1])
    }

    @Test func showDefaultUIWhenTheCellListsIt() async throws {
        var screens = Self.realScreens(start: "s2start")
        screens.supported[[0, 1, 5]] = ["AXShowDefaultUI", "AXScrollToVisible"]
        let rig = try Rig(episodes: [], ax: screens, web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))])
        #expect(out == "Playing the latest Harbour Lights, sir.")
        #expect(Array(rig.ax.actions.suffix(2)) == ["AXScrollToVisible [0, 1, 5]", "AXShowDefaultUI [0, 1, 5]"])
        #expect(rig.logs.contains("tv: episode cell S02E03 used AXShowDefaultUI"))
        #expect(!rig.ax.actions.contains { $0.hasPrefix("click") })
    }

    @Test func aCellOutsideTheWindowIsScrolledInBeforeTheClick() async throws {
        // The wheel does nothing here, but E1 lists AXScrollToVisible.
        var screens = Self.realScreens()
        screens.moves["s2mid|scroll 400"] = nil
        screens.supported[[0, 1, 3]] = ["AXScrollToVisible"]
        screens.moves["s2mid|AXScrollToVisible [0, 1, 3]"] = "s2start"
        let rig = try Rig(episodes: [], ax: screens, web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("S2E1"))])
        #expect(out == "Playing Harbour Lights S02E01, sir.")
        #expect(Array(rig.ax.actions.suffix(3)) == ["AXScrollToVisible [0, 1, 3]", "activate", "click [0, 1, 3]"])
        #expect(rig.logs.contains("tv: clicked cell at (140,540) (no AX actions)"))
    }

    @Test func neverClicksOutsideTheWindow() async throws {
        var screens = Self.realScreens()
        screens.moves["s2mid|scroll 400"] = nil
        let rig = try Rig(episodes: [], ax: screens, web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("S2E1"))])
        #expect(out == "I found Harbour Lights but couldn't start that episode, sir.")
        #expect(!rig.ax.actions.contains { $0.hasPrefix("click") })
        #expect(TVUIReader.clickPoint(Self.f(-220, 470, 230, 140), window: Self.window) == nil)
        #expect(TVUIReader.clickPoint(Self.f(25, 470, 230, 140), window: Self.window)! == (140, 540))
        #expect(TVUIReader.clickPoint(Self.f(25, 470, 230, 140), window: nil) == nil)
    }

    @Test func explicitEpisodeSwitchesSeasonWithThePicker() async throws {
        let rig = try Rig(episodes: [], ax: Self.realScreens(), web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("S1E2"))])
        #expect(out == "Playing Harbour Lights S01E02, sir.")
        #expect(rig.ax.actions == ["activate", "AXPress [0, 1, 0]", "AXPress [0, 1, 0, 0, 0]", "scroll 400", "activate", "click [0, 1, 4]"])
        #expect(rig.logs.contains { $0.hasPrefix("tv: season picker (AXPopUpButton id=UIA.TV.Button.seasonPicker title=Season 2) actions [AXPress, AXShowMenu]") })
    }

    @Test func withoutABannerLatestIsTheLastEpisodeOfTheHighestSeason() async throws {
        let rig = try Rig(episodes: [], ax: Self.realScreens(banner: nil, start: "s1start"), web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights"))])
        #expect(out == "Playing the latest Harbour Lights, sir.")
        #expect(rig.ax.actions == ["activate", "AXPress [0, 1, 0]", "AXPress [0, 1, 0, 0, 1]", "scroll 400", "scroll 400",
                                   "scroll -400", "activate", "click [0, 1, 5]"])
    }

    @Test func cellsOfBothKindsAreNumberedByXForThisShowOnly() {
        // Out of document order, with the `.episode` kind and a cell of another parent.
        let page = Self.node("AXWindow", [], frame: Self.window, [
            Self.node("AXGroup", [0], id: Self.cellID(4, 3, playable: false), frame: Self.f(760, 470, 230, 140)),
            Self.node("AXGroup", [1], id: Self.cellID(4, 1), frame: Self.f(270, 470, 230, 140)),
            Self.node("AXGroup", [2], id: Self.cellID(9, 9, parent: "umc.cmc.other"), frame: Self.f(25, 470, 230, 140)),
            Self.node("AXGroup", [3], id: Self.cellID(4, 2), frame: Self.f(515, 470, 230, 140)),
            Self.node("AXGroup", [4], id: Self.trailerID, frame: Self.f(0, 650, 230, 140)),
        ])
        let cells = TVUIReader.showPage(in: page).cells
        #expect(cells.map(\.episodeID) == ["umc.cmc.s4e1", "umc.cmc.s4e2", "umc.cmc.s4e3"])
        #expect(cells.map(\.playable) == [true, true, false])
    }

    @Test func thePickersSeasonComesFromItsTitle() {
        let page = TVUIReader.showPage(in: Self.realPage(banner: nil, season: 4, cells: []))
        #expect(page.picker?.value == nil)
        #expect(page.season == 4)
    }

    static func watchedAll() -> [MediaItem] {
        [ep(1, 1, .watched), ep(1, 2, .watched), ep(2, 1, .watched), ep(2, 2, .watched), ep(2, 3, .watched)]
    }

    @Test func fullyWatchedLatestPlaysItAgain() async throws {
        let rig = try Rig(episodes: Self.watchedAll(), ax: Self.realScreens(), web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("latest"))])
        #expect(out == "You've seen this one, sir; playing it again.")
        #expect(rig.ax.actions.last == "click [0, 1, 5]")
        // The library had no unwatched episode, so nothing played through the library.
        #expect(!rig.scripts.contains { $0.contains("to play") })
    }

    @Test func fullyWatchedNextSaysCaughtUp() async throws {
        let rig = try Rig(episodes: Self.watchedAll(), ax: Self.realScreens(), web: Self.searchPage)
        defer { rig.remove() }
        let out = await rig.call(TVPlay(tv: rig.tv), [("show", .string("Harbour Lights")), ("episode", .string("next"))])
        #expect(out == "You're all caught up on Harbour Lights, sir. The newest is S02E03; say \"play the latest Harbour Lights\" to watch it again.")
        #expect(rig.ax.actions == ["activate"])
    }

    @Test func trailersAndTheBannerAreNeverEpisodes() {
        let page = TVUIReader.showPage(in: Self.realPage(banner: "S2, E3 · Fog Bank", season: 2, cells: [Cell(e: 1, x: 25), Cell(e: 2, x: 270)]))
        #expect(page.banner?.season == 2 && page.banner?.episode == 3)
        #expect(page.season == 2)
        #expect(page.cells.map(\.episodeID) == ["umc.cmc.s2e1", "umc.cmc.s2e2"])
        #expect(page.cells.allSatisfy { $0.path.prefix(2) == [0, 1] })
        #expect(page.rows.isEmpty)
        // The titles route skips trailer and bonus cells and the banner too.
        let titled = Self.node("AXWindow", [], [
            Self.node("AXGroup", [0], id: Self.trailerID, label: "Episode 1 · Trailer"),
            Self.node("AXGroup", [1], id: "UIA.TV.Cell.lockup.play.parentId=\"uts.col.BonusContent.x\".id=\"b\"", label: "Episode 2 · Extra"),
            Self.node("AXGroup", [2], id: "UIA.TV.Cell.canonicalBanner.none", [Self.node("AXTextArea", [2, 0], value: "S4, E10 · Finale")]),
        ])
        #expect(TVUIReader.episodes(in: titled).isEmpty)
    }

    @Test func watchAgainTitlesAreOnlyAFallback() {
        #expect(TVUITitles.table.play.contains("Watch Again"))
        // A page with a "Watch Again" button and episode cells: the cell route never uses it.
        let page = TVUIReader.showPage(in: Self.realPage(banner: "S2, E3", season: 2, cells: [Cell(e: 1, x: 25)]))
        #expect(!page.cells.isEmpty && page.rows.isEmpty)
    }

    // MARK: Probe

    @Test func probeReportsTheSearchFieldAndTheEpisodeList() throws {
        let screens = Self.englishScreens()
        let home = TVProbe.accessibilityReport(screens.screens["home"])
        #expect(home.contains("tv-app search field: exposed (subrole AXSearchField) at [0, 0]"))
        #expect(home.contains { $0.hasPrefix("tv-app episode list: none on this screen") })
        let show = TVProbe.accessibilityReport(screens.screens["show"])
        #expect(show.contains("tv-app episode list: 3 rows (S02E01, S02E02, S02E03), 2 with watch marks, 3 with their own Play button"))
        #expect(show.contains("tv-app play button: exposed at [1, 1, 2]"))
        #expect(TVProbe.accessibilityReport(nil) == ["tv-app window: none (no window to read)"])
        let real = TVProbe.accessibilityReport(Self.realPage(banner: "S4, E10 · Being Alive", season: 4,
                                                             cells: [Cell(e: 7, x: -220), Cell(e: 8, x: 25), Cell(e: 9, x: 270), Cell(e: 10, x: 515)]))
        #expect(real.contains("tv-app banner: names S4E10"))
        #expect(real.contains("tv-app season picker: exposed, showing season 4"))
        #expect(real.contains("tv-app episode cells: 4 exposed (by identifier)"))
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
