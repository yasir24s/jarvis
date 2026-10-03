import CoreGraphics
import Foundation
import JarvisCore

/// `summarize_page`, Python's `_summarize_page` (jarvis.py 3584-3604) with `_active_tab_url`
/// (3558) and `_fetch_page_text` (3576): the front Safari or Chrome tab's page, read and then
/// summarised by the on-device model with Python's prompt. Natively the page is read by the W1
/// WebKit reader when the app has one (Python fetched raw HTML and stripped tags); without a
/// reader, Python's fetch and strip. Untrusted (TaintPolicy).
struct SummarizePage: ToolImpl {
    static let name = "summarize_page"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let limit = 6000
    static let userAgent = "Mozilla/5.0 (JARVIS)"
    static let failed = "I read the page, sir, but couldn't distil it."
    static let modelTimeout: Duration = .seconds(120)
    /// Python's `(?is)` and `(?s)` patterns, with the flags as options (PyRegex has no inline flags).
    private static let blocks = try! PyRegex(#"<(script|style|nav|header|footer|aside)[^>]*>.*?</\1>"#,
                                             ignoreCase: true, dotAll: true)
    private static let tags = try! PyRegex(#"<[^>]+>"#, dotAll: true)
    private static let spaces = try! PyRegex(#"\s+"#)

    let runner: any StdinCommandRunning
    let web: any WebFetching
    let online: @Sendable () async -> Bool
    let frontApp: @Sendable () async -> String
    /// W1's WebKit reader; nil reads the page as Python did.
    let reader: (any PageReading)?
    /// The on-device model; nil means the page cannot be summarised.
    let model: (any PersonaLLM)?
    var log: @Sendable (String) -> Void = { _ in }

    /// `_active_tab_url`: Safari, then Chrome (Chrome first when it is in front), only when
    /// running, and only an http(s) URL.
    func activeTabURL() async -> String {
        var order = ["Safari", "Google Chrome"]
        if Py.contains(await frontApp(), "Chrome") { order.reverse() }
        let scripts = AppleScriptRunner(runner: runner)
        for app in order {
            guard Py.eq(await scripts.run("if application \"\(app)\" is running then return \"yes\"\nreturn \"no\""), "yes")
            else { continue }
            let url = app == "Safari"
                ? await scripts.run("tell application \"Safari\" to return URL of current tab of front window")
                : await scripts.run("tell application \"Google Chrome\" to return URL of active tab of front window")
            if Py.startsWith(url, "http") { return url }
        }
        return ""
    }

    /// `_fetch_page_text` over the platform's GET: 400 000 bytes at most, the noisy blocks and
    /// every tag dropped, entities decoded, white space collapsed, the first 6000 code points.
    func fetchText(_ url: String) async throws -> String {
        let body = try await web.get(url, headers: [("User-Agent", Self.userAgent)], timeout: 10)
        // decode("utf-8", errors="replace"): Swift substitutes U+FFFD by the same maximal-subpart rule.
        var src = String(decoding: body.prefix(400_000), as: UTF8.self)
        src = Self.blocks.sub(src, literal: " ")
        let text = try PyHTML.unescape(Self.tags.sub(src, literal: " "))
        return Self.collapse(text)
    }

    static func collapse(_ text: String) -> String {
        Py.prefix(Py.strip(spaces.sub(text, literal: " ")), limit)
    }

    static func prompt(_ question: String, _ text: String) -> String {
        "You are JARVIS. Below is the text of the web page the user is reading. In two "
            + "or three short spoken sentences, " + question + ". No markdown or lists.\n\nPAGE:\n" + text
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        // `question or "…"` is concatenated to the prompt, so a truthy non-str fails only there.
        let questionValue = args["question"] ?? .string("")
        let question = questionValue.pyTruthy ? questionValue.stringValue : ""
        let url = await activeTabURL()
        if url.isEmpty { return .text("I can't see an open web page, sir — bring Safari or Chrome to the front.") }
        if !(await online()) { return .text("I'm offline, sir, so I can't fetch that page.") }
        let text: String
        do {
            if let reader {
                text = Self.collapse(try await reader.read(url).text)
            } else {
                text = try await fetchText(url)
            }
        } catch {
            log("page fetch failed: \(WebSearch.describe(error))")
            return .text("I couldn't fetch that page, sir.")
        }
        if text.isEmpty { return .text("That page appears to be empty, sir.") }
        guard let question else {
            throw PyError(description: "can only concatenate str (not \"\(PyArgs.typeName(questionValue))\") to str")
        }
        let ask = question.isEmpty ? "summarize the key points for me" : question
        guard let model,
              let answer = try? await model.complete(system: "", user: Self.prompt(ask, text), timeout: Self.modelTimeout)
        else { return .text(Self.failed) }
        let reply = Py.strip(answer)
        return .text(reply.isEmpty ? Self.failed : reply)
    }

    /// `_front_app` without AppKit: the owner of the frontmost normal window (window lists are
    /// front to back; owner names need no Screen Recording grant).
    static func liveFrontApp() -> String {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return "" }
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            return window[kCGWindowOwnerName as String] as? String ?? ""
        }
        return ""
    }
}

