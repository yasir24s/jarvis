import Foundation
import JarvisCore

/// A property-list value seen the way `plistlib` hands it to Python, so `_enrich_app_index`'s
/// truthiness, `.get`, iteration and `str()` can be reproduced exactly.
indirect enum PlistValue: Sendable, Equatable {
    case dict([String: PlistValue])
    case array([PlistValue])
    case string(String)
    case int(Int64)
    case real(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    /// Python None: plistlib's result for a document with no root object.
    case none

    /// `Contents/Info.plist` as `plistlib.load` reads it, or nil where it raises (Python's
    /// `except Exception: info = {}`). `_is_fmt_xml` picks the XML reader for `<?xml` or
    /// `<plist`, bare or after a UTF-8 or UTF-16 BOM; `bplist00` picks the binary one; anything
    /// else is "Invalid file". XML goes through the plistlib port (PlistXML), binary through
    /// CoreFoundation.
    static func load(_ path: String) -> PlistValue? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let head = Array(data.prefix(32))
        if head.starts(with: Array("bplist00".utf8)) {
            guard let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return nil }
            return from(value)
        }
        return isXML(head) ? PlistXML.parse(data) : nil
    }

    static func isXML(_ head: [UInt8]) -> Bool {
        let prefixes = ["<?xml", "<plist"]
        if prefixes.contains(where: { head.starts(with: Array($0.utf8)) }) { return true }
        let boms: [([UInt8], String.Encoding)] = [([0xEF, 0xBB, 0xBF], .utf8), ([0xFE, 0xFF], .utf16BigEndian),
                                                   ([0xFF, 0xFE], .utf16LittleEndian)]
        for (bom, encoding) in boms where head.starts(with: bom) {
            for prefix in prefixes {
                guard let encoded = prefix.data(using: encoding) else { continue }
                if head.starts(with: bom + Array(encoded)) { return true }
            }
        }
        return false
    }

    static func from(_ value: Any) -> PlistValue {
        switch value {
        case let s as String: return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return CFNumberIsFloatType(n) ? .real(n.doubleValue) : .int(n.int64Value)
        case let d as [String: Any]: return .dict(d.mapValues(from))
        case let a as [Any]: return .array(a.map(from))
        case let date as Date: return .date(date)
        case let data as Data: return .data(data)
        default: return .string(String(describing: value))
        }
    }

    /// Python truthiness.
    var truthy: Bool {
        switch self {
        case .dict(let d): !d.isEmpty
        case .array(let a): !a.isEmpty
        case .string(let s): !s.isEmpty
        case .int(let i): i != 0
        case .real(let x): x != 0
        case .bool(let b): b
        case .date: true
        case .data(let d): !d.isEmpty
        case .none: false
        }
    }

    /// `for x in value`: a list's items, a dict's keys, a str's code points, a bytes' ints.
    /// Nil where Python raises TypeError (a number, a bool, a date).
    var iterated: [PlistValue]? {
        switch self {
        case .array(let a): a
        case .dict(let d): d.keys.map { .string($0) }
        case .string(let s): s.unicodeScalars.map { .string(String($0)) }
        case .data(let d): d.map { .int(Int64($0)) }
        case .int, .real, .bool, .date, .none: nil
        }
    }

    /// `str(value)`.
    var pyStr: String {
        switch self {
        case .string(let s): return s
        case .date(let date):
            // str(datetime): "YYYY-MM-DD HH:MM:SS[.ffffff]".
            let c = Self.utcFields(date)
            let base = String(format: "%04d-%02d-%02d %02d:%02d:%02d", c.0, c.1, c.2, c.3, c.4, c.5)
            return c.6 == 0 ? base : base + String(format: ".%06d", c.6)
        default: return pyRepr
        }
    }

    /// (year, month, day, hour, minute, second, microsecond) of a naive UTC datetime.
    static func utcFields(_ date: Date) -> (Int, Int, Int, Int, Int, Int, Int) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let micro = Int(((date.timeIntervalSince1970 - date.timeIntervalSince1970.rounded(.down)) * 1_000_000).rounded())
        return (c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micro)
    }

    /// `repr(value)`, as `str()` of a container prints its items.
    var pyRepr: String {
        switch self {
        case .string(let s): return PyRepr.string(s)
        case .int(let i): return String(i)
        case .real(let x): return PyFloat.repr(x)
        case .bool(let b): return b ? "True" : "False"
        case .data(let d): return PyRepr.bytes(d)
        case .array(let a): return "[" + a.map(\.pyRepr).joined(separator: ", ") + "]"
        case .dict(let d):
            return "{" + d.map { PyRepr.string($0.key) + ": " + $0.value.pyRepr }.joined(separator: ", ") + "}"
        case .date(let date):
            // repr(datetime): datetime.datetime(Y, M, D, h, m[, s[, us]]).
            let c = Self.utcFields(date)
            var fields = [c.0, c.1, c.2, c.3, c.4]
            if c.5 != 0 || c.6 != 0 { fields.append(c.5) }
            if c.6 != 0 { fields.append(c.6) }
            return "datetime.datetime(" + fields.map(String.init).joined(separator: ", ") + ")"
        case .none: return "None"
        }
    }
}

