import Foundation
import JarvisCore
import Observation

// Batch C part 1: what Python JARVIS said on his own, outside a turn: the unlock greeting, the
// low-battery warning, meeting alerts, the voiceprint reminder and the briefing at a set time.
// Each is a small decision here (Foundation only, so it tests headless); the app owns the
// timers, the notifications and the voice (`BackgroundLoops` in JarvisApp). Quiet hours, a new
// setting, hold back every background line while they last.

/// The local hour and minute of `now`.
func localClock(_ now: Double, _ timeZone: TimeZone) -> (hour: Int, minute: Int) {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let c = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: now))
    return (c.hour ?? 0, c.minute ?? 0)
}

/// "HH:MM" as minutes after midnight; nil when it is not a valid 24-hour time.
public func minutesOfDay(_ hhmm: String) -> Int? {
    let parts = hhmm.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m),
          parts[1].count == 2 else { return nil }
    return h * 60 + m
}

// MARK: - Unlock greeting

/// Python's unlock greeting (jarvis.py 532-556): "Welcome back, sir. Good <part of day>." when
/// the Mac is unlocked after being locked for more than two minutes. On unless
/// `JARVIS_GREET_UNLOCK=0`.
public struct UnlockGreeting: Sendable {
    public static let minimumAway: Double = 120
    public let enabled: Bool
    private var lockedAt: Double?

    public init(environment: [String: String]) {
        enabled = environment["JARVIS_GREET_UNLOCK", default: "1"] != "0"
    }

    public mutating func locked(at now: Double) {
        lockedAt = now
    }

    /// The greeting to speak on unlock, or nil.
    public mutating func unlocked(at now: Double, timeZone: TimeZone) -> String? {
        defer { lockedAt = nil }
        guard enabled, let lockedAt, now - lockedAt > Self.minimumAway else { return nil }
        return Self.line(hour: localClock(now, timeZone).hour)
    }

    public static func line(hour: Int) -> String {
        let part = hour < 12 ? "morning" : hour < 18 ? "afternoon" : "evening"
        return "Welcome back, sir. Good \(part)."
    }
}

// MARK: - Quiet hours

/// Batch C part 1: quiet hours, when JARVIS raises nothing on his own (battery, meetings, the
/// voiceprint reminder, the timed briefing; a line due then is dropped, not saved for later).
/// Off by default. The window is `JARVIS_QUIET_HOURS` ("22:00-07:00") when set and valid, else
/// 22:00 to 07:00. A window that crosses midnight is fine; start == end is never quiet.
@MainActor
@Observable
public final class QuietHoursSetting {
    public static let defaultsKey = "quietHours"
    public static let defaultWindow = "22:00-07:00"
    public var isOn: Bool {
        didSet {
            defaults.set(isOn, forKey: Self.defaultsKey)
            shared.set(isOn)
        }
    }
    public let start: Int
    public let end: Int
    /// The same switch for the loops off the main actor.
    @ObservationIgnored public let shared: SharedFlag
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = FileLearningConsent.appDefaults,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        let window = Self.parse(environment["JARVIS_QUIET_HOURS"] ?? "") ?? Self.parse(Self.defaultWindow)!
        (start, end) = window
        let on = defaults.bool(forKey: Self.defaultsKey)
        isOn = on
        shared = SharedFlag(on)
    }

    public var menuTitle: String {
        "Quiet Hours (\(Self.format(start))–\(Self.format(end)))"
    }

    public nonisolated static func parse(_ text: String) -> (Int, Int)? {
        let parts = text.split(separator: "-")
        guard parts.count == 2, let a = minutesOfDay(String(parts[0])), let b = minutesOfDay(String(parts[1])) else { return nil }
        return (a, b)
    }

    public nonisolated static func format(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// A value the loops can hold off the main actor.
    public var window: QuietWindow { QuietWindow(start: start, end: end, on: shared) }
}

/// Quiet hours as the background loops ask about them.
public struct QuietWindow: Sendable {
    public let start: Int
    public let end: Int
    public let on: SharedFlag

    public init(start: Int, end: Int, on: SharedFlag) {
        self.start = start
        self.end = end
        self.on = on
    }

    public func isQuiet(_ now: Double, _ timeZone: TimeZone) -> Bool {
        guard on.isOn, start != end else { return false }
        let (h, m) = localClock(now, timeZone)
        let t = h * 60 + m
        return start < end ? (t >= start && t < end) : (t >= start || t < end)
    }
}

// MARK: - Low battery

/// The battery as `pmset -g batt` reports it: a percentage and a state word.
public struct BatteryReading: Sendable, Equatable {
    public enum State: String, Sendable { case charging, charged, ac, discharging, unknown }
    public var percent: Int
    public var state: State

    public init(percent: Int, state: State) {
        self.percent = percent
        self.state = state
    }
}

/// Reads the battery; nil on a Mac without one. The app's is IOKit's power sources; tests use a fake.
public protocol BatterySource: Sendable {
    func read() -> BatteryReading?
}

/// Python's low_battery_watch_loop (jarvis.py 3800-3821): every five minutes, on battery at or
/// under `JARVIS_LOW_BATTERY` percent, one warning, then none for an hour. Off when the variable
/// is unset or 0, as in Python.
public struct LowBatteryWatch: Sendable {
    public static let interval: Double = 300
    public static let cooldown: Double = 3600
    public let threshold: Int
    private var lastWarned: Double = 0

