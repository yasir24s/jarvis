import Foundation
import JarvisCore

// od/phase2 item 3: sentence vectors alone put the right tool in the first ten for about half
// the scorecard's requests ("Is the laptop charging" ranked get_battery 30th). Words the user
// says name most tools outright, so a word match goes ahead of the vectors, which then order
// what is left. Nothing here is logged.

/// Words and phrases that point at a tool. A word matches a word of the request that starts
/// with it ("remind" matches "reminders"), or is one typo away from it when it has five or more
/// letters. A phrase (it has a space) matches anywhere in the request, on word boundaries.
public enum LocalToolKeywords {
    public static let table: [String: [String]] = [
        "get_time": ["time", "clock", "date", "what day", "o'clock"],
        "get_battery": ["about to die", "dying", "running out", "power", "battery", "charging", "charger", "charge", "plugged in", "power left", "batt"],
        "get_cpu_usage": ["cpu", "processor", "busy", "load", "sluggish", "slow", "fans"],
        "get_wifi_status": ["wifi", "wi-fi", "network", "internet", "connected", "ssid", "online"],
        "get_location": ["where am i", "location", "my address", "which city", "what town"],
        "get_weather": ["weather", "rain", "raining", "umbrella", "temperature", "forecast", "sunny", "cold",
                        "warm", "jacket", "snow", "degrees"],
        "get_news": ["news", "headlines", "happening in the world", "current events"],
        "get_calendar": ["calendar", "schedule", "meetings", "agenda", "diary", "what's on", "appointments",
                         "busy today", "free today", "free tomorrow"],
        "create_event": ["calendar", "schedule", "meeting", "appointment", "book", "event", "pencil in",
                         "put in my diary", "lunch with", "dinner with"],
        "get_messages": ["texted", "messaged", "replied", "heard back", "messages", "texts", "imessage", "who texted", "who messaged", "inbox", "unread"],
        "send_message": ["message", "text", "msg", "imessage", "tell", "let know", "send", "whatsapp"],
        "send_email": ["email", "e-mail", "mail", "send"],
        "find_contact": ["contact", "number", "phone", "email address", "call", "ring"],
        "set_volume": ["volume", "louder", "quieter", "mute", "unmute", "sound", "loud", "quiet", "turn up",
                       "turn down", "turn it up", "turn it down"],
        "set_brightness": ["brightness", "brighter", "dimmer", "dim", "screen", "bright", "dark", "eyes"],
        "music_play": ["play", "song", "music", "album", "playlist", "track", "listen", "artist", "tune"],
        "music_control": ["pause", "resume", "skip", "next", "previous", "shuffle", "repeat", "stop the music",
                          "back a song", "play", "music", "track", "song", "unpause"],
        "music_now_playing": ["playing", "this song", "song is this", "track is this", "who sings", "now playing",
                              "what song"],
        "music_search": ["find song", "search music", "search for song", "songs by", "music library",
                         "do i have", "albums by", "in my library"],
        "find_song_by_lyrics": ["lyrics", "goes like", "song that goes", "words", "the one that goes"],
        "set_reminder": ["remind", "reminder", "nudge", "don't let me forget", "forget", "remember to",
                         "ping me", "later", "tonight", "tomorrow"],
        "set_alarm": ["alarm", "wake", "wake me", "get me up", "morning"],
        "make_note": ["note", "jot", "write down", "notes", "memo", "take down", "scribble"],
        "notify": ["notify", "notification", "alert", "banner", "pop up"],
        "web_search": ["search", "look up", "google", "who is", "what is", "latest", "price"],
        "search_memory": ["remember", "said", "told you", "last time", "earlier", "we talked", "did i"],
        "forget_memory": ["forget", "delete memory", "erase", "wipe", "remove that memory", "don't remember"],
        "correct_memory": ["actually", "correct", "wrong", "not right", "mistake", "update", "fix that"],
        "restore_memory": ["restore", "undo", "bring back", "unforget", "undelete", "put back"],
        "find_files": ["video", "photo", "where's", "pictures", "find", "file", "files", "document", "pdf", "where is", "folder", "recent"],
        "search_files": ["where did i save", "saved", "search", "files", "containing", "mention", "documents", "inside"],
        "read_file": ["read", "contents", "what's in", "what does it say", "open the file", "show me the file"],
        "write_file": ["write", "create a file", "create file", "new file", "make a file", "save as"],
        "move_file": ["move", "rename", "file", "folder", "~/", "into"],
        "delete_file": ["delete", "remove", "bin", "trash", "get rid", "erase", "~/", ".txt", ".png", ".pdf",
                        ".jpg", "file"],
        "run_command": ["browser", "website", ".com", "bring up", "url", "terminal", "command", "shell", "run", "bash", "zsh", "open", "launch", "start", "brew",
                        "git", "ls", "pop open", "fire up", "app"],
        "run_applescript": ["applescript", "script", "hide", "window", "windows", "finder", "app", "apps",
                            "minimise", "minimize", "close", "quit"],
        "run_shortcut": ["plug", "heating", "thermostat", "kettle", "lamp", "blinds", "shortcut", "scene", "run", "start", "lights", "routine", "home", "mode", "activate",
                         "trigger"],
        "list_shortcuts": ["shortcuts", "scenes", "routines", "automations", "smart home", "which", "list"],
        "find_apps": ["app", "apps", "installed", "application", "applications", "have i got", "do i have"],
        "open_settings": ["settings", "preferences", "privacy", "microphone", "camera", "permissions", "pane",
                          "system settings", "take me to", "bluetooth settings"],
        "system_control": ["hidden files", "wifi", "bluetooth", "dark mode", "do not disturb", "focus", "lock", "sleep",
                           "night shift", "airdrop", "turn on", "turn off", "switch on", "switch off", "toggle",
                           "enable", "disable", "mirror", "display"],
        "run_diagnostics": ["once-over", "how's everything", "system check", "diagnostics", "health", "healthy", "check up", "checkup", "running ok", "disk",
                            "memory", "ram", "storage", "system report", "doing ok", "okay"],
        "take_screenshot": ["screenshot", "screen grab", "capture", "snap", "screen shot", "picture of"],
        "see_screen": ["screen", "see", "looking at", "on my screen", "this window", "what's this", "read this"],
        "read_clipboard": ["clipboard", "copied", "paste", "pasted", "just copied"],
        "summarize_page": ["summarise", "summarize", "summary", "page", "article", "tl;dr", "tldr", "gist",
                           "website", "this page"],
        "type_text": ["take this down", "type out", "dictate", "type", "typing", "write out", "enter", "fill in"],
        "personality_note": ["prefer", "in future", "shorter", "longer answers", "from now on", "stop calling", "call me", "be more", "be less", "a bit more",
                             "a bit less", "don't be", "personality", "tone", "blunt", "formal", "sarcastic",
                             "stop saying", "less chatty", "always", "never"],
        "personality_rewrite": ["personality", "rewrite", "persona", "character", "who you are", "reset your",
                                "start over", "become"],
    ]

