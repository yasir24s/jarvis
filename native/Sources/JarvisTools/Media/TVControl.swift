import Foundation
import JarvisCore
import Synchronization

/// TV tools: "play the latest episode of <show>" by two routes. The library route reads the TV
/// app library and its watch state (the catalogue when Media Library is on, else the TV app's
/// own library on request) and plays through `MediaLibrary.play`. The search route, for a show
/// the library lacks or is behind on, drives the TV app through Accessibility: it lands on the
/// show page (by its tv.apple.com link, else by typing into the TV app's search), reads the
/// episode list, picks one and presses Play. It touches only the TV app.
public final class TVControl: Sendable {
    public static let accessLine = "I need Accessibility access to search the TV app, sir."
    public static let accessHowTo = " Open System Settings, then Privacy & Security, then Accessibility, and switch on JARVIS."
    public static let notFoundLine = "I couldn't find that show, sir."
    public static let onlyMacLine = "I can only play on this Mac for now, sir."
    public static let switchOffLine = "The TV switch in Learning Sources is off, sir. Turn it on and I can tell you what's on."

    /// What a call said, and whether it read the TV app's UI (the tool then taints the turn).
    public struct Reply: Sendable, Equatable {
        public let text: String
        public let readUI: Bool
    }

    let library: MediaLibrary
    let ax: any TVAccessibility
    let web: any WebFetching
    let storefront: String
    let tvSwitch: @Sendable () -> Bool
    let pause: @Sendable () async -> Void
    let attempts: Int
    let log: @Sendable (String) -> Void
    private let toldHowTo = Mutex(false)

