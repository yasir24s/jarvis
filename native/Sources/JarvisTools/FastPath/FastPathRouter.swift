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
    /// Mirrors `_quit_app(name) is not None` (a running app by that name). The quit branch is
    /// not carried, so the app passes "always": the brain gets "quit X", and nothing after that
    /// branch that this port carries can match a "quit/close/exit …" phrase anyway.
    let quitWouldHandle: @Sendable (String) -> Bool

    public init(quitWouldHandle: @escaping @Sendable (String) -> Bool = { _ in true }) {
        self.quitWouldHandle = quitWouldHandle
    }

    /// The branches carried by this port; the rest are matched and sent to the brain.
    public static let carried: Set<String> = [
        "corr.forget", "corr.teach", "media.play", "media.pause", "media.next", "media.previous",
        "timer.set", "presence", "voice.forget", "lock", "trash", "timer.cancel", "timer.status",
        "alarm.cancel", "alarm.list", "quit.all", "sleep", "ip", "bt.battery",
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
        if isIn(p.diagnostics) { return hit("diagnostics") }
        if p.shortcutRun.match(t) != nil { return hit("shortcut.run") }
        if let m = p.lights.match(t) {
            let thing = Self.orNonEmpty(m.groups[2], m.groups[3])
            if p.lightWords.contains(where: { Py.eq($0, Py.strip(thing)) }) { return hit("lights") }
        }
        if isIn(p.settingsRoot) { return hit("settings.root") }
        if p.settingsPrivacy.match(t) != nil { return hit("settings.privacy") }
        if p.settingsPane.match(t) != nil { return hit("settings.pane") }
        if p.openFile.match(t) != nil { return hit("open.file") }
        if p.openApp.match(t) != nil {
            // DEV-M7-01 and DEV-M7-02 (approved): Python's launcher swallows "start a timer for
            // 5 minutes" and "start music"; natively they reach the timer and media branches.
            if let m = p.timerSet.match(t) {
                return hit("timer.set", Self.timerSeconds(m.groups[1] ?? "", unit: m.groups[2] ?? "").map { FastPathCommand.setTimer($0) })
            }
            if isIn(["start music", "start the music"]) {
                return hit("media.play", .media(announcement: "Playing, sir.", command: "play"))
            }
            return hit("open.app")
        }
        if isIn(p.mediaPlay) { return hit("media.play", .media(announcement: "Playing, sir.", command: "play")) }
        if isIn(p.mediaPause) { return hit("media.pause", .media(announcement: "Paused, sir.", command: "pause")) }
        if isIn(p.mediaNext) {
            return hit("media.next", .media(announcement: "Next track, sir.", command: "next track"))
        }
        if isIn(p.mediaPrevious) {
            return hit("media.previous", .media(announcement: "Going back, sir.", command: "previous track"))
        }
        if isIn(p.nowPlaying) { return hit("media.now_playing") }
        if p.playQuery.match(t) != nil { return hit("media.play_query") }
        if p.songBy.match(t) != nil, let first = Py.split(t).first,
           !p.songByExcluded.contains(where: { Py.eq($0, first) }) {
            return hit("media.song_by")
        }
        if isIn(p.location) { return hit("location") }
        if has("weather") || has("temperature") || has("forecast") || isIn(p.weatherPhrases) {
            return hit("weather")
        }
        if let m = p.timerSet.match(t) {
            return hit("timer.set", Self.timerSeconds(m.groups[1] ?? "", unit: m.groups[2] ?? "").map { FastPathCommand.setTimer($0) })
        }
        if p.reminder.match(t) != nil { return hit("reminder") }
        if p.alarmSet.match(t) != nil { return hit("alarm.set") }
        if p.lyrics.match(t) != nil { return hit("lyrics.find") }
        if isIn(p.messages) { return hit("messages.read") }
        if isIn(p.calendar) { return hit("calendar.today") }
        if isIn(p.briefing) { return hit("briefing") }
        if isIn(p.screenExact) { return hit("screen.exact") }
        if has("screen"), p.screenWords.contains(where: { has($0) }) { return hit("screen.fuzzy") }
        if isIn(p.clipboard) { return hit("clipboard.help") }
        if p.note.match(t) != nil { return hit("note.make") }
        if isIn(p.time) { return hit("time") }
        if has("battery"), has("level") || has("how much") || has("status") || Py.eq(t, "battery") {
            return hit("battery")
        }
        if isIn(p.backend) { return hit("backend") }
        if isIn(p.presence) { return hit("presence", .presence) }
        if isIn(p.forgetVoice) { return hit("voice.forget", .forgetVoice) }
        if p.volumeSet.match(t) != nil { return hit("volume.set") }
        if isIn(["mute", "volume off"]) { return hit("volume.mute") }
        if isIn(["volume up", "louder"]) { return hit("volume.up") }
        if isIn(["volume down", "quieter"]) { return hit("volume.down") }
        if isIn(p.news) { return hit("news") }
        if isIn(p.screenshot) { return hit("screenshot") }
        if isIn(p.lock) { return hit("lock", .lockScreen) }
        if isIn(p.trash) { return hit("trash", .emptyTrash) }
        if p.brightnessSet.match(t) != nil { return hit("brightness.set") }
        if isIn(p.brightnessUp) { return hit("brightness.up") }
        if isIn(p.brightnessDown) { return hit("brightness.down") }
        if p.messageSend.match(t) != nil { return hit("message.send") }
        if p.typeText.match(t) != nil { return hit("type") }
        if isIn(p.summarize) { return hit("page.summarize") }
        if isIn(p.shortcutList) { return hit("shortcut.list") }
        if p.timerCancel.match(t) != nil { return hit("timer.cancel", .cancelTimers) }
        if p.timerHowLong.search(t) != nil || isIn(p.timerStatus) { return hit("timer.status", .timerStatus) }
        if p.alarmCancel.match(t) != nil { return hit("alarm.cancel", .cancelAlarms) }
        if isIn(p.alarmList) { return hit("alarm.list", .listAlarms) }
        if isIn(p.quitAll) { return hit("quit.all", .quitAllApps) }
        if let m = p.quitApp.match(t), quitWouldHandle(Py.strip(m.groups[1] ?? "")) { return hit("quit.app") }
        if isIn(p.sleep) { return hit("sleep", .sleepMac) }
        if isIn(p.copyLast) { return hit("clipboard.copy_last") }
        if isIn(p.defaultBrowser) { return hit("browser.default.get") }
        if p.setBrowser1.match(t) != nil || p.setBrowser2.match(t) != nil { return hit("browser.default.set") }
        if let m = p.appsFind.match(t) {
            let kind = Py.strip(m.groups[1] ?? "")
            if !(AppKinds.kindWord(kind) ?? "").isEmpty || AppKinds.allKinds.contains(where: { Py.eq($0, kind) }) {
                return hit("apps.find")
            }
        }
        if let m = p.toggle.match(t) {
            let thing = Py.strip(m.groups[2] ?? "")
            let key = p.leadingThe.sub(thing, literal: "")
            let knownSys = p.toggleSystem.contains { Py.eq($0, key) }
            let knownTweak = Self.tweakNames.contains { Py.contains($0, key) || Py.contains(key, $0) }
            if knownSys || knownTweak { return hit("toggle") }
        }
        if isIn(p.recentFiles) { return hit("files.recent") }
        if p.reveal.match(t) != nil, has("file") || has("in finder") { return hit("files.reveal") }
        if isIn(p.ip) { return hit("ip", .ipReport) }
        if isIn(p.bluetooth) { return hit("bt.battery", .btBattery) }
        if p.google.match(t) != nil { return hit("web.google") }
        if p.youtube1.match(t) != nil || p.youtube2.match(t) != nil { return hit("web.youtube") }
        return hit("defer")
    }

    /// `m.group(2) or m.group(3) or ""`.
    static func orNonEmpty(_ a: String?, _ b: String?) -> String {
        if let a, !a.isEmpty { return a }
        if let b, !b.isEmpty { return b }
        return ""
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
        static let songBy = re(#"^[\w'&., ]+ by [\w'&., ]+$"#)
        static let songByExcluded = ["what", "who", "stand", "made", "written", "directed", "designed", "built"]
        static let location = ["where am i", "where am i right now", "what's my location", "what is my location",
                               "my location", "where are we", "what's my current location", "locate me"]
        static let weatherPhrases = ["is it raining", "is it cold", "is it hot", "do i need a jacket",
                                     "is it going to rain", "will it rain", "will it rain today",
                                     "is it nice out", "what's it like outside"]
        static let timerSet = re(#"(?:set |start )?(?:a |an )?timer (?:for |of )?(\d+)\s*"#
            + #"(second|sec|minute|min|hour|hr)s?"#)
        static let reminder = re(#"(?:remind me to|set a reminder to|reminder to|remind me)\s+(.+)"#)
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
