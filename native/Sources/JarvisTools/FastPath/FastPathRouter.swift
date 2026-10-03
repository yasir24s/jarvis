import Foundation
import JarvisCore

/// What a fast-path branch this port carries asks for (PA batch A). Every other branch of
/// Python's `fast_path` is matched, so the order stays Python's, and then goes to the brain.
public enum FastPathCommand: Sendable, Equatable {
    /// `forget_correction(t)` / `learn_correction(t)` with the normalised text.
    case forgetCorrection(String)
    case learnCorrection(String)
    /// `("Playing, sir.", lambda: _media("play"))` and the other three media phrases.
    case media(announcement: String, command: String)
    /// `"At your service, sir."`
    case presence
    case forgetVoice
    /// `_set_timer(secs)`: the seconds as Python computed them, before `max(1, …)`.
    case setTimer(Int)
    case cancelTimers
    case timerStatus
    case cancelAlarms
    case listAlarms
    case lockScreen
    case emptyTrash
    case quitAllApps
    case sleepMac
    case ipReport
    case btBattery
    // PR2: the branches PA batch A left to the brain, each Python's own helper call.
    /// `_system_report()`.
    case diagnostics
    /// `_run_shortcut(name)` (the run and lights branches).
    case runShortcut(String)
    /// `(announcement, lambda: _open_settings(pane))`; nil pane is `_open_settings()`.
    case openSettings(announcement: String, pane: String?)
    /// `_open_path(path)`, `_resolve_open(name)`, `_reveal_in_finder(path)`.
    case openPath(String)
    case resolveOpen(String)
    case reveal(String)
    case nowPlaying
    /// `_play_query(q)`.
    case playQuery(String)
    case location
    /// `_weather(city)`.
    case weather(String)
    /// `_create_reminder(task, when_text)`.
    case reminder(task: String, when: String)
    /// `set_alarm(when)`.
    case setAlarm(String)
    /// `_find_song_by_lyrics(lyrics)`.
    case songByLyrics(String)
    case messages
    case calendar
    case briefing
    /// `_make_note(text)`.
    case makeNote(String)
    /// `_get_system_info(kind)`: "time" or "battery".
    case systemInfo(String)
    case backendReport
    /// `(f"Setting volume to {lvl}, sir.", lambda: _set_volume(lvl))` and mute.
    case setVolume(announcement: String, level: Int)
    /// `(…, lambda: _nudge_volume(±15))`.
    case nudgeVolume(announcement: String, delta: Int)
    case news
    case screenshot
    /// `(f"Brightness to {lvl}, sir.", lambda: _set_brightness(lvl))`.
    case setBrightness(announcement: String, level: Int)
    /// `(…, lambda: _nudge_brightness(±4))`.
    case nudgeBrightness(announcement: String, steps: Int)
    /// `_send_message(recipient, text)`.
    case sendMessage(recipient: String, text: String)
    /// `_type_text(text)`.
    case typeText(String)
    case summarizePage
    case listShortcuts
    /// `_quit_app(name)`.
    case quitApp(String)
    case copyLastReply
    /// The f-string over `_default_browser_name()`.
    case defaultBrowser
    /// `_set_default_browser(name)`.
    case setDefaultBrowser(String)
    /// `_find_apps(kind)`.
    case findApps(String)
    /// `(…, lambda: _toggle_system(thing_key, on))`.
    case toggleSystem(announcement: String, feature: String, on: Bool)
    /// `("Done, sir.", lambda: _macos_tweak(thing, on))`.
    case macosTweak(thing: String, on: Bool)
    /// `_spotlight("", recent=True)`.
    case recentFiles
    /// `(announcement, lambda: _open_url(url))`: the Google and YouTube searches.
    case openURL(announcement: String, url: String)