/// One `.app` from the index: `APP_INDEX[low] = name`, `APP_PATHS[low] = path`.
struct AppEntry: Sendable, Equatable {
    let low: String
    let name: String
    let path: String
}

/// What `find_apps` reads: the index in mdfind order and, once enrichment succeeded, each
/// app's kinds (`APP_META`). Empty `meta` means Python's `APP_META == {}`.
struct AppCatalog: Sendable, Equatable {
    var entries: [AppEntry] = []
    var meta: [String: [String]] = [:]
}

/// The pure half of jarvis.py's app intelligence (1666-1830, 1979-1996): the kind tables,
/// `_name_kinds`, `_enrich_app_index`, `_kind_word`, `_app_kinds`, `_apps_of_kind` and
/// `_find_apps`. Golden: m5_apps.
enum AppKinds {
    static let categoryKinds: [String: Set<String>] = [
        "web-browser": ["browser"], "developer-tools": ["developer"],
        "music": ["music"], "video": ["video"], "photography": ["photo"],
        "social-networking": ["chat"], "productivity": ["productivity"],
        "utilities": ["utility"], "graphics-design": ["design"],
        "entertainment": ["entertainment"], "education": ["education"],
        "finance": ["finance"], "news": ["news"], "reference": ["reference"],
        "medical": ["medical"], "business": ["business"], "travel": ["travel"],
        "weather": ["weather"], "lifestyle": ["lifestyle"],
    ]

    static let nameKinds: [(kind: String, needles: [String])] = [
        ("browser", ["safari", "chrome", "firefox", "edge", "brave", "opera", "vivaldi",
                     "orion", "arc", "atlas", "duckduckgo", "tor browser"]),
        ("email", ["mail", "outlook", "thunderbird", "spark", "airmail", "canary"]),
        ("music", ["music", "spotify", "tidal", "deezer", "muzify"]),
        ("video", ["vlc", "iina", "quicktime", "netflix", "iplayer", "plex", "infuse"]),
        ("terminal", ["terminal", "iterm", "warp", "kitty", "alacritty", "hyper"]),
        ("editor", ["visual studio code", "xcode", "sublime", "textmate", "bbedit",
                    "nova", "aquamacs", "emacs", "neovim", "cursor"]),
        ("notes", ["notes", "obsidian", "notion", "bear", "onenote", "evernote"]),
        ("chat", ["messages", "whatsapp", "telegram", "signal", "discord", "slack",
                  "teams", "zoom", "facetime"]),
        ("office", ["word", "excel", "powerpoint", "pages", "numbers", "keynote"]),
        ("ai", ["chatgpt", "claude", "ollama", "copilot", "gemini", "perplexity"]),
    ]