/// `find_song_by_lyrics`, Python's `_find_song_by_lyrics` (jarvis.py 4175-4191). Python asked the
/// local model alone. Natively, when online, the snippet is first looked up through the W1 web
/// search (DuckDuckGo's results page) and the song is read from a lyrics site's result title;
/// the on-device model, with Python's prompt, answers when that finds nothing or JARVIS is
/// offline. Untrusted (TaintPolicy): the titles come from the web.
struct FindSongByLyrics: ToolImpl {
    static let name = "find_song_by_lyrics"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let unknown = "I couldn't place that song, sir."
    static let modelTimeout: Duration = .seconds(120)
    static let results = 8
    private static let quotes = try! PyRegex(#"^["'\s]+|["'\s]+$"#)
    /// "Artist - Title Lyrics" (Genius, AZLyrics and most others), dash, en dash or em dash.
    private static let artistTitle = try! PyRegex(#"^(.+?)\s+[-–—]\s+(.+?)\s+lyrics\b"#, ignoreCase: true)
    /// "Title Lyrics by Artist" / "Title lyrics - Artist".
    private static let titleBy = try! PyRegex(#"^(.+?)\s+lyrics\s+(?:by|[-–—])\s+(.+)$"#, ignoreCase: true)

    let web: any WebFetching
    let online: @Sendable () async -> Bool
    /// The on-device model; nil leaves the web lookup alone.
    let model: (any PersonaLLM)?
    var log: @Sendable (String) -> Void = { _ in }

    static func prompt(_ snippet: String) -> String {
        "You identify songs from a short lyric snippet a user spoke or sang. "
            + "Reply with ONLY the song title and performing artist, formatted exactly as "
            + "Title by Artist, and nothing else. Never quote, repeat, or continue the lyrics. "
            + "If you genuinely don't recognise it, reply exactly: unknown.\n\n"
            + "Snippet: " + snippet
    }

    /// Python's post-processing of the model's answer: the first line, quotes and white space
    /// trimmed, at most 120 code points; nil for an empty or "unknown" answer.
    static func answer(_ raw: String) -> String? {
        let stripped = Py.strip(raw)
        let first = stripped.isEmpty ? "" : Py.strip(Py.splitlines(stripped).first ?? "")
        let ans = Py.prefix(quotes.sub(first, literal: ""), 120)
        if ans.isEmpty || ["unknown", "i don't know", "i do not know"].contains(where: { Py.eq(Py.lower(ans), $0) }) {
            return nil
        }
        return ans
    }

    /// "Title by Artist" from the first result title that names a song's lyrics page.
    static func song(fromTitles titles: [String]) -> String? {
        for raw in titles {
            let title = Py.strip(raw.components(separatedBy: " | ").first ?? raw)
            if let m = titleBy.match(title), let song = m.groups[1], let artist = m.groups[2] {
                return Py.prefix("\(Py.strip(song)) by \(Py.strip(artist))", 120)
            }
            if let m = artistTitle.match(title), let artist = m.groups[1], let song = m.groups[2] {
                return Py.prefix("\(Py.strip(song)) by \(Py.strip(artist))", 120)
            }
        }
        return nil
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let snippet = Py.strip(try PyArgs.stringOrEmpty(args, "lyrics", method: "strip"), " ,:'\".")
        if snippet.isEmpty { return .text("Say or sing a few of the words, sir.") }
        if await online() {
            do {
                let found = try await WebResults.search("\"\(snippet)\" lyrics", limit: Self.results, web: web)
                if let song = Self.song(fromTitles: found.map(\.title)) { return .text("That sounds like \(song), sir.") }
            } catch {
                log("lyrics search failed: \(WebSearch.describe(error))")
            }
        }
        guard let model,
              let raw = try? await model.complete(system: "", user: Self.prompt(snippet), timeout: Self.modelTimeout),
              let ans = Self.answer(raw) else { return .text(Self.unknown) }
        return .text("That sounds like \(ans), sir.")
    }
}
