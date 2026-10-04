import Foundation
import JarvisCore

// od/phase2 item 2 (DEV-OD2-01): everyday commands the on-device model was slow or wrong on
// (battery, Wi-Fi, time, CPU, volume, media keys, reminders, alarms, timers) answered without
// the model. Python's `fast_path` takes only its exact phrasings; these branches are tried only
// after every Python branch has deferred, so every phrasing Python routes keeps its routing.

extension FastPathRouter {
    /// The native branches this file adds, each matched only after Python's have deferred.
    static let quickBranches: Set<String> = [
        "battery.native", "wifi.native", "cpu.native", "time.native", "volume.native", "media.native",
        "reminder.native", "alarm.native", "timer.native",
    ]

    /// Python branches whose command a politely wrapped phrasing may reuse: "can you pause the
    /// music please" is routed as "pause the music".
    static let politeReuse: [String: String] = [
        "time": "time.native", "battery": "battery.native", "volume.set": "volume.native",
        "volume.mute": "volume.native", "volume.up": "volume.native", "volume.down": "volume.native",
        "media.play": "media.native", "media.pause": "media.native", "media.next": "media.native",
        "media.previous": "media.native", "reminder": "reminder.native", "alarm.set": "alarm.native",
        "timer.set": "timer.native",
    ]

    /// The native branch and command for `t` (already `normalise`d), or nil to defer.
    func nativeQuick(_ t: String) -> (String, FastPathCommand)? {
        let s = Self.canonical(Self.unwrapped(t))
        guard !s.isEmpty else { return nil }
        if s != t {
            let again = route(s)
            if let command = again.command {
                if let branch = Self.politeReuse[again.branch] { return (branch, command) }
                if Self.quickBranches.contains(again.branch) { return (again.branch, command) }
            }
        }
        let q = NativePatterns.self
        func any(_ list: [PyRegex]) -> PyMatch? { list.lazy.compactMap { $0.match(s) }.first }

        if any(q.battery) != nil { return ("battery.native", .systemInfo("battery")) }
        if any(q.wifi) != nil { return ("wifi.native", .systemInfo("wifi")) }
        if any(q.cpu) != nil { return ("cpu.native", .systemInfo("cpu")) }
        // A typo anywhere but in "time" itself: "what's the tide" is not about the clock.
        if Self.near(s, q.time), s.split(separator: " ").contains(where: { q.timeWord.contains(String($0)) }) {
            return ("time.native", .systemInfo("time"))
        }

        if let m = any(q.volumeSet), let lvl = Self.level(m.groups[1] ?? "") {
            return ("volume.native", .setVolume(announcement: "Setting volume to \(lvl), sir.", level: lvl))
        }
        if q.mute.contains(s) { return ("volume.native", .setVolume(announcement: "Muting, sir.", level: 0)) }
        if q.louder.contains(s) {
            return ("volume.native", .nudgeVolume(announcement: "Turning it up, sir.", delta: 15))
        }
        if q.quieter.contains(s) {
            return ("volume.native", .nudgeVolume(announcement: "Turning it down, sir.", delta: -15))
        }

        if q.pause.contains(s) { return ("media.native", .media(announcement: "Paused, sir.", command: "pause")) }
        if q.play.contains(s) { return ("media.native", .media(announcement: "Playing, sir.", command: "play")) }
        if q.next.contains(s) { return ("media.native", .media(announcement: "Next track, sir.", command: "next track")) }
        if q.previous.contains(s) {
            return ("media.native", .media(announcement: "Going back, sir.", command: "previous track"))
        }

        if let m = q.reminderTimeFirst.match(s) {
            let when = Py.strip(m.groups[1] ?? ""), task = Py.strip(m.groups[2] ?? "")
            let joiner = when.first?.isNumber == true ? " at " : " "
            return ("reminder.native", Self.reminder(task + joiner + when))
        }
        if let m = any(q.reminder) { return ("reminder.native", Self.reminder(Py.strip(m.groups[1] ?? ""))) }

        if let m = any(q.timer), let secs = Self.timerSeconds(m.groups[1] ?? "", unit: m.groups[2] ?? "") {
            return ("timer.native", .setTimer(secs))
        }
        // A label ("… labelled gym") is the model's to split out; set_alarm's `when` has no room for it.
        if let m = any(q.alarm), let when = m.groups[1].map({ Py.strip($0) }),
           !q.labelWords.contains(where: { (" " + when + " ").contains(" " + $0 + " ") }) {
            return ("alarm.native", .setAlarm(when))
        }
        return nil
    }

