import Darwin
import Foundation
import JarvisCore

/// `_spotlight` (jarvis.py 2679-2718) and `_KIND_MDFIND` (2662-2677): the query string and the
/// reply are pure; mdfind runs through the bounded runner and `stat` reads mtimes for `recent`
/// (plan: M05-M06 §3.5 keeps `/usr/bin/mdfind` with Python's query, 15 s). Golden: m5_spotlight.
enum SpotlightQuery {
    static let kinds: [String: String] = [
        "pdf": "kMDItemContentType == 'com.adobe.pdf'",
        "image": "kMDItemContentTypeTree == 'public.image'",
        "photo": "kMDItemContentTypeTree == 'public.image'",
        "video": "kMDItemContentTypeTree == 'public.movie'",
        "movie": "kMDItemContentTypeTree == 'public.movie'",
        "audio": "kMDItemContentTypeTree == 'public.audio'",
        "music": "kMDItemContentTypeTree == 'public.audio'",
        "document": "kMDItemContentTypeTree == 'public.content'",
        "spreadsheet": "kMDItemContentTypeTree == 'public.spreadsheet'",
        "presentation": "kMDItemContentTypeTree == 'public.presentation'",
        "folder": "kMDItemContentType == 'public.folder'",
        "app": "kMDItemContentType == 'com.apple.application-bundle'",
        "archive": "kMDItemContentTypeTree == 'public.archive'",
        "code": "kMDItemContentTypeTree == 'public.source-code'",
    ]
    static let junk = ["/Library/", "/.Trash/", "/node_modules/", "/__pycache__/", "/.git/"]
    static let junkExtensions = [".log", ".pyc", ".cache", ".tmp", ".plist", ".db", ".db-wal"]
    static let limit = 12
    static let timeout = 15.0

    /// `if kind and kind in _KIND_MDFIND`: a falsy value is skipped, a str is looked up, other
    /// hashable values are simply absent, and a non-empty list or dict raises TypeError.
    static func kindClause(_ kind: JSONValue?) throws -> String? {
        guard let kind, kind.pyTruthy else { return nil }
        switch kind {
        case .string(let s): return kinds[s]
        case .array, .object:
            let type = PyArgs.typeName(kind)
            throw PyError(description: "cannot use '\(type)' as a dict key (unhashable type: '\(type)')")
        default: return nil
        }
    }

    /// The mdfind expression: the name-or-content clause (with `\` and `'` escaped), the kind
    /// clause and the this-week clause joined with " && ", or `q or "*"` with none.
    static func expression(query q: String, kindClause: String?, recent: Bool) -> String {
        var clauses: [String] = []
        if !q.isEmpty {
            let esc = q.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            clauses.append("(kMDItemDisplayName == '*\(esc)*'cd || kMDItemTextContent == '*\(esc)*'cd)")
        }
        if let kindClause { clauses.append(kindClause) }
        if recent { clauses.append("kMDItemFSContentChangeDate >= $time.this_week") }
        return clauses.isEmpty ? (q.isEmpty ? "*" : q) : clauses.joined(separator: " && ")
    }

    /// Python's argv (`mdfind` by name); the runner gets the absolute path.
    static func argv(_ expression: String, recent: Bool, home: String) -> [String] {
        ["mdfind"] + (recent ? ["-onlyin", home] : []) + [expression]
    }

    /// `str(TimeoutExpired)`: "Command '<repr of the argv list>' timed out after 15 seconds".
    static func timeoutText(_ argv: [String]) -> String {
        "Command '[" + argv.map(PyRepr.string).joined(separator: ", ") + "]' timed out after 15 seconds"
    }

    /// The junk filter for `recent`: none of the junk folders in the path, no dot-file name, no
    /// junk extension (case-insensitive).
    static func isJunk(_ path: String) -> Bool {
        if junk.contains(where: { Py.contains(path, $0) }) { return true }
        if Py.startsWith(basename(path), ".") { return true }
        let lowered = Array(Py.lower(path).unicodeScalars)
        return junkExtensions.contains { lowered.reversed().starts(with: Array($0.unicodeScalars).reversed()) }
    }