    public init(environment: [String: String]) {
        threshold = Int(environment["JARVIS_LOW_BATTERY"] ?? "0") ?? 0
    }

    public var enabled: Bool { threshold > 0 }

    public mutating func check(_ reading: BatteryReading?, now: Double) -> String? {
        guard enabled, let reading, ![.charging, .charged, .ac].contains(reading.state) else { return nil }
        guard reading.percent <= threshold, now - lastWarned > Self.cooldown else { return nil }
        lastWarned = now
        return "Battery at \(reading.percent) percent, sir — you may want to plug in."
    }
}

// MARK: - Meeting alerts

/// An event starting soon, from the calendar.
public struct UpcomingEvent: Sendable, Equatable {
    public var title: String
    public var start: Double     // epoch seconds
    public var allDay: Bool

    public init(title: String, start: Double, allDay: Bool = false) {
        self.title = title
        self.start = start
        self.allDay = allDay
    }
}

/// The calendar as meeting alerts read it: every event overlapping `start..<end`; nil when the
/// calendar cannot be read (no permission). Shaped like parity batch B's `CalendarStoring.events`
/// (its `CalendarEntry` has the same title, start and allDay), so its `LiveCalendar` can back it
/// once both are on one branch. The app's stand-in reads EventKit only once access is granted.
public protocol UpcomingEventsSource: Sendable {
    func events(from start: Date, to end: Date) async -> [UpcomingEvent]?
}

/// Python's meeting_alert_loop (jarvis.py 3823-3887): every two minutes, each event starting
/// within `JARVIS_MEETING_ALERTS` minutes is announced once ("Sir, <title> starts in about
/// <n> minutes."). Off when the variable is unset or 0. Announced keys are kept two hours.
public struct MeetingAlerts: Sendable {
    public static let interval: Double = 120
    public let leadMinutes: Int
    private var announced: [String: Double] = [:]

    public init(environment: [String: String]) {
        leadMinutes = Int(environment["JARVIS_MEETING_ALERTS"] ?? "0") ?? 0
    }

    public var enabled: Bool { leadMinutes > 0 }
    public var window: Double { Double(leadMinutes) * 60 }

    public mutating func check(_ events: [UpcomingEvent]?, now: Double) -> [String] {
        guard enabled, let events else { return [] }
        var lines: [String] = []
        for e in events where e.start >= now {
            let title = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = "\(title)@\(Int(e.start / 60))"
            guard announced[key] == nil else { continue }
            announced[key] = now
            let mins = max(1, Int((e.start - now) / 60 + 0.5))
            lines.append("Sir, \(title) starts in about \(mins) minute\(mins == 1 ? "" : "s").")
        }
        announced = announced.filter { $0.value > now - 7200 }
        return lines
    }
}

// MARK: - Voiceprint reminder

/// Python's proactive_loop reminder (jarvis.py 2535-2566): hourly, while there is no voiceprint,
/// once a day between 10:00 and 21:59. The day is kept in the app's defaults (Python kept it in
/// proactive.json).
public struct VoiceprintReminder: Sendable {
    public static let interval: Double = 3600
    public static let defaultsKey = "voiceprintReminderDay"
    public static let line = "A housekeeping note, sir — I still don't have your voiceprint, so I can't yet tell "
        + "your voice from the television. Say 'learn my voice' whenever convenient."

    public init() {}

    /// The line when due, with the day to record; nil otherwise.
    public func check(enrolled: Bool, lastDay: String?, now: Double, timeZone: TimeZone) -> (line: String, day: String)? {
        let hour = localClock(now, timeZone).hour
        let today = MorningBriefing.day(now, timeZone)
        guard !enrolled, lastDay != today, (10...21).contains(hour) else { return nil }
        return (Self.line, today)
    }
}

// MARK: - The briefing at a set time

/// Python's daily_briefing_loop (jarvis.py 3767-3787): the briefing once a day at
/// `JARVIS_BRIEFING_TIME` ("HH:MM"); unset is off, and an invalid value is off with a log line.
/// Native also keeps F1's briefing before the first turn of the day; the timed one counts as
/// that day's briefing.
public struct TimedBriefing: Sendable {
    public let minute: Int?
    public let invalid: Bool

    public init(environment: [String: String]) {
        let raw = (environment["JARVIS_BRIEFING_TIME"] ?? "").trimmingCharacters(in: .whitespaces)
        minute = raw.isEmpty ? nil : minutesOfDay(raw)
        invalid = !raw.isEmpty && minute == nil
    }

    /// Seconds from `now` to the next occurrence (tomorrow's when today's has passed or is now).
    public func secondsUntilNext(now: Double, timeZone: TimeZone) -> Double? {
        guard let minute else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: now)
        // From the start of the day: `date(bySettingHour:of:)` searches forward from `date` itself.
        let day = calendar.startOfDay(for: date)
        guard var target = calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
                                         matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
        else { return nil }
        if target <= date { target = calendar.date(byAdding: .day, value: 1, to: target) ?? target.addingTimeInterval(86_400) }
        return target.timeIntervalSince(date)
    }
}
