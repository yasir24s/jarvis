import Foundation
import JarvisCore

/// The AppleScript helpers Python's data tools share (jarvis.py `_as_escape` 1261,
/// `_applescript_errored` 2998, `_ensure_app_running` 3006).
enum AppleScriptText {
    /// `_as_escape`: backslashes, then double quotes, for a double-quoted AppleScript literal.
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// `_applescript_errored`: osascript printed an error, not a result.
    static func errored(_ out: String) -> Bool {
        let low = Py.lower(out)
        return Py.contains(out, "-600") || Py.contains(low, "execution error") || Py.contains(low, "isn't running")
            || Py.contains(low, "not running") || Py.startsWith(low, "applescript error")
    }

    /// `"error" in out.lower()`, the test the outbound tools use.
    static func mentionsError(_ out: String) -> Bool { Py.contains(Py.lower(out), "error") }

    /// `_ensure_app_running(app)`: launch it without bringing it forward, then wait 2 s.
    static func ensureRunning(_ app: String, scripts: AppleScriptRunner,
                              pause: @Sendable (Double) async -> Void) async {
        _ = await scripts.run("tell application \"\(escape(app))\" to launch")
        await pause(2.0)
    }

    /// `s.split("|")` with each part stripped, by code points (a combining mark after the bar
    /// must not join it, as a Swift Character split would).
    static func fields(_ line: String) -> [String] {
        line.components(separatedBy: "|").map { Py.strip($0) }
    }
}

/// `music_now_playing`, Python's `_now_playing` (jarvis.py 1474-1498): Music only; Spotify is
/// left out of the script on purpose (its terminology fails to compile when it is absent).
struct MusicNowPlaying: ToolImpl {
    static let name = "music_now_playing"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let script = "if application \"Music\" is running then\n"
        + "  tell application \"Music\"\n"
        + "    if player state is playing then\n"
        + "      return (name of current track) & \" | \" & (artist of current track) & \" | \" & (album of current track)\n"
        + "    end if\n"
        + "  end tell\nend if\nreturn \"nothing\""
    static let nothing = "Nothing is playing, sir."
    let runner: any StdinCommandRunning

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let out = await AppleScriptRunner(runner: runner).run(Self.script)
        if out.isEmpty || Py.eq(out, "nothing") || AppleScriptText.errored(out) {
            return .text(Self.nothing)
        }
        let parts = AppleScriptText.fields(out)
        let name = parts.first ?? out
        let artist = parts.count > 1 ? parts[1] : ""
        let album = parts.count > 2 ? parts[2] : ""
        var reply = "Now playing \(name)"
        if !artist.isEmpty { reply += " by \(artist)" }
        if !album.isEmpty { reply += ", from \(album)" }
        return .text(reply + ", sir.")
    }
}

/// `music_search`, Python's `_music_search` (jarvis.py 1500-1542): lists library matches and
/// plays nothing. `by` narrows to the song, artist or album field.
struct MusicSearch: ToolImpl {
    static let name = "music_search"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let fields = ["artist": "artist", "album": "album", "song": "name", "track": "name", "title": "name"]
    let runner: any StdinCommandRunning
    let pause: @Sendable (Double) async -> Void

    static func script(_ cond: String, launch: Bool) -> String {
        "tell application \"Music\"\n" + (launch ? "  launch\n" : "") + "  set out to \"\"\n  try\n"
            + "    set theTracks to (every track whose \(cond))\n"
            + "    set n to (count of theTracks)\n"
            + "    if n > 8 then set n to 8\n"
            + "    repeat with i from 1 to n\n      set t to item i of theTracks\n"
            + "      set out to out & (name of t) & \" | \" & (artist of t) & \" | \" & (album of t) & linefeed\n"
            + "    end repeat\n  end try\n  return out\nend tell"
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let query = try PyArgs.stringOrEmpty(args, "query", method: "strip")
        let q = AppleScriptText.escape(Py.strip(query))
        if q.isEmpty { return .text("What should I search for, sir?") }
        let by = Py.strip(Py.lower(try PyArgs.stringOrEmpty(args, "by", method: "lower")))
        let cond = Self.fields[by].map { "\($0) contains \"\(q)\"" }
            ?? "(name contains \"\(q)\" or artist contains \"\(q)\" or album contains \"\(q)\")"
        let scripts = AppleScriptRunner(runner: runner)
        var out = await scripts.run(Self.script(cond, launch: true))
        if AppleScriptText.errored(out) {
            await AppleScriptText.ensureRunning("Music", scripts: scripts, pause: pause)
            out = await scripts.run(Self.script(cond, launch: false))
        }
        if AppleScriptText.errored(out) { return .text("I couldn't reach your music library, sir.") }
        let lines = Py.splitlines(out).filter { !Py.strip($0).isEmpty }
        if lines.isEmpty { return .text("I found nothing matching \(query) in your library, sir.") }
        let songs = lines.map { line -> String in
            let p = AppleScriptText.fields(line)
            var s = p[0]
            if p.count > 1, !p[1].isEmpty { s += " by \(p[1])" }
            if p.count > 2, !p[2].isEmpty { s += " on \(p[2])" }
            return s
        }
        let head = "Found \(songs.count)" + (songs.count == 8 ? " (first 8)" : "") + ": "
        return .text(head + songs.joined(separator: "; ") + ", sir.")
    }
}

