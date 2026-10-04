import Foundation
import JarvisCore
import Synchronization

/// TV tools: "play the latest episode of <show>" by two routes. The library route reads the TV
/// app library and its watch state (the catalogue when Media Library is on, else the TV app's
/// own library on request) and plays through `MediaLibrary.play`. The search route, for a show
/// the library lacks or is behind on, drives the TV app through Accessibility: it lands on the
/// show page (by its tv.apple.com link, else by typing into the TV app's search), picks the
/// episode, switches season and scrolls as needed, and presses that episode's cell. It touches
/// only the TV app.
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
    public init(library: MediaLibrary, ax: any TVAccessibility, web: any WebFetching = LiveWebFetch(),
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
        return await searchAndPlay(show: show, want: want, library: eps)
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
        guard let page = await openShow(show) else { return Reply(text: Self.notFoundLine, readUI: true) }
        if page.banner != nil || page.picker != nil || !page.cells.isEmpty {
            var lines = ["Not in your library. The TV app has a show page for \(show)."]
            if let b = page.banner { lines.append("Its banner names \(Self.code(b.season, b.episode)) (the latest or up next).") }
            if let s = page.season { lines.append("The season picker shows season \(s).") }
            lines.append("\(page.cells.count) episode\(page.cells.count == 1 ? "" : "s") showing in the Episodes row.")
            return Reply(text: lines.joined(separator: "\n"), readUI: true)
        }
        let rows = page.rows
        guard !rows.isEmpty else { return Reply(text: Self.notFoundLine, readUI: true) }
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

    func searchAndPlay(show: String, want: TVEpisodeWant, library eps: [MediaItem] = []) async -> Reply {
        guard ax.isTrusted() else { return Reply(text: accessReply(), readUI: false) }
        guard await ax.activateTV() else { return Reply(text: "I couldn't open the TV app, sir.", readUI: false) }
        guard let page = await openShow(show) else { return Reply(text: Self.notFoundLine, readUI: true) }
        if page.banner != nil || page.picker != nil || !page.cells.isEmpty {
            return await playCell(show: show, want: want, page: page, library: eps)
        }
        return await playRow(show: show, want: want, rows: page.rows)
    }

    static func seenLine() -> String { "You've seen this one, sir; playing it again." }

    static func caughtUpLine(_ show: String, newest: String) -> String {
        "You're all caught up on \(show), sir. The newest is \(newest); say \"play the latest \(show)\" to watch it again."
    }

    static func code(_ season: Int?, _ episode: Int) -> String {
        season.map { String(format: "S%02dE%02d", $0, episode) } ?? String(format: "E%02d", episode)
    }

    /// The cell route (the TV app's identifiers): pick the episode, switch the season with the
    /// picker when needed, scroll the Episodes row until the cell is exposed, and press that
    /// cell. Never the banner, and never a Play button.
    func playCell(show: String, want: TVEpisodeWant, page: TVShowPage, library eps: [MediaItem]) async -> Reply {
        // The target: the asked code; for latest (and next, which the TV app's banner answers
        // as up next) the banner's episode; else the last episode of the highest season.
        var season: Int?
        var episode: Int?
        switch want {
        case .code(let s, let e): (season, episode) = (s, e)
        case .latest, .next:
            if let b = page.banner { (season, episode) = (b.season, b.episode) }
        }
        let watchedInLibrary = { (s: Int?, e: Int) in eps.contains { $0.season == s && $0.episode == e && $0.watch == .watched } }
        let allWatched = !eps.isEmpty && eps.allSatisfy { $0.watch == .watched }
        if want == .next, allWatched, let e = episode, watchedInLibrary(season, e) {
            return Reply(text: Self.caughtUpLine(show, newest: Self.code(season, e)), readUI: true)
        }
        // The season.
        var current = page
        if let s = season {
            if current.season != s, current.picker != nil {
                guard let switched = await chooseSeason(s, from: current) else {
                    return Reply(text: "I couldn't switch to season \(s) of \(show), sir.", readUI: true)
                }
                current = switched
            }
        } else if current.picker != nil {
            // No banner: the highest season.
            if let switched = await chooseSeason(nil, from: current) { current = switched }
            season = current.season
        }
        // The cell, scrolling the row until it is exposed.
        guard let (cell, number) = await findCell(episode: episode, season: season, in: current) else {
            return Reply(text: "I couldn't find that episode of \(show), sir.", readUI: true)
        }
        let played = Self.code(cell.season ?? season, number)
        if want == .next, allWatched, watchedInLibrary(cell.season ?? season, number) {
            return Reply(text: Self.caughtUpLine(show, newest: played), readUI: true)
        }
        guard await pressCell(cell.episodeID, what: "episode cell \(played)") else {
            return Reply(text: "I found \(show) but couldn't start that episode, sir.", readUI: true)
        }
        log("tv: played \(played) through its episode cell")
        if cell.watch == .watched || watchedInLibrary(cell.season ?? season, number) {
            return Reply(text: Self.seenLine(), readUI: true)
        }
        return Reply(text: Self.playingLine(show, want: want, code: played), readUI: true)
    }

    /// Opens the season picker and chooses season `season` (nil: the highest offered). Returns
    /// the page once it shows episode cells.
    func chooseSeason(_ season: Int?, from page: TVShowPage) async -> TVShowPage? {
        guard let picker = page.picker,
              await press(picker, what: "season picker", prefer: ["AXPress", "AXShowMenu", "AXShowDefaultUI"], window: page.window)
        else { return nil }
        guard let choices = await look({ r -> [(season: Int, node: TVAXNode)]? in
            let c = TVUIReader.seasonChoices(in: r)
            return c.isEmpty ? nil : c
        }) else { return nil }
        let pick = season.map { s in choices.first { $0.season == s } } ?? choices.max { $0.season < $1.season }
        guard let pick, await press(pick.node, what: "season \(pick.season)", window: page.window) else { return nil }
        return await look { r in
            let p = TVUIReader.showPage(in: r)
            guard !p.cells.isEmpty, p.season == nil || p.season == pick.season else { return nil }
            var shown = p
            shown.season = p.season ?? pick.season
            shown.cells = p.cells.map { var c = $0; c.season = c.season ?? pick.season; return c }
            return shown
        }
    }

    static let maxScrolls = 15
    /// One scroll-wheel step over the Episodes row, in points.
    static let scrollStep = 400

    /// Whether the row moved between two looks: other cells, or the same cells elsewhere.
    static func moved(_ a: TVShowPage, _ b: TVShowPage) -> Bool {
        a.cells.map { "\($0.episodeID)@\($0.frame?.x ?? -1)" } != b.cells.map { "\($0.episodeID)@\($0.frame?.x ?? -1)" }
    }

    /// A point over the Episodes row inside the TV window: the window's middle, at the cells'
    /// height.
    static func rowPoint(_ page: TVShowPage) -> (x: Double, y: Double)? {
        guard let w = page.window, let y = page.cells.compactMap(\.frame).first?.midY, w.contains(x: w.midX, y: y) else { return nil }
        return (w.midX, y)
    }

    /// Scrolls the Episodes row one step: its chevron when it is not dimmed, else a
    /// scroll-wheel event over the row. The page once the row moved; nil when it did not.
    func scrollRow(forward: Bool, page: TVShowPage) async -> TVShowPage? {
        var sent = false
        if let chevron = forward ? page.forward : page.back, chevron.enabled != false {
            sent = await press(chevron, what: forward ? "forward chevron" : "back chevron", window: page.window)
        }
        if !sent, let at = Self.rowPoint(page) {
            sent = await ax.scroll(horizontal: forward ? -Self.scrollStep : Self.scrollStep, x: at.x, y: at.y)
            log("tv: scrolled the episodes row \(forward ? "forward" : "back") at (\(Int(at.x)),\(Int(at.y)))")
        }
        guard sent else { return nil }
        return await look(attempts: 3) { r in
            let p = TVUIReader.showPage(in: r)
            return Self.moved(page, p) ? p : nil
        }
    }

    /// The episode cell for `episode` (nil: the last), and its number. A cell whose text names
    /// its episode is matched by that. Otherwise the row is scrolled back to its start and the
    /// cells (both kinds, this show's) are numbered by x order, collected across scrolls.
    func findCell(episode: Int?, season: Int?, in page: TVShowPage) async -> (TVEpisodeCell, Int)? {
        var current = page
        if let e = episode, let hit = current.cells.first(where: { $0.episode == e }) { return (hit, e) }
        for _ in 0..<Self.maxScrolls {
            guard let back = await scrollRow(forward: false, page: current) else { break }
            current = back
        }
        var order: [String] = []
        for step in 0...Self.maxScrolls {
            order += current.cells.map(\.episodeID).filter { !order.contains($0) }
            if let e = episode {
                if let hit = current.cells.first(where: { $0.episode == e }) { return (hit, e) }
                if order.count >= e, let hit = current.cells.first(where: { $0.episodeID == order[e - 1] }) { return (hit, e) }
            }
            guard step < Self.maxScrolls, let next = await scrollRow(forward: true, page: current) else { break }
            current = next
        }
        guard episode == nil, let last = order.last, let cell = current.cells.first(where: { $0.episodeID == last }) else { return nil }
        return (cell, cell.episode ?? order.count)
    }

    /// Presses an episode cell: an AX action when it lists one (live, the cells list none);
    /// otherwise, with the TV window in front, a click at the cell's centre, only once the row
    /// shows that centre inside the window (it scrolls first).
    func pressCell(_ id: String, what: String) async -> Bool {
        for _ in 0...Self.maxScrolls {
            guard let root = await ax.snapshot() else { return false }
            let page = TVUIReader.showPage(in: root)
            guard let cell = page.cells.first(where: { $0.episodeID == id }) else { return false }
            let actions = await ax.actions(cell.path)
            log("tv: \(what) (id=\(id)) actions [\(actions.joined(separator: ", "))]")
            if let action = ["AXPress", "AXShowDefaultUI"].first(where: actions.contains) {
                if actions.contains("AXScrollToVisible") { _ = await ax.perform("AXScrollToVisible", at: cell.path) }
                if await ax.perform(action, at: cell.path) {
                    log("tv: \(what) used \(action)")
                    return true
                }
                log("tv: \(what) \(action) failed")
            }
            if TVUIReader.clickPoint(cell.frame, window: page.window) != nil {
                _ = await ax.activateTV()
                // Read it again with the window in front, in case it moved.
                guard let fresh = await ax.snapshot().map({ TVUIReader.showPage(in: $0) }),
                      let c = fresh.cells.first(where: { $0.episodeID == id }),
                      let at = TVUIReader.clickPoint(c.frame, window: fresh.window) else { continue }
                let ok = await ax.click(x: at.x, y: at.y)
                let pressable = actions.contains("AXPress") || actions.contains("AXShowDefaultUI")
                log("tv: clicked cell at (\(Int(at.x)),\(Int(at.y))) (\(pressable ? "its AX actions failed" : "no AX actions"))")
                return ok
            }
            // Its centre is outside the window: bring it in first.
            if actions.contains("AXScrollToVisible"), await ax.perform("AXScrollToVisible", at: cell.path) {
                log("tv: \(what) is outside the window; AXScrollToVisible")
                continue
            }
            let forward = (cell.frame?.midX ?? 0) > (page.window?.midX ?? 0)
            log("tv: \(what) is outside the window; scrolling \(forward ? "forward" : "back")")
            guard await scrollRow(forward: forward, page: page) != nil else { return false }
        }
        return false
    }

    /// Presses a control (the season picker and its menu, a chevron, the search tab, a search
    /// result) with the first supported action of `prefer`, logging its role, identifier,
    /// title and actions. With no AX action that works, it clicks the centre, only when that is
    /// inside the TV window.
    func press(_ node: TVAXNode, what: String, prefer: [String] = ["AXPress", "AXShowDefaultUI"], window: TVAXFrame? = nil) async -> Bool {
        let actions = await ax.actions(node.path)
        var label = node.role
        if let id = node.identifier { label += " id=\(id)" }
        if let t = node.title ?? node.label { label += " title=\(TVUIReader.clean(t).prefix(60))" }
        log("tv: \(what) (\(label)) actions [\(actions.joined(separator: ", "))]")
        for action in prefer where actions.contains(action) {
            if await ax.perform(action, at: node.path) {
                log("tv: \(what) used \(action)")
                return true
            }
        }
        var frame = window
        if frame == nil { frame = await ax.snapshot()?.frame }
        guard let at = TVUIReader.clickPoint(node.frame, window: frame) else {
            log("tv: \(what) not pressed (no AX action, and not inside the window)")
            return false
        }
        _ = await ax.activateTV()
        let ok = await ax.click(x: at.x, y: at.y)
        log("tv: clicked \(what) at (\(Int(at.x)),\(Int(at.y))) (\(prefer.contains(where: actions.contains) ? "its AX actions failed" : "no AX actions"))")
        return ok
    }

    /// Presses by path with AX actions only (the titles route); AXPress when none are listed.
    func activate(_ path: [Int], what: String, prefer: [String] = ["AXPress", "AXShowDefaultUI"]) async -> Bool {
        let actions = await ax.actions(path)
        log("tv: \(what) actions [\(actions.joined(separator: ", "))]")
        for action in actions.isEmpty ? ["AXPress"] : prefer.filter(actions.contains) {
            if await ax.perform(action, at: path) {
                log("tv: \(what) used \(action)")
                return true
            }
        }
        log("tv: \(what) could not be pressed")
        return false
    }

    /// The titles route, for a page without the TV app's identifiers.
    func playRow(show: String, want: TVEpisodeWant, rows: [TVEpisodeRow]) async -> Reply {
        guard let row = TVUIReader.pick(rows, want: want) else {
            return Reply(text: rows.isEmpty ? Self.notFoundLine : "I couldn't find that episode of \(show), sir.", readUI: true)
        }
        var pressed = false
        if let p = row.playPath { pressed = await activate(p, what: "row play button") }
        if !pressed {
            _ = await activate(row.path, what: "episode row")
            if let button = await look({ TVUIReader.playButton(in: $0) }) {
                pressed = await press(button, what: "play button")
            }
        }
        guard pressed else { return Reply(text: "I found \(show) but couldn't press Play, sir.", readUI: true) }
        log("tv: played through the TV app's show page")
        return Reply(text: Self.playingLine(show, want: want, code: row.code), readUI: true)
    }

    /// Lands on the show page: by the tv.apple.com link when one is found, else through the TV
    /// app's search field.
    func openShow(_ show: String) async -> TVShowPage? {
        let ready = { (r: TVAXNode) -> TVShowPage? in
            let p = TVUIReader.showPage(in: r)
            return p.isShowPage ? p : nil
        }
        if let url = await showURL(show) {
            let out = await library.scripts.run("tell application \"TV\" to open location \"\(url)\"")
            if !out.lowercased().contains("error"), let page = await look(ready) { return page }
        }
        guard let root = await look({ $0 }) else { return nil }
        var field = TVUIReader.searchField(in: root)
        if field == nil, let tab = TVUIReader.searchTab(in: root) {
            _ = await press(tab, what: "search tab")
            field = await look { TVUIReader.searchField(in: $0) }
        }
        guard let field, await ax.setText(show, at: field.path) else { return nil }
        _ = await ax.perform("AXConfirm", at: field.path)
        guard let hit = await look({ TVUIReader.showResult(show, in: $0, excluding: field.path) }) else { return nil }
        _ = await press(hit, what: "search result")
        return await look(ready)
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
    func look<T>(attempts limit: Int? = nil, _ check: (TVAXNode) -> T?) async -> T? {
        let n = max(1, min(limit ?? attempts, attempts))
        for i in 0..<n {
            if let root = await ax.snapshot(), let found = check(root) { return found }
            if i < n - 1 { await pause() }
        }
        return nil
    }
}