    /// `os.path.basename`: everything after the last "/".
    static func basename(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
    }

    /// `lines.sort(key=mtime, reverse=True)`: newest first, equal keys in their original order.
    static func newestFirst(_ lines: [String], mtime: (String) -> Double) -> [String] {
        let keyed = lines.enumerated().map { (offset: $0.offset, line: $0.element, key: mtime($0.element)) }
        return keyed.sorted { $0.key != $1.key ? $0.key > $1.key : $0.offset < $1.offset }.map(\.line)
    }

    /// The reply for the (filtered, sorted) lines.
    static func reply(_ lines: [String]) -> String {
        let shown = Array(lines.prefix(limit))
        guard !shown.isEmpty else { return "No matching files found, sir." }
        let names = shown.map(basename)
        let spoken = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? ", and \(names.count - 6) more" : "")
        return "Found \(shown.count): \(spoken).\n" + shown.joined(separator: "\n")
    }

    /// `os.path.getmtime(p) if os.path.exists(p) else 0`: `stat` (following links), with
    /// CPython's float `sec + nsec * 1e-9`.
    static func mtime(_ path: String) -> Double {
        var st = stat()
        guard stat(path, &st) == 0 else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }
}

/// The body shared by `search_files` (`_spotlight(query)`) and `find_files`
/// (`_spotlight(query, kind, bool(recent))`).
struct Spotlight: Sendable {
    /// A broad `recent` listing is sorted whole, so the runner keeps far more than the default
    /// 4 MiB; the reply itself is at most 12 paths.
    static let cap = 64 << 20
    let runner: any CommandRunning
    /// `os.path.expanduser("~")`.
    let home: String
    var mtime: @Sendable (String) -> Double = SpotlightQuery.mtime

    func search(query: String, kind: JSONValue?, recent: Bool) async throws -> String {
        let q = Py.strip(query)
        let expression = SpotlightQuery.expression(query: q, kindClause: try SpotlightQuery.kindClause(kind),
                                                   recent: recent)
        let user = Py.rstrip(home, "/")
        let argv = SpotlightQuery.argv(expression, recent: recent, home: user.isEmpty ? "/" : user)
        guard let output = await runner.run(["/usr/bin/mdfind"] + argv.dropFirst(), timeout: SpotlightQuery.timeout) else {
            return "Search error: [Errno 2] No such file or directory: 'mdfind'"
        }
        if output.timedOut { return "Search error: " + SpotlightQuery.timeoutText(argv) }
        var bytes = output.stdout
        if output.truncated, let lastBreak = bytes.lastIndex(of: 0x0A) {
            bytes = bytes.prefix(through: lastBreak)          // never decode a cut-off last line
        }
        guard let stdout = PyText.decode(bytes) else {
            return "Search error: " + (PyText.decodeError(bytes) ?? "'utf-8' codec can't decode")
        }
        var lines = Py.splitlines(stdout).filter { !Py.strip($0).isEmpty }
        if recent {
            lines = SpotlightQuery.newestFirst(lines.filter { !SpotlightQuery.isJunk($0) }, mtime: mtime)
        }
        return SpotlightQuery.reply(lines)
    }
}

/// `search_files` (plan: M05-M06 §2a, §3.5, A-FILE-1): `_spotlight(query)`.
struct SearchFiles: ToolImpl {
    static let name = "search_files"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let spotlight: Spotlight

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(try await spotlight.search(query: try PyArgs.stringOrEmpty(args, "query", method: "strip"),
                                         kind: nil, recent: false))
    }
}

/// `find_files` (A-FILE-1): `_spotlight(query, kind, bool(recent))`.
struct FindFiles: ToolImpl {
    static let name = "find_files"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let spotlight: Spotlight

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let query = try PyArgs.stringOrEmpty(args, "query", method: "strip")
        return .text(try await spotlight.search(query: query, kind: args["kind"], recent: args["recent"]?.pyTruthy ?? false))
    }
}
