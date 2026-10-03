import Foundation
import JarvisCore
import Observation

/// F1: the morning briefing. Python's `_briefing` (jarvis.py 3137-3148) joined the time, the
/// weather, today's calendar and three headlines; its daily loop spoke it at a set time, off by
/// default. Native asks the current brain for it as a turn of its own, through the usual turn and
/// the gateway's tools, so it is composed in his persona. It plays before the first turn of each
/// day after 05:00 (typed, push-to-talk or hands-free), at most once a day, and whenever the user
/// asks for it ("brief me", "morning briefing").
public enum MorningBriefing {
    /// The user row a briefing he did not ask for is shown under, and what history keeps.
    public static let shown = "Morning briefing"
    /// No briefing before this local hour.
    public static let startHour = 5

    /// What asks for a briefing on demand: Python's phrases (jarvis.py 4486) without its greetings.
    static let phrases: Set<String> = ["brief me", "briefing", "daily briefing", "morning briefing",
                                       "my briefing", "what's my briefing", "whats my briefing",
                                       "my morning briefing", "give me my briefing", "give me my morning briefing"]

    /// True when `text` is a request for the briefing: one of `phrases`, ignoring case,
    /// punctuation and a "jarvis" or "please" at either end.
    public static func isRequest(_ text: String) -> Bool {
        var kept = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            let isWordPart = CharacterSet.letters.contains(scalar) || scalar == "'"
            kept.append(isWordPart ? scalar : " ")
        }
        var words = String(kept).split(separator: " ").map(String.init)
        let fillers: Set<String> = ["jarvis", "please", "hey"]
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        while let last = words.last, fillers.contains(last) { words.removeLast() }
        return phrases.contains(words.joined(separator: " "))
    }

    /// What the brain is asked: look up the day with its tools and give one short spoken
    /// paragraph. `agenda` is what JARVIS has set for later today (`agendaLine`); there is no
    /// tool that lists it.
    public static func request(agenda: [String]) -> String {
        "[Morning briefing. Before anything else, give the user his rundown for today. Look it up with your "
            + "tools: get_time for the time and date, get_weather for today's weather, get_calendar for today's "
            + "events and get_news for the headlines. Then answer in one short spoken paragraph of about 60 to 90 "
            + "words, in your usual manner: the time and date, today's weather, today's calendar events, the "
            + "reminders and alarms below, and three news headlines. Leave out any part a tool could not supply, "
            + "without apologising. No lists or markdown: it will be read aloud.]\n"
            + "Reminders and alarms due later today: " + (agenda.isEmpty ? "none." : agenda.joined(separator: "; ") + ".")
    }

    /// One agenda item: "6:00 PM, reminder: call a friend".
    public static func agendaLine(_ entry: AlarmEntry, timeZone: TimeZone) -> String {
        let time = Py.lstrip(PyTime.strftime("%I:%M %p", entry.time, timeZone: timeZone), "0")
        let label = Py.strip(entry.label)
        return "\(time), \(entry.kind.rawValue)" + (label.isEmpty ? "" : ": \(label)")
    }

    /// The local day, "2026-10-03", the record's form.
    static func day(_ now: Double, _ timeZone: TimeZone) -> String {
        PyTime.strftime("%Y-%m-%d", Date(timeIntervalSince1970: now), timeZone: timeZone)
    }
}

/// The menus' "Morning Briefing" toggle (on by default), and the day of the last briefing, both
/// in UserDefaults so a relaunch neither replays nor forgets it.
@MainActor
@Observable
public final class MorningBriefingSetting {
    /// The UserDefaults keys.
    public static let defaultsKey = "morningBriefing"
    public static let lastDayKey = "morningBriefingLastDay"
    public static let menuTitle = "Morning Briefing"

    public var isOn: Bool {
        didSet { defaults.set(isOn, forKey: Self.defaultsKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: any JarvisClock
    @ObservationIgnored private let timeZone: TimeZone

    public init(defaults: UserDefaults = FileLearningConsent.appDefaults, clock: any JarvisClock = SystemClock(),
                timeZone: TimeZone = .autoupdatingCurrent) {
        self.defaults = defaults
        self.clock = clock
        self.timeZone = timeZone
        isOn = defaults.object(forKey: Self.defaultsKey) == nil ? true : defaults.bool(forKey: Self.defaultsKey)
    }

    /// The local day of the last briefing, nil before the first.
    public var lastDay: String? { defaults.string(forKey: Self.lastDayKey) }

    /// True, and today recorded, when the briefing should play before this turn: switched on, at
    /// or after 05:00 local time, and none yet today.
    public func claimIfDue() -> Bool {
        let now = clock.now()
        let hour = Int(PyTime.strftime("%H", Date(timeIntervalSince1970: now), timeZone: timeZone)) ?? 0
        let today = MorningBriefing.day(now, timeZone)
        guard isOn, hour >= MorningBriefing.startHour, lastDay != today else { return false }
        defaults.set(today, forKey: Self.lastDayKey)
        return true
    }

    /// A briefing asked for: today has had one, so none plays unasked.
    public func recordToday() {
        defaults.set(MorningBriefing.day(clock.now(), timeZone), forKey: Self.lastDayKey)
    }
}