    static let synonyms: [String: String] = [
        "browser": "browser", "browsers": "browser", "web browser": "browser",
        "web browsers": "browser", "internet browser": "browser",
        "email": "email", "emails": "email", "mail": "email", "mail app": "email",
        "email app": "email", "email client": "email", "mail client": "email",
        "music": "music", "music app": "music", "music player": "music",
        "video": "video", "video player": "video", "media player": "video",
        "terminal": "terminal", "editor": "editor", "text editor": "editor",
        "code editor": "editor", "notes app": "notes", "note taking app": "notes",
        "chat app": "chat", "messaging app": "chat", "game": "game", "games": "game",
        "photo editor": "photo", "photos app": "photo", "office": "office",
        "word processor": "office", "ai app": "ai", "ai apps": "ai",
    ]

    /// `_ALL_KINDS`.
    static let allKinds: Set<String> = Set(nameKinds.map(\.kind))
        .union(categoryKinds.values.flatMap { $0 }).union(["game"])

    /// `_name_kinds(low)`: a needle matches between `\b`s (Python Unicode `\w`). Every needle
    /// starts and ends with a word character, so `\b` means "no word character beside it".
    static func nameKinds(_ low: String) -> Set<String> {
        let hay = Array(low.unicodeScalars)
        var kinds = Set<String>()
        for (kind, needles) in nameKinds where needles.contains(where: { matchesWord(hay, Array($0.unicodeScalars)) }) {
            kinds.insert(kind)
        }
        return kinds
    }

    static func matchesWord(_ hay: [Unicode.Scalar], _ needle: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        for start in 0...(hay.count - needle.count) where hay[start..<start + needle.count].elementsEqual(needle) {
            let end = start + needle.count
            if (start == 0 || !Py.isWord(hay[start - 1])) && (end == hay.count || !Py.isWord(hay[end])) {
                return true
            }
        }
        return false
    }

    /// `_kind_word(s)`: lowercased, stripped, one leading `my|the|a|an` + whitespace removed.
    static func kindWord(_ s: String?) -> String? {
        let text = Py.strip(Py.lower(s ?? ""))
        return synonyms[dropArticle(text)]
    }

    /// `re.sub(r"^(?:my|the|a|an)\s+", "", s)`: alternation order matters only for a prefix of
    /// another, and none of these is followed by whitespace inside another.
    static func dropArticle(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        for article in ["my", "the", "a", "an"] {
            let a = Array(article.unicodeScalars)
            guard u.count > a.count, u.starts(with: a), Py.isSpace(u[a.count]) else { continue }
            var i = a.count
            while i < u.count, Py.isSpace(u[i]) { i += 1 }
            return String(String.UnicodeScalarView(u[i...]))
        }
        return s
    }

    /// `_enrich_app_index()` over `entries`, reading each `Contents/Info.plist` with `load`.
    /// Nil wherever Python's loop raises (a plist whose root is not a dict, a truthy
    /// non-iterable, or a non-dict URL/document type entry): the real enrichment thread dies
    /// there and `APP_META` stays empty, so it is all or nothing.
    static func enrich(_ entries: [AppEntry], load: (String) -> PlistValue?) -> [String: [String]]? {
        var meta: [String: [String]] = [:]
        for entry in entries {
            let info = (entry.path.isEmpty ? nil : load(entry.path + "/Contents/Info.plist")) ?? .dict([:])
            guard case .dict(let plist) = info else { return nil }
            func list(_ value: PlistValue?) -> [PlistValue]? {          // `value or []`, iterated
                guard let value, value.truthy else { return [] }
                return value.iterated
            }
            func table(_ value: PlistValue) -> [String: PlistValue]? {  // `(value or {})`, then .get
                guard value.truthy else { return [:] }
                if case .dict(let d) = value { return d }
                return nil
            }
            var schemes = Set<String>(), exts = Set<String>(), utis = Set<String>()
            guard let urlTypes = list(plist["CFBundleURLTypes"]) else { return nil }
            for urlType in urlTypes {
                guard let t = table(urlType), let values = list(t["CFBundleURLSchemes"]) else { return nil }
                schemes.formUnion(values.map { Py.lower($0.pyStr) })
            }
            guard let docTypes = list(plist["CFBundleDocumentTypes"]) else { return nil }
            for docType in docTypes {
                guard let t = table(docType), let e = list(t["CFBundleTypeExtensions"]),
                      let u = list(t["LSItemContentTypes"]) else { return nil }
                exts.formUnion(e.map { Py.lower($0.pyStr) })
                utis.formUnion(u.map { Py.lower($0.pyStr) })
            }
            let handlesHTML = !exts.isDisjoint(with: ["html", "htm", "webloc"])
                || utis.contains { Py.contains($0, "html") || Py.contains($0, "webarchive") }
            var kinds = nameKinds(entry.low)
            if schemes.isSuperset(of: ["http", "https"]) && handlesHTML && !Py.contains(entry.low, "download") {
                kinds.insert("browser")
            }
            if schemes.contains("mailto") { kinds.insert("email") }
            let category = (plist["LSApplicationCategoryType"] ?? .string("")).pyStr
                .replacingOccurrences(of: "public.app-category.", with: "", options: .literal)
            kinds.formUnion(categoryKinds[category] ?? [])
            if category.unicodeScalars.reversed().starts(with: "games".unicodeScalars.reversed()) {
                kinds.insert("game")
            }
            meta[entry.low] = pySorted(Array(kinds))
        }
        return meta
    }