    /// Python's own spelling of the call, `{fn, args}` in the quick_router golden fixture.
    public var goldenCall: (fn: String, args: [String]) {
        switch self {
        case .forgetCorrection(let t): ("forget_correction", [t])
        case .learnCorrection(let t): ("learn_correction", [t])
        case .media(_, let command): ("_media", [command])
        case .presence: ("", [])
        case .forgetVoice: ("forget_voice", [])
        case .setTimer(let secs): ("_set_timer", [String(secs)])
        case .cancelTimers: ("_cancel_timers", [])
        case .timerStatus: ("_timer_status", [])
        case .cancelAlarms: ("_cancel_alarms", [])
        case .listAlarms: ("_list_alarms", [])
        case .lockScreen: ("_lock_screen", [])
        case .emptyTrash: ("_empty_trash", [])
        case .quitAllApps: ("_quit_all_apps", [])
        case .sleepMac: ("_sleep_mac", [])
        case .ipReport: ("_ip_report", [])
        case .btBattery: ("_bt_battery", [])
        case .diagnostics: ("_system_report", [])
        case .runShortcut(let name): ("_run_shortcut", [name])
        case .openSettings(_, let pane): ("_open_settings", pane.map { [$0] } ?? [])
        case .openPath(let path): ("_open_path", [path])
        case .resolveOpen(let name): ("_resolve_open", [name])
        case .reveal(let path): ("_reveal_in_finder", [path])
        case .nowPlaying: ("_now_playing", [])
        case .playQuery(let q): ("_play_query", [q])
        case .location: ("_location", [])
        case .weather(let city): ("_weather", [city])
        case .reminder(let task, let when): ("_create_reminder", [task, when])
        case .setAlarm(let when): ("set_alarm", [when])
        case .songByLyrics(let lyrics): ("_find_song_by_lyrics", [lyrics])
        case .messages: ("_recent_messages", [])
        case .calendar: ("_calendar_today", [])
        case .briefing: ("_briefing", [])
        case .makeNote(let text): ("_make_note", [text])
        case .systemInfo(let kind): ("_get_system_info", [kind])
        case .backendReport: ("_backend_report", [])
        case .setVolume(_, let level): ("_set_volume", [String(level)])
        case .nudgeVolume(_, let delta): ("_nudge_volume", [String(delta)])
        case .news: ("_get_news", [])
        case .screenshot: ("_take_screenshot", [])
        case .setBrightness(_, let level): ("_set_brightness", [String(level)])
        case .nudgeBrightness(_, let steps): ("_nudge_brightness", [String(steps)])
        case .sendMessage(let recipient, let text): ("_send_message", [recipient, text])
        case .typeText(let text): ("_type_text", [text])
        case .summarizePage: ("_summarize_page", [])
        case .listShortcuts: ("_list_shortcuts", [])
        case .quitApp(let name): ("_quit_app", [name])
        case .copyLastReply: ("_copy_last_reply", [])
        case .defaultBrowser: ("_default_browser_name", [])
        case .setDefaultBrowser(let name): ("_set_default_browser", [name])
        case .findApps(let kind): ("_find_apps", [kind])
        case .toggleSystem(_, let feature, let on): ("_toggle_system", [feature, on ? "True" : "False"])
        case .macosTweak(let thing, let on): ("_macos_tweak", [thing, on ? "True" : "False"])
        case .recentFiles: ("_spotlight", [""])
        case .openURL(_, let url): ("_open_url", [url])
        }
    }

    /// What Python speaks at once for a tuple (`kind: act` in the golden), else nil.
    public var announcement: String? {
        switch self {
        case .media(let a, _), .openSettings(let a, _), .setVolume(let a, _), .nudgeVolume(let a, _),
             .setBrightness(let a, _), .nudgeBrightness(let a, _), .toggleSystem(let a, _, _), .openURL(let a, _):
            a
        case .macosTweak: "Done, sir."
        case .lockScreen: QuickReplies.locking
        case .sleepMac: QuickReplies.goodnight
        case .emptyTrash: "Taking out the trash, sir."
        default: nil
        }
    }
}

/// One routed command: the branch of Python's `fast_path` that took it (native/plan/M07 §2.1
/// names, "defer" when none did), and the command when that branch is one this port carries.
public struct FastPathMatch: Sendable, Equatable {
    public let branch: String
    public let command: FastPathCommand?
}

/// jarvis.py `fast_path(text)`'s matching, in Python's order, with no side effects. Proven
/// branch by branch against Python by the quick_router golden suite.
public struct FastPathRouter: Sendable {
    /// Mirrors `_quit_app(name) is not None` (a running app by that name). The app passes
    /// "always": QuickCommands asks the quit tool, and when nothing by that name is running the
    /// phrase goes to the brain, as Python's fall-through does (no later branch can match a
    /// "quit/close/exit …" phrase).
    let quitWouldHandle: @Sendable (String) -> Bool