    /// The request's words (lower-cased, curly apostrophes folded) and the padded text phrases
    /// are looked for in.
    struct Request {
        let text: String
        let words: [String]

        init(_ raw: String) {
            let lowered = raw.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
                .replacingOccurrences(of: "\u{2018}", with: "'")
            words = lowered.split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "-") }
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
                .filter { !$0.isEmpty }
            text = " " + words.joined(separator: " ") + " " + lowered + " "
        }
    }

    /// How many of `tool`'s keys `request` matches.
    public static func hits(_ tool: String, in text: String) -> Int {
        hits(tool, in: Request(text))
    }

    static func hits(_ tool: String, in request: Request) -> Int {
        guard let keys = table[tool] else { return 0 }
        var n = 0
        for key in keys where matches(key, request) { n += 1 }
        return n
    }

    static func matches(_ key: String, _ request: Request) -> Bool {
        // A file extension or a path: anywhere in the text as typed.
        if key.hasPrefix(".") || key.contains("/") { return request.text.contains(key) }
        // A phrase: starts on a word boundary and ends on one, or with a plural "s".
        if key.contains(" ") || key.contains("'") || key.contains("-") {
            var from = request.text.startIndex
            while let r = request.text.range(of: " " + key, range: from..<request.text.endIndex) {
                let next = request.text[r.upperBound...].first
                if next.map({ !$0.isLetter || $0 == "s" }) ?? true { return true }
                from = r.upperBound
            }
            return false
        }
        let k = Array(key.unicodeScalars)
        for word in request.words {
            if word == key { return true }
            if key.count >= 4 && word.hasPrefix(key) { return true }
            // "plaay": a four-letter key with one letter too many.
            if key.count == 4 && word.count == 5 && word.first == key.first,
               FastPathTypos.distance(Array(word.unicodeScalars), k) <= 1 {
                return true
            }
            if key.count >= 5 && abs(word.count - key.count) <= 1 && word.first == key.first,
               FastPathTypos.distance(Array(word.unicodeScalars), k) <= 1 {
                return true
            }
        }
        return false
    }
}

/// Levenshtein distance with an adjacent swap counted as one edit, capped at 2.
enum FastPathTypos {
    static func distance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a == b { return 0 }
        if abs(a.count - b.count) > 1 { return 2 }
        if a.count == b.count {
            let diff = a.indices.filter { a[$0] != b[$0] }
            if diff.count == 1 { return 1 }
            if diff.count == 2, diff[1] == diff[0] + 1, a[diff[0]] == b[diff[1]], a[diff[1]] == b[diff[0]] { return 1 }
            return 2
        }
        let (long, short) = a.count > b.count ? (a, b) : (b, a)
        for skip in long.indices {
            var rest = long
            rest.remove(at: skip)
            if rest == short { return 1 }
        }
        return 2
    }
}
