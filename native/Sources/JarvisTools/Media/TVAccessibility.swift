import ApplicationServices
import Foundation
import JarvisCore

/// TV tools: the TV app's window as Accessibility sees it, reduced to what the search route
/// needs. Built only from the TV app's own process; the value of a secure text field is never
/// read (it stays nil).
public struct TVAXNode: Sendable, Equatable {
    public var role: String
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var label: String?
    public var value: String?
    /// Child indexes from the window down to this element.
    public var path: [Int]
    public var children: [TVAXNode]

    public init(role: String, subrole: String? = nil, identifier: String? = nil, title: String? = nil,
                label: String? = nil, value: String? = nil, path: [Int] = [], children: [TVAXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        self.label = label
        self.value = TVAXNode.isSecure(role: role, subrole: subrole) ? nil : value
        self.path = path
        self.children = children
    }

    static func isSecure(role: String, subrole: String?) -> Bool {
        subrole == "AXSecureTextField" || role == "AXSecureTextField"
    }

    /// Title, description and value, cleaned. A secure field gives nothing.
    var ownText: String {
        guard !Self.isSecure(role: role, subrole: subrole) else { return "" }
        return [title, label, value].compactMap { $0 }.map(TVUIReader.clean).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// This element's text and its descendants', in reading order.
    var fullText: String {
        ([ownText] + children.map(\.fullText)).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Every element, depth first (document order).
    var all: [TVAXNode] { [self] + children.flatMap(\.all) }
}

/// The Accessibility seam. The live one touches only the TV app; tests use a fake.
public protocol TVAccessibility: Sendable {
    /// Whether macOS lets JARVIS use Accessibility.
    func isTrusted() -> Bool
    /// Shows macOS's own Accessibility prompt (once per request that finds it missing).
    func askForTrust()
    /// Opens the TV app, or brings it forward.
    func activateTV() async -> Bool
    /// The TV app's front window, or nil when it has none.
    func snapshot() async -> TVAXNode?
    /// Types `text` into the element at `path` (by setting its value).
    func setText(_ text: String, at path: [Int]) async -> Bool
    /// The AX actions the element at `path` supports (AXPress, AXShowDefaultUI, …).
    func actions(_ path: [Int]) async -> [String]
    /// Performs one AX action on the element at `path`.
    func perform(_ action: String, at path: [Int]) async -> Bool
}

/// The TV app's own AXIdentifiers, from its real window (macOS 27.2, en-GB, a show page).
/// Matched before any title; titles (`TVUITitles`) are the fallback.
public enum TVAXIDs {
    /// The show page's banner; its text area names the latest or up-next episode ("S4, E10 · …").
    public static let banner = "UIA.TV.Cell.canonicalBanner"
    /// A playable episode cell: `UIA.TV.Cell.episodeLockup.play.parentId="<show>".id="<episode>"`.
    public static let episodeCell = "UIA.TV.Cell.episodeLockup.play."
    public static let seasonPicker = "UIA.TV.Button.seasonPicker"
    public static let searchTab = "UIA.TV.Tabs.search"
    /// The Episodes row's forward chevron (the list shows a few cells at a time).
    public static let forwardChevron = "ChevronDirection(rawValue: 1)"
    /// Trailers and bonus content (`UIA.TV.Cell.lockup.play…uts.col.Trailers…`): never an episode.
    public static let excluded = ["uts.col.", "Trailers", "BonusContent"]

    static func isExcluded(_ id: String?) -> Bool {
        guard let id else { return false }
        return excluded.contains { id.contains($0) }
    }
}

/// The words the TV app's UI shows, per language. Matching prefers roles, subroles and
/// identifiers; these titles are the fallback, kept in this one table so a new language is one
/// line each.
public struct TVUITitles: Sendable, Equatable {
    public var search: [String]
    public var play: [String]
    public var season: [String]
    public var episode: [String]
    public var watched: [String]
    /// Substrings of AXIdentifier values, tried before any title.
    public var searchIdentifiers: [String]
    public var playIdentifiers: [String]

    public init(search: [String], play: [String], season: [String], episode: [String], watched: [String],
                searchIdentifiers: [String], playIdentifiers: [String]) {
        self.search = search
        self.play = play
        self.season = season
        self.episode = episode
        self.watched = watched
        self.searchIdentifiers = searchIdentifiers
        self.playIdentifiers = playIdentifiers
    }

    public static let table = TVUITitles(
        search: ["Search", "Rechercher", "Suchen", "Buscar", "Cerca", "Zoeken", "Pesquisar"],
        // The titles route only (no episode cells exposed); the cell route never presses these.
        play: ["Play", "Resume", "Lire", "Reprendre", "Wiedergeben", "Fortsetzen", "Reproducir", "Reanudar",
               "Riproduci", "Riprendi", "Afspelen", "Hervatten", "Reproduzir", "Retomar",
               "Watch Again", "Play from Beginning", "Restart", "Revoir", "Recommencer", "Erneut ansehen",
               "Von Anfang an", "Ver de nuevo", "Desde el principio", "Guarda di nuovo", "Dall'inizio"],
        season: ["Season", "Saison", "Staffel", "Temporada", "Stagione", "Seizoen"],
        episode: ["Episode", "Épisode", "Folge", "Episodio", "Aflevering", "Episódio"],
        watched: ["Watched", "Played", "Vu", "Gesehen", "Visto", "Bekeken", "Assistido"],
        searchIdentifiers: ["search"],
        playIdentifiers: ["play", "resume"])
}

/// One episode as the TV app's show page lists it. `title` is untrusted UI text.
public struct TVEpisodeRow: Sendable, Equatable {
    public var season: Int?
    public var episode: Int
    public var title: String
    public var watch: MediaItem.WatchState
    public var path: [Int]
    /// The row's own Play button, when it has one.
    public var playPath: [Int]?

    public init(season: Int?, episode: Int, title: String, watch: MediaItem.WatchState, path: [Int], playPath: [Int]? = nil) {
        self.season = season
        self.episode = episode
        self.title = title
        self.watch = watch
        self.path = path
        self.playPath = playPath
    }

    public var code: String {
        season.map { String(format: "S%02dE%02d", $0, episode) } ?? String(format: "E%02d", episode)
    }
}

/// Which episode was asked for.
public enum TVEpisodeWant: Sendable, Equatable {
    case latest, next
    case code(season: Int, episode: Int)

    /// "latest", "next", "S2E3", "s02e03", "S2 E3"; nil or "" is latest; anything else is nil.
    public init?(_ raw: String?) {
        let t = (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "", "latest", "newest", "new": self = .latest
        case "next": self = .next
        default:
            guard let m = TVUIReader.firstMatch(#"^s\s*(\d{1,3})\s*,?\s*e\s*(\d{1,4})$"#, in: t),
                  let s = Int(m[1]), let e = Int(m[2]) else { return nil }
            self = .code(season: s, episode: e)
        }
    }
}

/// Pure reading of a snapshot: the search field, a show result, the episode rows and the play
/// button. No side effects, so the tests run it on fake trees.
public enum TVUIReader {
    static let rowRoles: Set<String> = ["AXCell", "AXGroup", "AXButton", "AXRow", "AXLink"]
    static let resultRoles: Set<String> = ["AXCell", "AXGroup", "AXButton", "AXRow", "AXLink", "AXImage"]
    static let pressRoles: Set<String> = ["AXButton", "AXRadioButton", "AXCell", "AXRow", "AXLink", "AXMenuItem", "AXTab"]
    public static let maxText = 120

    /// UI text made safe to quote: no control characters or newlines, single spaces, bounded.
    public static func clean(_ s: String) -> String {
        let flat = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0) }.joined()
        let words = flat.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return words.count > maxText ? String(words.prefix(maxText)) : words
    }

    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    static func alternation(_ list: [String]) -> String {
        list.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    static func matchesAny(_ text: String?, _ list: [String]) -> Bool {
        guard let text else { return false }
        let w = words(text).joined(separator: " ")
        return list.contains { words($0).joined(separator: " ") == w }
    }

    static func idHas(_ node: TVAXNode, _ list: [String]) -> Bool {
        guard let id = node.identifier?.lowercased() else { return false }
        return list.contains { id.contains($0.lowercased()) }
    }

    // MARK: Search

    /// The search field: a search-field subrole first, then an identifier, then a text field
    /// titled "Search" in any listed language. Never a secure field.
    public static func searchField(in root: TVAXNode, titles: TVUITitles = .table) -> TVAXNode? {
        let fields = root.all.filter { ($0.role == "AXTextField" || $0.role == "AXComboBox") && !TVAXNode.isSecure(role: $0.role, subrole: $0.subrole) }
        return fields.first { $0.subrole == "AXSearchField" }
            ?? fields.first { idHas($0, titles.searchIdentifiers) }
            ?? fields.first { matchesAny($0.title, titles.search) || matchesAny($0.label, titles.search) }
    }

    /// The control that opens the search page (a sidebar row or tab), when no field is showing.
    public static func searchTab(in root: TVAXNode, titles: TVUITitles = .table) -> TVAXNode? {
        if let tab = root.all.first(where: { $0.identifier?.hasPrefix(TVAXIDs.searchTab) == true }) { return tab }
        let candidates = root.all.filter { pressRoles.contains($0.role) || $0.role == "AXStaticText" }
        return candidates.first { pressRoles.contains($0.role) && idHas($0, titles.searchIdentifiers) }
            ?? candidates.first { matchesAny($0.ownText, titles.search) || matchesAny($0.fullText, titles.search) }
    }

    /// The first search result whose text begins with the show's name. The search field and
    /// everything that contains it are skipped (they hold the typed name too).
    public static func showResult(_ show: String, in root: TVAXNode, excluding field: [Int]?) -> TVAXNode? {
        let key = words(show)
        guard !key.isEmpty else { return nil }
        return root.all.first { node in
            guard resultRoles.contains(node.role) else { return false }
            if let field, field.count >= node.path.count, Array(field.prefix(node.path.count)) == node.path { return false }
            let w = words(node.fullText)
            return w.count >= key.count && Array(w.prefix(key.count)) == key
        }
    }

    // MARK: Episodes

    /// (season?, episode) in a row's text, in any listed language.
    static func episodeNumber(_ text: String, titles: TVUITitles) -> (season: Int?, episode: Int)? {
        let s = alternation(titles.season), e = alternation(titles.episode)
        if let m = firstMatch(#"(?:^|[^\p{L}])S\s*(\d{1,3})\s*[,.:·-]?\s*E\s*(\d{1,4})(?![\p{L}\d])"#, in: text),
           let sn = Int(m[1]), let en = Int(m[2]) { return (sn, en) }
        if let m = firstMatch("(?:\(s))\\s*(\\d{1,3})\\W+(?:\(e))\\s*(\\d{1,4})", in: text),
           let sn = Int(m[1]), let en = Int(m[2]) { return (sn, en) }
        if let m = firstMatch("(?:^|[^\\p{L}])(?:\(e))\\s*(\\d{1,4})(?!\\d)", in: text), let en = Int(m[1]) { return (nil, en) }
        return nil
    }

    static func seasonHeader(_ text: String, titles: TVUITitles) -> Int? {
        firstMatch("(?:^|[^\\p{L}])(?:\(alternation(titles.season)))\\s*(\\d{1,3})(?!\\d)", in: text).flatMap { Int($0[1]) }
    }

    static func watchState(of row: TVAXNode, titles: TVUITitles) -> MediaItem.WatchState {
        let parts = row.all
        if parts.contains(where: { matchesAny($0.ownText, titles.watched) || matchesAny($0.label, titles.watched) }) { return .watched }
        for p in parts where p.role == "AXProgressIndicator" || p.role == "AXLevelIndicator" {
            guard let v = p.value.flatMap(Double.init) else { continue }
            let fraction = v > 1 ? v / 100 : v
            return fraction >= 0.95 ? .watched : (fraction > 0 ? .inProgress : .unwatched)
        }
        return .unknown
    }

    /// The episode rows of a show page, in document order. A row is the deepest cell, group,
    /// button, row or link whose text names an episode. A row without a season takes the last
    /// "Season N" shown above it (the season picker).
    public static func episodes(in root: TVAXNode, titles: TVUITitles = .table) -> [TVEpisodeRow] {
        var rows: [TVEpisodeRow] = []
        var currentSeason: Int?
        var claimed: [[Int]] = []
        func inside(_ path: [Int], _ parent: [Int]) -> Bool { path.count >= parent.count && Array(path.prefix(parent.count)) == parent }
        func visit(_ node: TVAXNode) {
            if claimed.contains(where: { inside(node.path, $0) }) { return }
            if TVAXIDs.isExcluded(node.identifier) || node.identifier?.hasPrefix(TVAXIDs.banner) == true { return }
            let isRow = rowRoles.contains(node.role) && episodeNumber(node.fullText, titles: titles) != nil
                && !node.children.flatMap(\.all).contains { rowRoles.contains($0.role) && episodeNumber($0.fullText, titles: titles) != nil }
            if isRow, let n = episodeNumber(node.fullText, titles: titles) {
                claimed.append(node.path)
                let play = node.all.dropFirst().first { $0.role == "AXButton" && (idHas($0, titles.playIdentifiers) || matchesAny($0.ownText, titles.play)) }
                rows.append(TVEpisodeRow(season: n.season ?? currentSeason, episode: n.episode, title: title(of: node, titles: titles),
                                         watch: watchState(of: node, titles: titles), path: node.path, playPath: play?.path))
                return
            }
            if node.children.isEmpty || node.role == "AXPopUpButton" || node.role == "AXMenuButton" || node.role == "AXRadioButton" {
                if episodeNumber(node.ownText, titles: titles) == nil, let s = seasonHeader(node.ownText, titles: titles) {
                    if node.role != "AXRadioButton" || node.value == "1" { currentSeason = s }
                }
            }
            node.children.forEach(visit)
        }
        visit(root)
        return rows
    }

    /// A row's title: its longest text that is not the episode label, a play word or a watch mark.
    static func title(of row: TVAXNode, titles: TVUITitles) -> String {
        let texts = row.all.map(\.ownText).filter { t in
            !t.isEmpty && episodeNumber(t, titles: titles) == nil && !matchesAny(t, titles.play) && !matchesAny(t, titles.watched)
                && Double(t) == nil
        }
        return clean(texts.max { $0.count < $1.count } ?? "")
    }

    /// Picks the episode: the asked one; else the next unwatched when the page shows watch
    /// marks (an episode in progress counts); else the newest (highest season, then episode).
    public static func pick(_ rows: [TVEpisodeRow], want: TVEpisodeWant) -> TVEpisodeRow? {
        switch want {
        case .code(let s, let e):
            return rows.first { $0.season == s && $0.episode == e } ?? rows.first { $0.season == nil && s == 1 && $0.episode == e }
        case .latest, .next:
            let ordered = rows.sorted { ($0.season ?? 0, $0.episode) < ($1.season ?? 0, $1.episode) }
            if ordered.contains(where: { $0.watch != .unknown }),
               let next = ordered.first(where: { $0.watch != .watched }) { return next }
            return ordered.last
        }
    }

    /// A Play button anywhere in the window (after a row was opened).
    public static func playButton(in root: TVAXNode, titles: TVUITitles = .table) -> TVAXNode? {
        let buttons = root.all.filter { $0.role == "AXButton" }
        return buttons.first { idHas($0, titles.playIdentifiers) } ?? buttons.first { matchesAny($0.ownText, titles.play) }
    }
}

// MARK: - The show page by identifier

/// One playable episode cell. The real cells carry no text, so the episode number is the
/// cell's place in the Episodes row unless its text names one.
public struct TVEpisodeCell: Sendable, Equatable {
    public var episodeID: String
    public var season: Int?
    public var episode: Int?
    public var watch: MediaItem.WatchState
    public var path: [Int]
}

public struct TVShowPage: Sendable, Equatable {
    /// The banner's episode ("S4, E10").
    public var banner: (season: Int?, episode: Int)?
    public var picker: TVAXNode?
    /// The season the picker shows, when it says.
    public var season: Int?
    public var cells: [TVEpisodeCell]
    /// The titles route's rows, for a page without episode cells.
    public var rows: [TVEpisodeRow]

    public var isShowPage: Bool { banner != nil || picker != nil || !cells.isEmpty || !rows.isEmpty }

    public static func == (a: TVShowPage, b: TVShowPage) -> Bool {
        a.banner?.season == b.banner?.season && a.banner?.episode == b.banner?.episode && a.picker == b.picker
            && a.season == b.season && a.cells == b.cells && a.rows == b.rows
    }
}

extension TVUIReader {
    /// The show page as the TV app's identifiers describe it.
    public static func showPage(in root: TVAXNode, titles: TVUITitles = .table) -> TVShowPage {
        let nodes = root.all
        var banner: (season: Int?, episode: Int)?
        if let b = nodes.first(where: { $0.identifier?.hasPrefix(TVAXIDs.banner) == true }) {
            let texts = b.all.filter { $0.role == "AXTextArea" } + b.all
            for t in texts {
                if let n = episodeNumber(t.ownText, titles: titles) { banner = n; break }
            }
        }
        let picker = nodes.first { $0.identifier?.hasPrefix(TVAXIDs.seasonPicker) == true }
        let season = picker.flatMap { seasonHeader([$0.value, $0.title].compactMap { $0 }.joined(separator: " "), titles: titles) }
        let cells = nodes.filter { n in
            guard let id = n.identifier else { return false }
            return id.hasPrefix(TVAXIDs.episodeCell) && !TVAXIDs.isExcluded(id)
        }.map { n in
            let number = episodeNumber(n.fullText, titles: titles)
            return TVEpisodeCell(episodeID: episodeID(n.identifier ?? ""), season: number?.season ?? season, episode: number?.episode,
                                 watch: watchState(of: n, titles: titles), path: n.path)
        }
        return TVShowPage(banner: banner, picker: picker, season: season, cells: cells,
                          rows: cells.isEmpty ? episodes(in: root, titles: titles) : [])
    }

    /// The `id="…"` at the end of a cell's identifier (the whole identifier when there is none).
    static func episodeID(_ identifier: String) -> String {
        firstMatch(#"\.id="([^"]+)"$"#, in: identifier)?[1] ?? identifier
    }

    /// The seasons an open season menu offers, as (season, element). The picker itself is
    /// skipped.
    public static func seasonChoices(in root: TVAXNode, titles: TVUITitles = .table) -> [(season: Int, node: TVAXNode)] {
        root.all.compactMap { n in
            guard n.identifier?.hasPrefix(TVAXIDs.seasonPicker) != true,
                  ["AXMenuItem", "AXButton", "AXRadioButton", "AXCell", "AXRow", "AXStaticText"].contains(n.role),
                  let s = seasonHeader(n.ownText, titles: titles) else { return nil }
            return (s, n)
        }
    }

    /// The Episodes row's forward chevron.
    public static func forwardChevron(in root: TVAXNode) -> TVAXNode? {
        root.all.first { ($0.identifier ?? "").contains(TVAXIDs.forwardChevron) || ($0.label ?? "").contains(TVAXIDs.forwardChevron) }
    }
}

// MARK: - Live

/// The TV app's process: finding it and opening it. AppKit work, so the live one lives in
/// JarvisApp (`LiveTVAppProcess`) and is passed in.
public protocol TVAppProcess: Sendable {
    /// The running TV app's process id, or nil when it is not running.
    func pid() -> pid_t?
    /// Opens the TV app, or brings it forward.
    func activate() async -> Bool
}

/// AXUIElement on the TV app (bundle com.apple.TV) only. It walks the TV app's focused window,
/// never another app, and never reads a secure field's value.
public struct LiveTVAccessibility: TVAccessibility {
    public static let bundleID = "com.apple.TV"
    public static let appPath = "/System/Applications/TV.app"
    /// Bounds on the walk, so a long list cannot stall a turn.
    public static let maxDepth = 25
    public static let maxNodes = 4000

    let app: any TVAppProcess

    public init(app: any TVAppProcess) {
        self.app = app
    }

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    public func askForTrust() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public func activateTV() async -> Bool { await app.activate() }

    func window() -> AXUIElement? {
        guard let pid = app.pid() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success, let value {
            return (value as! AXUIElement)
        }
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let list = value as? [AXUIElement], let first = list.first { return first }
        return nil
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    public func snapshot() async -> TVAXNode? {
        guard let window = window() else { return nil }
        var budget = Self.maxNodes
        func walk(_ e: AXUIElement, _ path: [Int]) -> TVAXNode {
            budget -= 1
            let role = Self.string(e, kAXRoleAttribute) ?? ""
            let subrole = Self.string(e, kAXSubroleAttribute)
            let secure = TVAXNode.isSecure(role: role, subrole: subrole)
            var node = TVAXNode(role: role, subrole: subrole, identifier: Self.string(e, kAXIdentifierAttribute),
                                title: secure ? nil : Self.string(e, kAXTitleAttribute),
                                label: secure ? nil : Self.string(e, kAXDescriptionAttribute),
                                value: secure ? nil : Self.string(e, kAXValueAttribute), path: path)
            if path.count < Self.maxDepth, !secure {
                for (i, child) in Self.children(e).enumerated() where budget > 0 {
                    node.children.append(walk(child, path + [i]))
                }
            }
            return node
        }
        return walk(window, [])
    }

    func element(at path: [Int]) -> AXUIElement? {
        guard var e = window() else { return nil }
        for i in path {
            let kids = Self.children(e)
            guard i < kids.count else { return nil }
            e = kids[i]
        }
        return e
    }

    public func setText(_ text: String, at path: [Int]) async -> Bool {
        guard let e = element(at: path) else { return false }
        let role = Self.string(e, kAXRoleAttribute) ?? "", subrole = Self.string(e, kAXSubroleAttribute)
        guard !TVAXNode.isSecure(role: role, subrole: subrole) else { return false }
        _ = AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, text as CFString) == .success
    }

    public func actions(_ path: [Int]) async -> [String] {
        guard let e = element(at: path) else { return [] }
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }

    public func perform(_ action: String, at path: [Int]) async -> Bool {
        guard let e = element(at: path) else { return false }
        return AXUIElementPerformAction(e, action as CFString) == .success
    }
}