    public init(quitWouldHandle: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.quitWouldHandle = quitWouldHandle
    }

    /// The branches carried by this port; the rest are matched and sent to the brain.
    /// PR2: every branch but the screen and clipboard help, whose Python helpers are a model
    /// call over OCR or the pasteboard text, which the brain makes with see_screen and
    /// read_clipboard.
    public static let carried: Set<String> = [
        "corr.forget", "corr.teach", "media.play", "media.pause", "media.next", "media.previous",
        "timer.set", "presence", "voice.forget", "lock", "trash", "timer.cancel", "timer.status",
        "alarm.cancel", "alarm.list", "quit.all", "sleep", "ip", "bt.battery",
        "diagnostics", "shortcut.run", "lights", "settings.root", "settings.privacy", "settings.pane",
        "open.file", "open.app", "media.now_playing", "media.play_query", "media.song_by", "location",
        "weather", "reminder", "alarm.set", "lyrics.find", "messages.read", "calendar.today", "briefing",
        "note.make", "time", "battery", "backend", "volume.set", "volume.mute", "news", "screenshot",
        "brightness.set", "message.send", "type", "page.summarize", "shortcut.list", "quit.app",
        "browser.default.get", "apps.find", "toggle", "files.recent", "files.reveal", "web.google",
        "web.youtube", "volume.up", "volume.down", "brightness.up", "brightness.down", "clipboard.copy_last",
        "browser.default.set",
    ]

    /// `text.lower().strip().rstrip("?.")`.
    public static func normalise(_ text: String) -> String {
        Py.rstrip(Py.strip(Py.lower(text)), "?.")
    }