    /// `pause` runs between looks at the TV app while it loads (half a second live);
    /// `attempts` bounds the looks.
    public init(library: MediaLibrary, ax: any TVAccessibility = LiveTVAccessibility(), web: any WebFetching = LiveWebFetch(),
                storefront: String = Locale.current.region?.identifier.lowercased() ?? "us",
                tvSwitch: @escaping @Sendable () -> Bool,
                pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(for: .milliseconds(500)) },
                attempts: Int = 12,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.library = library
        self.ax = ax
        self.web = web
        self.storefront = storefront
        self.tvSwitch = tvSwitch
        self.pause = pause
        self.attempts = max(1, attempts)
        self.log = log
    }

    // MARK: - Library route

    /// A show's episodes from the library: the catalogue while it is on, else (or when it has
    /// none) the TV app's own library, read for this request and not kept.
    func libraryEpisodes(_ show: String) async -> [MediaItem] {
        if library.switches.library() || library.switches.music() {
            await library.refresh()
            let eps = library.load().episodes(of: show)
            if !eps.isEmpty { return eps }
        }
        guard let items = await library.tv.read() else { return [] }
        var c = MediaCatalogue()
        c.items = items
        return c.episodes(of: show)
    }

    /// The library's pick, or nil when the library cannot answer (the show is missing, the asked
    /// episode is missing, or every episode is watched: the library is behind).
    public static func libraryPick(_ episodes: [MediaItem], want: TVEpisodeWant) -> MediaItem? {
        switch want {
        case .code(let s, let e):
            return episodes.first { $0.season == s && $0.episode == e }
        case .latest, .next:
            guard !episodes.isEmpty else { return nil }
            if episodes.contains(where: { $0.watch != .unknown }) {
                return episodes.first { $0.watch == .unwatched || $0.watch == .inProgress }
            }
            return episodes.max { ($0.released ?? 0, $0.season ?? 0, $0.episode ?? 0) < ($1.released ?? 0, $1.season ?? 0, $1.episode ?? 0) }
        }
    }

    static func playingLine(_ show: String, want: TVEpisodeWant, code: String) -> String {
        switch want {
        case .latest: "Playing the latest \(show), sir."
        case .next: "Playing the next episode of \(show), sir."
        case .code: "Playing \(show)\(code.isEmpty ? "" : " \(code)"), sir."
        }
    }

    // MARK: - Tools

    public func play(show: String, want: TVEpisodeWant) async -> Reply {
        let eps = await libraryEpisodes(show)
        if let ep = Self.libraryPick(eps, want: want) {
            let name = ep.show ?? show
            guard await library.play(ep) != nil else { return Reply(text: "I couldn't start \(name), sir.", readUI: false) }
            log("tv: played from the library")
            return Reply(text: Self.playingLine(name, want: want, code: ep.episodeCode), readUI: false)
        }
        log(eps.isEmpty ? "tv: not in the library; searching the TV app" : "tv: the library is behind; searching the TV app")
        return await searchAndPlay(show: show, want: want)
    }

    public func find(show: String) async -> Reply {
        let eps = await libraryEpisodes(show)
        if !eps.isEmpty {
            let name = eps.first?.show ?? show
            let left = eps.filter { $0.watch != .watched }
            var lines = ["In your library: \(eps.count) episode\(eps.count == 1 ? "" : "s") of \(name), \(left.count) not watched."]
            if let next = Self.libraryPick(eps, want: .latest) { lines.append("Next: \(next.line)") }
            lines += eps.prefix(20).map(\.line)
            return Reply(text: lines.joined(separator: "\n"), readUI: false)
        }
        guard ax.isTrusted() else { return Reply(text: accessReply(), readUI: false) }
        guard await ax.activateTV() else { return Reply(text: "I couldn't open the TV app, sir.", readUI: false) }
        guard let rows = await openShow(show), !rows.isEmpty else { return Reply(text: Self.notFoundLine, readUI: true) }
        let shown = rows.prefix(30).map { r in
            "\(r.code) \"\(r.title)\"" + (r.watch == .unknown ? "" : ", \(r.watch == .inProgress ? "in progress" : r.watch.rawValue)")
        }
        return Reply(text: (["Not in your library. The TV app lists \(rows.count) episode\(rows.count == 1 ? "" : "s") of \(show) on its show page:"]
                            + shown).joined(separator: "\n"), readUI: true)
    }

    public func nowPlaying() async -> Reply {
        guard tvSwitch() else { return Reply(text: Self.switchOffLine, readUI: false) }
        return Reply(text: Self.nowPlayingLine(await library.scripts.run(TVProbe.nowPlayingScript)), readUI: false)
    }

    /// `TVProbe.nowPlayingScript`'s answer, spoken.
    static func nowPlayingLine(_ out: String) -> String {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if t == "not running" { return "The TV app isn't open, sir." }
        if t == "stopped" { return "Nothing is playing in the TV app, sir." }
        let f = t.components(separatedBy: "|")
        guard f.count >= 5, !t.lowercased().contains("error") else { return "I couldn't ask the TV app what's playing, sir." }
        let state = f[0] == "paused" ? "Paused" : "Playing"
        let title = TVUIReader.clean(f[1]), show = TVUIReader.clean(f[2])
        let s = Int(f[3]) ?? 0, e = Int(f[4]) ?? 0
        let code = s > 0 && e > 0 ? String(format: " S%02dE%02d", s, e) : ""
        return show.isEmpty ? "\(state) in the TV app: \"\(title)\", sir." : "\(state) in the TV app: \(show)\(code), \"\(title)\", sir."
    }

    // MARK: - Search route

    func accessReply() -> String {
        let first = toldHowTo.withLock { told in
            defer { told = true }
            return !told
        }
        if first { ax.askForTrust() }
        return Self.accessLine + (first ? Self.accessHowTo : "")
    }

    func searchAndPlay(show: String, want: TVEpisodeWant) async -> Reply {
        guard ax.isTrusted() else { return Reply(text: accessReply(), readUI: false) }
        guard await ax.activateTV() else { return Reply(text: "I couldn't open the TV app, sir.", readUI: false) }
        guard let rows = await openShow(show), !rows.isEmpty else { return Reply(text: Self.notFoundLine, readUI: true) }
        guard let row = TVUIReader.pick(rows, want: want) else {
            return Reply(text: "I couldn't find that episode of \(show), sir.", readUI: true)
        }
        var pressed = false
        if let p = row.playPath { pressed = await ax.press(p) }
        if !pressed {
            _ = await ax.press(row.path)
            if let button = await look({ TVUIReader.playButton(in: $0) }) { pressed = await ax.press(button.path) }
        }
        guard pressed else { return Reply(text: "I found \(show) but couldn't press Play, sir.", readUI: true) }
        log("tv: played through the TV app's show page")
        return Reply(text: Self.playingLine(show, want: want, code: row.code), readUI: true)
    }

    /// Lands on the show page and returns its episode rows: by the tv.apple.com link when one
    /// is found, else through the TV app's search field.
    func openShow(_ show: String) async -> [TVEpisodeRow]? {
        if let url = await showURL(show) {
            let out = await library.scripts.run("tell application \"TV\" to open location \"\(url)\"")
            if !out.lowercased().contains("error"), let rows = await look({ r in
                let rows = TVUIReader.episodes(in: r)
                return rows.isEmpty ? nil : rows
            }) { return rows }
        }
        guard let root = await look({ $0 }) else { return nil }
        var field = TVUIReader.searchField(in: root)
        if field == nil, let tab = TVUIReader.searchTab(in: root) {
            _ = await ax.press(tab.path)
            field = await look { TVUIReader.searchField(in: $0) }
        }
        guard let field, await ax.setText(show, at: field.path) else { return nil }
        _ = await ax.confirm(field.path)
        guard let hit = await look({ TVUIReader.showResult(show, in: $0, excluding: field.path) }) else { return nil }
        _ = await ax.press(hit.path)
        return await look { r in
            let rows = TVUIReader.episodes(in: r)
            return rows.isEmpty ? nil : rows
        }
    }

    /// The show's tv.apple.com page from the public search page, or nil (offline, or no link
    /// whose name is the show's). Only links of the form TVProbe accepts come back.
    func showURL(_ show: String) async -> String? {
        guard let url = TVProbe.searchURL(show, storefront: storefront),
              let data = try? await web.get(url.absoluteString, headers: [("User-Agent", "Mozilla/5.0 (Macintosh)")], timeout: 10)
        else { return nil }
        return TVProbe.showURL(for: show, inSearchPage: String(decoding: data, as: UTF8.self))
    }

    /// Looks at the TV app's window until `check` finds something, `attempts` times at most.
    func look<T>(_ check: (TVAXNode) -> T?) async -> T? {
        for i in 0..<attempts {
            if let root = await ax.snapshot(), let found = check(root) { return found }
            if i < attempts - 1 { await pause() }
        }
        return nil
    }
}