/// `music_control`, Python's `_music_control` (jarvis.py 1544-1570) over `_media` (1432-1453).
/// The `_media` script is Python's, Spotify branch included (plan §8 R9).
struct MusicControl: ToolImpl {
    static let name = "music_control"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let alias = ["play": "play", "resume": "play", "unpause": "play", "pause": "pause", "stop": "pause",
                        "next": "next track", "skip": "next track", "next track": "next track",
                        "previous": "previous track", "prev": "previous track", "back": "previous track",
                        "previous track": "previous track"]
    static let said = ["play": "Playing", "pause": "Paused", "next track": "Next track",
                       "previous track": "Previous track"]
    let runner: any StdinCommandRunning

    static func media(_ cmd: String) -> String {
        "if application \"Spotify\" is running then\n"
            + "  tell application \"Spotify\" to \(cmd)\n"
            + "else\n"
            + "  tell application \"Music\"\n"
            + "    if it is not running then launch\n"
            + "    \(cmd)\n"
            + "  end tell\n"
            + "end if\nreturn \"ok\""
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let action = args["action"] ?? .string("")
        let a = Py.strip(Py.lower(try PyArgs.stringOrEmpty(args, "action", method: "lower")))
        let volume = args["volume"].flatMap { $0 == .null ? nil : $0 }
        let scripts = AppleScriptRunner(runner: runner)
        var said: [String] = []
        if let command = Self.alias[a] {
            _ = await scripts.run(Self.media(command))
            said.append((Self.said[command] ?? "") + ", sir.")
        } else if !a.isEmpty, volume == nil {
            return .text("I don't know the music action \(PyArgs.repr(action)), sir.")
        }
        if let volume {
            guard let level = try? ActionLevel.clamped(volume) else { return .text("What volume should I set, sir?") }
            let out = await scripts.run("tell application \"Music\" to set sound volume to \(level)")
            said.append(AppleScriptText.errored(out) ? "I couldn't set the music volume, sir." : "Music volume \(level), sir.")
        }
        return .text(said.isEmpty ? "Nothing to do, sir." : said.joined(separator: " "))
    }
}

/// `music_play`, Python's `_play_query` (jarvis.py 1572-1610) as `execute_tool` runs it: the
/// library first, then (online) the top YouTube result, else an Apple Music search page. The
/// page is opened before the announcement is returned, as Python's `act()`.
struct MusicPlay: ToolImpl {
    static let name = "music_play"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let songBy = try! PyRegex(#"^(.*\S)\s+by\s+(\S.*)$"#)
    static let videoID = try! PyRegex(#""videoId":"([\w-]{11})""#)
    let runner: any StdinCommandRunning
    let web: any WebFetching
    let online: @Sendable () async -> Bool
    let opener: any SettingsOpening
    var log: @Sendable (String) -> Void = { _ in }

    static func script(_ cond: String) -> String {
        "tell application \"Music\"\n  launch\n  try\n"
            + "    set theTracks to (every track whose \(cond))\n"
            + "    if (count of theTracks) > 0 then\n      play (item 1 of theTracks)\n      return \"playing\"\n    end if\n"
            + "  end try\n  return \"notfound\"\nend tell"
    }

    static func condition(_ q: String) -> String {
        if let m = songBy.match(q) {
            let song = AppleScriptText.escape(Py.strip(m.groups[1] ?? ""))
            let artist = AppleScriptText.escape(Py.strip(m.groups[2] ?? ""))
            return "name contains \"\(song)\" and artist contains \"\(artist)\""
        }
        let e = AppleScriptText.escape(q)
        return "name contains \"\(e)\" or artist contains \"\(e)\""
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let q = Py.strip(try PyArgs.stringOrEmpty(args, "query", method: "strip"))
        let out = await AppleScriptRunner(runner: runner).run(Self.script(Self.condition(q)))
        if Py.startsWith(out, "playing") { return .text("Playing \(q) from your library, sir.") }
        if await online() {
            do {
                let body = try await web.get("https://www.youtube.com/results?search_query=" + PyURL.quote(q),
                                             headers: [("User-Agent", "Mozilla/5.0")], timeout: 8)
                if let id = Self.videoID.search(String(decoding: body, as: UTF8.self))?.groups[1],
                   let url = URL(string: "https://www.youtube.com/watch?v=\(id)") {
                    await opener.open(url)
                    return .text("Playing \(q), sir.")
                }
            } catch {
                log("YouTube search failed: \(WebSearch.describe(error))")
            }
        }
        if let url = URL(string: "https://music.apple.com/us/search?term=" + PyURL.quote(q)) {
            await opener.open(url)
        }
        return .text("I couldn't play \(q) directly, sir; opening a search.")
    }
}

/// What a platform opens URLs with before the app gives it LaunchServices: nothing, so a
/// fake platform never opens a real page.
struct NoURLOpener: SettingsOpening {
    func open(_ url: URL) async {}
}