    public func route(_ text: String) -> FastPathMatch {
        let t = Self.normalise(text)
        let p = Patterns.self
        func hit(_ branch: String, _ command: FastPathCommand? = nil) -> FastPathMatch {
            FastPathMatch(branch: branch, command: command)
        }
        func isIn(_ list: [String]) -> Bool { list.contains { Py.eq($0, t) } }
        func has(_ needle: String) -> Bool { Py.contains(t, needle) }

        // transcription corrections, checked first (jarvis.py 4378-4381)
        if p.corrForget.search(t) != nil { return hit("corr.forget", .forgetCorrection(t)) }
        if CorrectionsLogic.parseTeach(t) != nil { return hit("corr.teach", .learnCorrection(t)) }
        if isIn(p.diagnostics) { return hit("diagnostics", .diagnostics) }
        if let m = p.shortcutRun.match(t) {
            return hit("shortcut.run", .runShortcut(Py.strip(Self.orNonEmpty(m.groups[1], m.groups[2]))))
        }
        if let m = p.lights.match(t) {
            let thing = Self.orNonEmpty(m.groups[2], m.groups[3])
            if p.lightWords.contains(where: { Py.eq($0, Py.strip(thing)) }) {
                return hit("lights", .runShortcut("turn \(Self.orNonEmpty(m.groups[1], m.groups[4])) lights"))
            }
        }
        if isIn(p.settingsRoot) {
            return hit("settings.root", .openSettings(announcement: "Opening System Settings, sir.", pane: nil))
        }
        if let m = p.settingsPrivacy.match(t) {
            return hit("settings.privacy", .openSettings(announcement: "Opening privacy settings, sir.",
                                                         pane: Py.strip(m.groups[1] ?? "")))
        }
        if let m = p.settingsPane.match(t) {
            return hit("settings.pane", .openSettings(announcement: "Opening settings, sir.", pane: Py.strip(m.groups[1] ?? "")))
        }
        if let m = p.openFile.match(t) { return hit("open.file", .openPath(Py.strip(m.groups[1] ?? ""))) }
        if let open = p.openApp.match(t) {
            // DEV-M7-01 and DEV-M7-02 (approved): Python's launcher swallows "start a timer for
            // 5 minutes" and "start music"; natively they reach the timer and media branches.
            if let m = p.timerSet.match(t) {
                return hit("timer.set", Self.timerSeconds(m.groups[1] ?? "", unit: m.groups[2] ?? "").map { FastPathCommand.setTimer($0) })
            }
            if isIn(["start music", "start the music"]) {
                return hit("media.play", .media(announcement: "Playing, sir.", command: "play"))
            }
            return hit("open.app", .resolveOpen(Py.strip(open.groups[1] ?? "")))
        }
        if isIn(p.mediaPlay) { return hit("media.play", .media(announcement: "Playing, sir.", command: "play")) }
        if isIn(p.mediaPause) { return hit("media.pause", .media(announcement: "Paused, sir.", command: "pause")) }
        if isIn(p.mediaNext) {
            return hit("media.next", .media(announcement: "Next track, sir.", command: "next track"))
        }
        if isIn(p.mediaPrevious) {
            return hit("media.previous", .media(announcement: "Going back, sir.", command: "previous track"))
        }
        if isIn(p.nowPlaying) { return hit("media.now_playing", .nowPlaying) }
        if let m = p.playQuery.match(t) {
            let q = Py.strip(m.groups[1] ?? "")
            if p.playGeneric.contains(where: { Py.eq($0, q) }) {
                return hit("media.play_query", .media(announcement: "Playing, sir.", command: "play"))
            }
            return hit("media.play_query", .playQuery(q))
        }
        if p.songBy.match(t) != nil, let first = Py.split(t).first,
           !p.songByExcluded.contains(where: { Py.eq($0, first) }) {
            return hit("media.song_by", .playQuery(t))
        }
        if isIn(p.location) { return hit("location", .location) }
        if has("weather") || has("temperature") || has("forecast") || isIn(p.weatherPhrases) {
            return hit("weather", .weather(p.weatherCity.search(t)?.groups[1] ?? ""))
        }
        if let m = p.timerSet.match(t) {
            return hit("timer.set", Self.timerSeconds(m.groups[1] ?? "", unit: m.groups[2] ?? "").map { FastPathCommand.setTimer($0) })
        }
        if let m = p.reminder.match(t) { return hit("reminder", Self.reminder(Py.strip(m.groups[1] ?? ""))) }
        if let m = p.alarmSet.match(t) { return hit("alarm.set", .setAlarm(Py.strip(m.groups[1] ?? ""))) }
        if let m = p.lyrics.match(t) { return hit("lyrics.find", .songByLyrics(m.groups[1] ?? "")) }
        if isIn(p.messages) { return hit("messages.read", .messages) }
        if isIn(p.calendar) { return hit("calendar.today", .calendar) }
        if isIn(p.briefing) { return hit("briefing", .briefing) }
        if isIn(p.screenExact) { return hit("screen.exact") }
        if has("screen"), p.screenWords.contains(where: { has($0) }) { return hit("screen.fuzzy") }
        if isIn(p.clipboard) { return hit("clipboard.help") }
        if let m = p.note.match(t) { return hit("note.make", .makeNote(Py.strip(m.groups[1] ?? ""))) }
        if isIn(p.time) { return hit("time", .systemInfo("time")) }
        if has("battery"), has("level") || has("how much") || has("status") || Py.eq(t, "battery") {
            return hit("battery", .systemInfo("battery"))
        }
        if isIn(p.backend) { return hit("backend", .backendReport) }
        if isIn(p.presence) { return hit("presence", .presence) }
        if isIn(p.forgetVoice) { return hit("voice.forget", .forgetVoice) }
        if let m = p.volumeSet.match(t), let lvl = Self.level(m.groups[1] ?? "") {
            return hit("volume.set", .setVolume(announcement: "Setting volume to \(lvl), sir.", level: lvl))
        }
        if isIn(["mute", "volume off"]) { return hit("volume.mute", .setVolume(announcement: "Muting, sir.", level: 0)) }
        if isIn(["volume up", "louder"]) {
            return hit("volume.up", .nudgeVolume(announcement: "Turning it up, sir.", delta: 15))
        }
        if isIn(["volume down", "quieter"]) {
            return hit("volume.down", .nudgeVolume(announcement: "Turning it down, sir.", delta: -15))
        }
        if isIn(p.news) { return hit("news", .news) }
        if isIn(p.screenshot) { return hit("screenshot", .screenshot) }
        if isIn(p.lock) { return hit("lock", .lockScreen) }
        if isIn(p.trash) { return hit("trash", .emptyTrash) }
        if let m = p.brightnessSet.match(t), let lvl = Self.level(m.groups[1] ?? "") {
            return hit("brightness.set", .setBrightness(announcement: "Brightness to \(lvl), sir.", level: lvl))
        }
        if isIn(p.brightnessUp) { return hit("brightness.up", .nudgeBrightness(announcement: "Brighter, sir.", steps: 4)) }
        if isIn(p.brightnessDown) { return hit("brightness.down", .nudgeBrightness(announcement: "Dimming, sir.", steps: -4)) }
        if let m = p.messageSend.match(t) {
            return hit("message.send", .sendMessage(recipient: Py.strip(m.groups[1] ?? ""), text: Py.strip(m.groups[2] ?? "")))
        }
        if let m = p.typeText.match(t) { return hit("type", .typeText(Py.strip(m.groups[1] ?? ""))) }
        if isIn(p.summarize) { return hit("page.summarize", .summarizePage) }
        if isIn(p.shortcutList) { return hit("shortcut.list", .listShortcuts) }
        if p.timerCancel.match(t) != nil { return hit("timer.cancel", .cancelTimers) }
        if p.timerHowLong.search(t) != nil || isIn(p.timerStatus) { return hit("timer.status", .timerStatus) }
        if p.alarmCancel.match(t) != nil { return hit("alarm.cancel", .cancelAlarms) }
        if isIn(p.alarmList) { return hit("alarm.list", .listAlarms) }
        if isIn(p.quitAll) { return hit("quit.all", .quitAllApps) }
        if let m = p.quitApp.match(t), quitWouldHandle(Py.strip(m.groups[1] ?? "")) {
            return hit("quit.app", .quitApp(Py.strip(m.groups[1] ?? "")))
        }
        if isIn(p.sleep) { return hit("sleep", .sleepMac) }
        if isIn(p.copyLast) { return hit("clipboard.copy_last", .copyLastReply) }
        if isIn(p.defaultBrowser) { return hit("browser.default.get", .defaultBrowser) }
        if let m = p.setBrowser1.match(t) ?? p.setBrowser2.match(t) {
            return hit("browser.default.set", .setDefaultBrowser(Py.strip(m.groups[1] ?? "")))
        }
        if let m = p.appsFind.match(t) {
            let kind = Py.strip(m.groups[1] ?? "")
            if !(AppKinds.kindWord(kind) ?? "").isEmpty || AppKinds.allKinds.contains(where: { Py.eq($0, kind) }) {
                return hit("apps.find", .findApps(kind))
            }
        }
        if let m = p.toggle.match(t) {
            let thing = Py.strip(m.groups[2] ?? "")
            let key = p.leadingThe.sub(thing, literal: "")
            let knownSys = p.toggleSystem.contains { Py.eq($0, key) }
            let knownTweak = Self.tweakNames.contains { Py.contains($0, key) || Py.contains(key, $0) }
            let verb = m.groups[1] ?? ""
            let on = ["on", "enable", "show"].contains { Py.eq($0, verb) }
            if knownSys {
                let spoken = Py.eq(verb, "on") || Py.eq(verb, "off") ? "Turning \(verb) \(thing), sir." : "Done, sir."
                return hit("toggle", .toggleSystem(announcement: spoken, feature: key, on: on))
            }
            if knownTweak { return hit("toggle", .macosTweak(thing: thing, on: on)) }
        }
        if isIn(p.recentFiles) { return hit("files.recent", .recentFiles) }
        if let m = p.reveal.match(t), has("file") || has("in finder") {
            return hit("files.reveal", .reveal(Py.strip(m.groups[1] ?? "")))
        }
        if isIn(p.ip) { return hit("ip", .ipReport) }
        if isIn(p.bluetooth) { return hit("bt.battery", .btBattery) }
        if let m = p.google.match(t) {
            let q = Py.strip(m.groups[1] ?? "")
            return hit("web.google", .openURL(announcement: "Googling \(q), sir.",
                                              url: "https://www.google.com/search?q=" + PyURL.quote(q)))
        }
        if let m = p.youtube1.match(t) ?? p.youtube2.match(t) {
            let q = Py.strip(m.groups[1] ?? "")
            return hit("web.youtube", .openURL(announcement: "Searching YouTube for \(q), sir.",
                                               url: "https://www.youtube.com/results?search_query=" + PyURL.quote(q)))
        }
        return hit("defer")
    }