    /// `t` without the courtesy around a command: "hey jarvis, could you please …, thanks".
    static func unwrapped(_ t: String) -> String {
        var s = Py.strip(t, " ,!")
        var changed = true
        while changed {
            changed = false
            for prefix in NativePatterns.politePrefixes where s.hasPrefix(prefix) && s.count > prefix.count {
                s = Py.strip(String(s.dropFirst(prefix.count)), " ,!")
                changed = true
            }
            for suffix in NativePatterns.politeSuffixes where s.hasSuffix(suffix) && s.count > suffix.count {
                s = Py.strip(String(s.dropLast(suffix.count)), " ,!")
                changed = true
            }
        }
        return Py.rstrip(s, "?.")
    }

    /// Typo tolerance: each word within one edit of a key word (two from seven letters), with
    /// the same first letter, becomes that word; "wi-fi" and "wi fi" become "wifi". Number words
    /// stay words: Python's golden sends "timer for five minutes" and "volume fifty" to the model.
    static func canonical(_ s: String) -> String {
        let folded = s.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "wi-fi", with: "wifi").replacingOccurrences(of: "wi fi", with: "wifi")
        // Spacing is kept as typed: Python's golden sends "what  time is it" to the model.
        let words = folded.split(separator: " ", omittingEmptySubsequences: false).map { word -> String in
            let w = String(word)
            guard w.count >= 4, !NativePatterns.keyWords.contains(w), !NativePatterns.neverFolded.contains(w) else {
                return w
            }
            let said = Array(w.unicodeScalars)
            for key in NativePatterns.keyWords where key.first == w.first {
                let limit = key.count >= 7 ? 2 : 1
                let target = Array(key.unicodeScalars)
                if abs(key.count - w.count) <= limit,
                   editDistance(said, target, atMost: limit) <= limit || swapsOnce(said, target) {
                    return key
                }
            }
            return w
        }
        return words.joined(separator: " ")
    }

    /// True when `a` is `b` with two neighbouring letters swapped ("puase", "pause").
    static func swapsOnce(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Bool {
        guard a.count == b.count else { return false }
        let diff = a.indices.filter { a[$0] != b[$0] }
        return diff.count == 2 && diff[1] == diff[0] + 1 && a[diff[0]] == b[diff[1]] && a[diff[1]] == b[diff[0]]
    }

    /// `s` is one of `phrases`, or within one edit per word (two in all from 15 characters) of
    /// one with as many words.
    static func near(_ s: String, _ phrases: [String]) -> Bool {
        if phrases.contains(s) { return true }
        let said = s.split(separator: " ", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
        return phrases.contains { phrase in
            let words = phrase.split(separator: " ").map { Array($0.unicodeScalars) }
            guard words.count == said.count else { return false }
            let allowed = phrase.unicodeScalars.count >= 15 ? 2 : 1
            var total = 0
            for (a, b) in zip(said, words) {
                let d = swapsOnce(a, b) ? 1 : editDistance(a, b, atMost: 1)
                if d > 1 { return false }
                total += d
            }
            return total <= allowed
        }
    }
}

enum NativePatterns {
    static func re(_ pattern: String) -> PyRegex { try! PyRegex(pattern) }

    static let politePrefixes = [
        "hey jarvis", "ok jarvis", "okay jarvis", "jarvis", "can you please", "could you please",
        "would you please", "can you", "could you", "would you", "will you", "please", "i want you to",
        "i'd like you to", "go ahead and", "just", "quickly", "um", "uh", "so",
    ].map { $0 + " " } + ["hey jarvis,", "jarvis,"]
    static let politeSuffixes = [" please", " for me", " jarvis", " thanks", " thank you", " mate", " sir"]

    /// Words a typo is folded into (see `FastPathRouter.canonical`).
    static let keyWords = [
        "battery", "charging", "volume", "louder", "quieter", "pause", "resume", "previous", "reminder",
        "remind", "alarm", "timer", "minutes", "minute", "seconds", "second", "network", "usage",
        "processor", "music",
    ]

    /// Real words one edit from a key word: "time" is not a typo of "timer".
    static let neverFolded: Set<String> = ["time", "times", "timed", "remains", "tracks"]


    static let ask = #"(?:what(?:'s| is)?|whats|how(?:'s| is| much)?|hows|check|tell me|show me|give me)"#
    static let device = #"(?:(?:the |my |me )?(?:mac(?:book)?|laptop|computer)(?:'s|s)? |the |my )?"#

    static let battery = [
        // An ask word, or something after "battery": "my battery" alone is Python's, and it defers.
        re("^\(ask) \(device)battery(?: level| percentage| percent| status| life| charge)?"
           + #"(?: at| left| like| looking| remaining| now| doing| on| is| then)*$"#),
        re("^\(device)battery(?: level| percentage| percent| status| life| charge)?"
           + #"(?: at| left| like| looking| remaining| now| doing| on| is| then)+$"#),
        re(#"^how much (?:battery|charge) (?:do i have|have i got|is left|left|remaining|have we got)(?: left)?$"#),
        re(#"^(?:is|am) (?:the |my )?(?:laptop|mac|macbook|computer|i|it) (?:still )?(?:charging|plugged in)$"#),
        re(#"^(?:is|am) (?:the |my )?(?:laptop|mac|macbook|computer|it )?charging$"#),
    ]
    static let wifi = [
        re(#"^(?:what(?:'s| is)?|whats|which) (?:the |my |this )?(?:wifi|network|wifi network)"#
           + #"(?: name| called| am i on| am i connected to| i'm on| im on| are we on| is this| is it| is that)?$"#),
        re(#"^(?:what(?:'s| is)?|whats) (?:the )?name of (?:the |my |this )?(?:wifi|network|wifi network)$"#),
        re(#"^(?:what|which) (?:wifi|network|wifi network) (?:am i|are we) (?:on|connected to|using)$"#),
        re(#"^am i (?:on|connected to) (?:the )?wifi$"#),
        re(#"^wifi (?:name|network|status)$"#),
    ]
    static let cpu = [
        re("^(?:\(ask) )?(?:the |my )?(?:cpu|processor)(?: usage| load| use| utilisation| utilization)?"
           + #"(?: at| like| looking| now| doing)*$"#),
        re(#"^how (?:busy|hard) is (?:the |my )?(?:cpu|processor|mac|computer|laptop)(?: working)?$"#),
    ]
    static let time = [
        "what time is it", "what's the time", "whats the time", "what is the time", "tell me the time",
        "what time is it now", "what's the time now", "whats the time now", "got the time",
        "do you have the time", "what time it is", "current time", "the time", "time please",
    ]

    static let timeWord: Set<String> = ["time", "tiem", "tme", "timee", "itme", "tmie"]

    static let volumeSet = [
        re(#"^(?:set|change|put|turn|make)? ?(?:the |my )?(?:volume|sound)(?: level)? (?:to |at |up to |down to )?"#
           + #"(\d{1,3})(?: ?%| percent)?$"#),
        re(#"^(?:set|change|put|turn) (?:the |my )?(?:volume|sound) (?:up |down )?to (\d{1,3})(?: ?%| percent)?$"#),
    ]
    static let mute = ["mute it", "mute the sound", "mute the volume", "mute audio", "mute the audio",
                       "mute sound", "mute the mac", "mute my mac", "mute volume", "mute the speakers"]
    static let louder = [
        "turn it up", "turn it up a bit", "turn the volume up", "turn up the volume", "turn the sound up", "turn up the sound",
        "volume up a bit", "make it louder", "a bit louder", "little louder", "a little louder", "louder still",
        "raise the volume", "increase the volume", "crank it up", "up the volume", "bump the volume up",
        "bump up the volume", "turn the music up", "turn up the music", "volume higher", "louder music",
    ]
    static let quieter = [
        "turn it down", "turn it down a bit", "turn the volume down", "turn down the volume", "turn the sound down",
        "turn down the sound", "volume down a bit", "make it quieter", "a bit quieter", "little quieter",
        "a little quieter", "lower the volume", "decrease the volume", "reduce the volume", "softer",
        "turn the music down", "turn down the music", "volume lower", "quieter music",
    ]
    static let pause = [
        "pause the music", "pause the song", "pause playback", "pause the track", "pause this",
        "pause this song", "stop the song", "stop playing", "stop playback", "stop the track", "hold the music",
    ]
    static let play = [
        "resume the music", "resume playback", "resume the song", "resume playing", "keep playing",
        "unpause the music", "unpause it", "play the music", "carry on playing", "start playing",
    ]
    static let next = [
        "skip the song", "skip this song", "skip this track", "skip the track", "play the next song",
        "skip to the next song", "skip to the next track", "go to the next song", "next song please",
        "play the next track", "skip ahead", "skip track",
    ]
    static let previous = [
        "go back a song", "go back a track", "play the previous song", "back one song",
        "go back one song", "go back one track", "play the previous track", "last track", "back a song",
        "go to the previous song", "go back to the previous song",
    ]

    static let reminder = [
        re(#"^(?:set|add|create|make|put in|schedule) (?:a |me a |up a |an )?reminder (?:to|that|about) (.+)$"#),
        re(#"^(?:set|add|create) (?:a )?reminder: ?(.+)$"#),
        re(#"^(?:don't|do not|dont) let me forget to (.+)$"#),
        re(#"^remind me (?:that i need to|that i have to|i need to|i have to) (.+)$"#),
    ]
    /// "set a reminder for 5pm to call mum": the time first, then the task.
    static let reminderTimeFirst = re(
        #"^(?:set|add|create|make|remind me|set me) (?:a |me a |an )?(?:reminder )?(?:for |at )"#
        + #"(\d[\d:.]*\s*(?:am|pm|a\.m\.|p\.m\.)?|tomorrow(?: morning| afternoon| evening)?|tonight|noon)"#
        + #" (?:to|that i need to|about) (.+)$"#)

    static let labelWords = ["label", "labelled", "labeled", "called", "named", "titled"]

    static let timer = [
        re(#"^(?:set|start|make|put on|run) (?:a |an |me a )?(\d+)[ -]?(second|sec|minute|min|hour|hr)s? timer$"#),
        re(#"^(\d+)[ -]?(second|sec|minute|min|hour|hr)s? timer$"#),
        re(#"^(?:set|start|make|put on) (?:a |an |me a |the )?timer (?:for |of |to )?(\d+)\s*(second|sec|minute|min|hour|hr)s?$"#),
        re(#"^(?:count|countdown|count down) (?:from )?(\d+)\s*(second|sec|minute|min|hour|hr)s?$"#),
    ]
    static let alarm = [
        re(#"^(?:set|make|create|add|put|give) (?:me |my )?(?:an? |the )?alarm (?:for |at |in )?(.*\d.*|tomorrow.*|noon|midnight)$"#),
        re(#"^alarm (?:for|at|in) (.+)$"#),
        re(#"^(?:wake me|get me up) (?:at|in|by) (.+)$"#),
    ]
}