    /// Python's `sorted()` for str: code point order.
    static func pySorted(_ values: [String]) -> [String] {
        values.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// `_app_kinds(low)`, sorted for a stable reply (Python joins a set in hash order).
    static func appKinds(_ low: String, _ catalog: AppCatalog) -> [String] {
        if !catalog.meta.isEmpty, let kinds = catalog.meta[low] { return kinds }
        return pySorted(Array(nameKinds(low)))
    }

    /// `_apps_of_kind(kind)`.
    static func apps(ofKind kind: String, _ catalog: AppCatalog) -> [String] {
        if !catalog.meta.isEmpty {
            let names = Dictionary(catalog.entries.map { ($0.low, $0.name) }, uniquingKeysWith: { a, _ in a })
            return pySorted(catalog.meta.compactMap { low, kinds in kinds.contains(kind) ? names[low] : nil })
        }
        return pySorted(catalog.entries.filter { nameKinds($0.low).contains(kind) }.map(\.name))
    }

    /// `_find_apps(query)`. `echo` is `str(query)` for the no-match reply (the query itself
    /// unless the caller passed a falsy non-str). `defaultBrowser` is asked only for a
    /// non-empty browser list.
    static func findApps(_ query: String, _ catalog: AppCatalog, echo: String? = nil,
                         defaultBrowser: () async -> String) async -> String {
        let q = Py.strip(Py.lower(query))
        if let kind = kindWord(q) ?? (allKinds.contains(q) ? q : nil) {
            let names = apps(ofKind: kind, catalog)
            if names.isEmpty { return "I don't see any \(kind) apps installed, sir." }
            let preferred = kind == "browser" ? await defaultBrowser() : ""
            let marked = names.map { $0 == preferred ? $0 + " — the default" : $0 }
            return "Installed \(kind) apps: " + marked.prefix(12).joined(separator: ", ") + "."
        }
        var hits: [String] = []
        for entry in catalog.entries {
            if Py.contains(entry.low, q) {
                let kinds = appKinds(entry.low, catalog).joined(separator: ", ")
                hits.append("\(entry.name) (\(kinds.isEmpty ? "app" : kinds))")
            }
            if hits.count >= 10 { break }
        }
        return hits.isEmpty ? "Nothing installed matches \(echo ?? query), sir."
            : "Matching apps: " + hits.joined(separator: "; ") + "."
    }

    /// `build_app_index`'s line rules over mdfind's stdout (already decoded): each line
    /// stripped, kept if it ends in ".app"; the first path per lowercased name wins.
    static func index(fromMdfind stdout: String) -> [AppEntry] {
        var seen = Set<String>()
        var entries: [AppEntry] = []
        for raw in Py.splitlines(stdout) {
            let line = Py.strip(raw)
            guard line.unicodeScalars.reversed().starts(with: ".app".unicodeScalars.reversed()) else { continue }
            let base = line.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? line
            let name = Py.prefix(base, Py.len(base) - 4)
            let low = Py.lower(name)
            if seen.insert(low).inserted { entries.append(AppEntry(low: low, name: name, path: line)) }
        }
        return entries
    }
}