    /// `m.group(2) or m.group(3) or ""`.
    static func orNonEmpty(_ a: String?, _ b: String?) -> String {
        if let a, !a.isEmpty { return a }
        if let b, !b.isEmpty { return b }
        return ""
    }

    /// The reminder branch's split of `rest` into the task and `when_text`.
    static func reminder(_ rest: String) -> FastPathCommand {
        let wm = Patterns.reminderWhen.search(rest)
        let when = wm?.groups[1] ?? ""
        let task = Py.strip(wm.map { Py.strip(Py.prefix(rest, $0.span.lowerBound)) } ?? rest, " ,")
        return .reminder(task: task.isEmpty ? rest : task, when: when)
    }

    /// `max(0, min(100, int(m.group(1))))` for the volume and brightness levels (`\d{1,3}`, so
    /// never more than three digits); nil only if the digits are not decimal digits.
    static func level(_ digits: String) -> Int? {
        timerSeconds(digits, unit: "sec").map { max(0, min(100, $0)) }
    }

    /// `n, u = int(m.group(1)), m.group(2)` and the seconds. Python's `\d` and `int()` take
    /// every Unicode decimal digit. Nil when the number does not fit an Int (Python's would).
    static func timerSeconds(_ digits: String, unit: String) -> Int? {
        var n = 0
        for scalar in digits.unicodeScalars {
            guard let value = scalar.properties.numericValue, scalar.properties.numericType == .decimal else {
                return nil
            }
            let (times, o1) = n.multipliedReportingOverflow(by: 10)
            let (sum, o2) = times.addingReportingOverflow(Int(value))
            if o1 || o2 { return nil }
            n = sum
        }
        let factor = unit.hasPrefix("sec") ? 1 : unit.hasPrefix("min") ? 60 : 3600
        let (secs, overflow) = n.multipliedReportingOverflow(by: factor)
        return overflow ? nil : secs
    }

    /// `_TWEAKS`' keys, in Python's order: "dark mode", then SystemControl's tweaks.
    static let tweakNames: [String] = ["dark mode"] + SystemControl.tweakNames

    enum Patterns {
        static func re(_ pattern: String) -> PyRegex { try! PyRegex(pattern) }

        static let corrForget = try! PyRegex(#"\bforget (?:the )?corrections?(?: for)?\s*(.*)"#, ignoreCase: true)
        static let diagnostics = [
            "run diagnostics", "run a diagnostic", "run a diagnostics", "run system diagnostics",
            "system report", "system status", "full diagnostics", "diagnostics",
            "how's my system", "hows my system", "system health", "status report",
            "run a systems check", "systems check", "run a system check"]
        static let shortcutRun = re(#"run (?:the )?shortcut (.+)|run (?:the )?(.+?) shortcut$"#)
        static let lights = re(#"(?:turn|switch) (on|off) (?:the |my )?(.+)|(?:the |my )?(.+?) (on|off)$"#)
        static let lightWords = ["lights", "light", "lamp", "lamps", "the lights"]
        static let settingsRoot = ["open settings", "open system settings", "open preferences",
                                   "open system preferences", "settings", "system settings"]
        static let settingsPrivacy = re(#"open (?:the )?(.+?) (?:privacy|permission)s?(?: settings)?$"#)
        static let settingsPane = re(#"(?:open|show|go to|take me to) (?:the )?(.+?) (?:settings|preferences)$"#)
        static let openFile = re(#"open (?:the )?file (.+)"#)
        static let openApp = re(#"(?:open|launch|open up|fire up|bring up|pull up|run|start|go to)\s+(.+)"#)
        static let mediaPlay = [
            "play", "resume", "play music", "resume music", "continue playing", "unpause",
            "play it", "play some music", "play a song", "play something", "play tunes",
            "play me music", "play me some music", "start music", "start the music"]
        static let mediaPause = ["pause", "pause music", "pause it", "stop", "stop music", "stop the music"]
        static let mediaNext = ["next", "next song", "next track", "skip", "skip song", "skip this", "skip it"]
        static let mediaPrevious = ["previous", "previous song", "previous track", "last song",
                                    "go back a song", "replay"]
        static let nowPlaying = ["what's playing", "what is playing", "what song is this", "current song",
                                 "name this song"]
        static let playQuery = re(#"(?:play|put on|throw on|listen to|i want to listen to|i wanna listen to|"#
            + #"i want to hear|can you play)\s+(?:some |the song |the track |me )?(.+?)"#
            + #"(?: please)?$"#)
        static let playGeneric = ["music", "it", "that", "something", "a song", "some music", "tunes", "songs"]
        static let songBy = re(#"^[\w'&., ]+ by [\w'&., ]+$"#)
        static let songByExcluded = ["what", "who", "stand", "made", "written", "directed", "designed", "built"]
        static let location = ["where am i", "where am i right now", "what's my location", "what is my location",
                               "my location", "where are we", "what's my current location", "locate me"]
        static let weatherPhrases = ["is it raining", "is it cold", "is it hot", "do i need a jacket",
                                     "is it going to rain", "will it rain", "will it rain today",
                                     "is it nice out", "what's it like outside"]
        static let weatherCity = re(#"(?:weather|temperature|forecast)\s*(?:like\s*)?in (.+)"#)
        static let timerSet = re(#"(?:set |start )?(?:a |an )?timer (?:for |of )?(\d+)\s*"#
            + #"(second|sec|minute|min|hour|hr)s?"#)
        static let reminder = re(#"(?:remind me to|set a reminder to|reminder to|remind me)\s+(.+)"#)
        static let reminderWhen = re(#"\b(in \d+\s*\w+.*|at \d.*|tomorrow.*)$"#)
        static let alarmSet = re(#"(?:set (?:an? )?alarm|wake me up|set alarm)\s*(?:for|at|in)?\s*(.+)"#)
        static let lyrics = re(#"(?:what(?:'s| is)? the song (?:that goes|with the lyrics|that says|called)|"#
            + #"find (?:the |a )?song(?: that goes| with the lyrics)?|name the song that goes|"#
            + #"what song (?:goes|says)|song that goes)\s+(.+)"#)
        static let messages = ["read my messages", "read my texts", "any new messages", "any new texts",
                               "latest messages", "check my messages", "read my latest texts",
                               "read my latest messages"]
        static let calendar = ["what's on my calendar", "whats on my calendar", "my calendar", "my schedule",
                               "what's my schedule", "whats my schedule", "what's on today", "whats on today",
                               "what does my day look like", "my schedule today", "what's on my schedule"]
        static let briefing = ["brief me", "briefing", "daily briefing", "what's my briefing", "morning briefing",
                               "good morning jarvis", "good morning", "good evening jarvis"]
        static let screenExact = ["what's on my screen", "whats on my screen", "what am i looking at",
                                  "look at my screen", "read my screen", "analyze my screen", "help me with this",
                                  "what should i do", "what am i doing", "help with this", "what do you see",
                                  "check my screen", "scan my screen", "what's on screen", "give me ideas"]
        static let screenWords = ["what", "help", "read", "look", "see", "analy", "scan", "explain"]
        static let clipboard = ["what's on my clipboard", "whats on my clipboard", "read my clipboard",
                                "what did i copy", "explain this", "what is this", "explain my clipboard",
                                "check my clipboard"]
        static let note = re(#"(?:take a note|make a note|note that|new note|jot down|note)\s*[:,\-]?\s*(.+)"#)
        static let time = ["what time is it", "what's the time", "time", "what is the time"]
        static let backend = ["which model are you using", "what model are you using", "which backend",
                              "what backend are you using", "are you using claude", "claude or local",
                              "which brain are you using", "what model handled that", "backend status",
                              "are you running on claude", "which model was that"]
        static let presence = ["are you there", "you there", "hello", "you online", "are you online", "status"]
        static let forgetVoice = ["forget my voice", "reset voice recognition", "respond to everyone",
                                  "disable voice recognition", "clear my voice", "stop recognizing only me"]
        static let volumeSet = re(#"(?:set )?volume (?:to )?(\d{1,3})"#)
        static let news = ["news", "the news", "any news", "what's in the news", "whats in the news",
                           "give me the news", "news briefing", "top headlines", "headlines",
                           "the headlines", "today's headlines", "todays headlines", "what's the news",
                           "whats the news", "what's happening in the world", "whats happening in the world"]
        static let screenshot = ["take a screenshot", "screenshot", "capture the screen", "capture my screen",
                                 "grab a screenshot", "screenshot this", "take a screen shot"]
        static let lock = ["lock my screen", "lock the screen", "lock my mac", "lock the mac", "lock it",
                           "lock my computer", "lock the computer", "lock up", "i'm stepping away",
                           "im stepping away", "going away for a bit"]
        static let trash = ["empty the trash", "empty trash", "empty the bin", "empty my trash",
                            "take out the trash", "empty the recycle bin"]
        static let brightnessSet = re(#"(?:set )?brightness (?:to )?(\d{1,3})(?: percent)?"#)
        static let brightnessUp = ["brightness up", "brighter", "screen brighter", "make it brighter"]
        static let brightnessDown = ["brightness down", "dimmer", "screen dimmer", "make it dimmer", "dim the screen"]
        static let messageSend = re(#"(?:send (?:a |an )?(?:message|text|imessage)|text|message|imessage)\s+"#
            + #"(?:to\s+)?(.+?)\s+(?:saying|that says|say|telling (?:them|her|him))\s+(.+)"#)
        static let typeText = re(#"(?:type|dictate|take this down)\s*[:,\-]?\s+(.+)"#)
        static let summarize = ["summarize this page", "summarise this page", "summarize this article",
                                "summarise this article", "summarize this", "read this page", "read this article",
                                "what's this page about", "whats this page about", "what's this article about",
                                "whats this article about", "tldr", "give me the gist of this"]
        static let shortcutList = ["what shortcuts do i have", "list my shortcuts", "my shortcuts",
                                   "what automations do i have", "list shortcuts"]
        static let timerCancel = re(#"(?:cancel|stop|kill) (?:the |my |all )?timers?$"#)
        static let timerHowLong = re(#"how (?:long|much time).*timer"#)
        static let timerStatus = ["timer status", "how's the timer", "hows the timer", "how long left",
                                  "check the timer", "check my timer"]
        static let alarmCancel = re(#"(?:cancel|stop|kill|delete|turn off) (?:the |my |all )?alarms?$"#)
        static let alarmList = ["what alarms do i have", "list my alarms", "my alarms", "list alarms",
                                "what alarms are set", "do i have any alarms"]
        static let quitAll = ["close everything", "quit everything", "close all apps", "quit all apps",
                              "close all my apps", "quit all applications", "close every app"]
        static let quitApp = re(#"(?:quit|close|exit)\s+(.+)"#)
        static let sleep = ["goodnight jarvis", "good night jarvis", "goodnight", "good night",
                            "put the mac to sleep", "put my mac to sleep", "sleep the mac",
                            "put the computer to sleep"]
        static let copyLast = ["copy that", "copy this", "copy that to my clipboard", "copy this to my clipboard",
                               "put that on my clipboard", "copy your last reply", "copy your answer",
                               "copy the answer", "copy it"]
        static let defaultBrowser = ["what's my default browser", "whats my default browser",
                                     "what is my default browser", "which browser is my default",
                                     "what browser am i using"]
        static let setBrowser1 = re(#"(?:set|make|change) (?:the |my )?default browser to (.+)"#)
        static let setBrowser2 = re(#"make (.+?) (?:my|the) default browser"#)
        static let appsFind = re(#"(?:what|which) (.+?)(?: apps?)? do i have(?: installed)?$"#)
        static let toggle = re(#"(?:turn |switch )?(on|off|enable|disable|show|hide) (.+)"#)
        static let leadingThe = re(#"^(the )?"#)
        static let toggleSystem = ["wifi", "wi-fi", "wireless", "bluetooth", "bt", "do not disturb", "dnd",
                                   "focus", "dark mode", "dark", "light mode"]
        static let recentFiles = ["what did i work on recently", "recent files", "my recent files",
                                  "what have i been working on", "recently changed files"]
        static let reveal = re(#"(?:reveal|find the file|where is) (?:the )?(?:file )?(.+?)"#
            + #"(?: in finder)?$"#)
        static let ip = ["what's my ip", "whats my ip", "what's my ip address", "whats my ip address",
                         "what is my ip address", "my ip address", "ip address", "what's my public ip",
                         "whats my public ip"]
        static let bluetooth = ["how are my airpods", "airpods battery", "airpod battery", "check my airpods",
                                "how's my airpods battery", "hows my airpods battery", "whats my airpods battery",
                                "what's my airpods battery", "headphones battery", "headphone battery",
                                "how are my headphones"]
        static let google = re(#"google\s+(.+)"#)
        static let youtube1 = re(#"(?:search |look up |find )?youtube (?:for )?(.+)"#)
        static let youtube2 = re(#"(?:search for |look up |find )(.+?) on youtube$"#)
    }
}
