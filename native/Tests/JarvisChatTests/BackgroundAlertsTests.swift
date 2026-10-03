import Foundation
import JarvisChat
import JarvisCore
import Testing

/// Batch C part 1: the background lines' decisions, against Python's rules, with a fake battery,
/// a fake calendar and fixed clocks. Nothing here reads the real battery or calendar.
@Suite("Batch C background alerts", .timeLimit(.minutes(1)))
struct BackgroundAlertsTests {
    static let tz = TimeZone(identifier: "Europe/London")!
    /// 2026-10-03 00:00 in London (BST, UTC+1).
    static let midnight: Double = 1_790_982_000

    static func at(_ h: Int, _ m: Int = 0) -> Double { midnight + Double(h * 3600 + m * 60) }
    static func date(_ t: Double) -> Date { Date(timeIntervalSince1970: t) }

    @Test("the hour words match Python's _unlock_greeting")
    func greetingLines() {
        #expect(UnlockGreeting.line(hour: 9) == "Welcome back, sir. Good morning.")
        #expect(UnlockGreeting.line(hour: 12) == "Welcome back, sir. Good afternoon.")
        #expect(UnlockGreeting.line(hour: 18) == "Welcome back, sir. Good evening.")
    }

    @Test("the greeting needs more than two minutes locked, and JARVIS_GREET_UNLOCK=0 turns it off")
    func greetingRules() {
        var g = UnlockGreeting(environment: [:])
        #expect(g.enabled)
        #expect(g.unlocked(at: Self.at(9), timeZone: Self.tz) == nil)   // never locked
        g.locked(at: Self.at(9))
        #expect(g.unlocked(at: Self.at(9) + 120, timeZone: Self.tz) == nil)   // exactly two minutes
        g.locked(at: Self.at(9))
        #expect(g.unlocked(at: Self.at(9) + 121, timeZone: Self.tz) == "Welcome back, sir. Good morning.")
        #expect(g.unlocked(at: Self.at(9) + 500, timeZone: Self.tz) == nil)   // one greeting per lock
        var off = UnlockGreeting(environment: ["JARVIS_GREET_UNLOCK": "0"])
        off.locked(at: Self.at(9))
        #expect(off.unlocked(at: Self.at(10), timeZone: Self.tz) == nil)
    }

    @Test("quiet hours: off by default, a window across midnight, and JARVIS_QUIET_HOURS")
    @MainActor
    func quietHours() throws {
        let suite = "jarvis-tests-quiet-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let q = QuietHoursSetting(defaults: defaults, environment: [:])
        #expect(!q.isOn)
        #expect(q.menuTitle == "Quiet Hours (22:00–07:00)")
        #expect(!q.window.isQuiet(Self.at(23), Self.tz))   // off
        q.isOn = true
        #expect(q.window.isQuiet(Self.at(23), Self.tz))
        #expect(q.window.isQuiet(Self.at(6, 59), Self.tz))
        #expect(!q.window.isQuiet(Self.at(7), Self.tz))
        #expect(!q.window.isQuiet(Self.at(12), Self.tz))
        #expect(QuietHoursSetting(defaults: defaults, environment: [:]).isOn)   // kept
        let day = QuietHoursSetting(defaults: defaults, environment: ["JARVIS_QUIET_HOURS": "13:00-14:30"])
        #expect(day.window.isQuiet(Self.at(14, 29), Self.tz))
        #expect(!day.window.isQuiet(Self.at(14, 30), Self.tz))
        let bad = QuietHoursSetting(defaults: defaults, environment: ["JARVIS_QUIET_HOURS": "25:00-07:00"])
        #expect(bad.start == 22 * 60 && bad.end == 7 * 60)
    }

    struct FakeBattery: BatterySource {
        let reading: BatteryReading?
        func read() -> BatteryReading? { reading }
    }

    @Test("low battery: opt-in threshold, on battery only, then an hour's cooldown")
    func battery() {
        var off = LowBatteryWatch(environment: [:])
        #expect(!off.enabled)
        #expect(off.check(FakeBattery(reading: .init(percent: 5, state: .discharging)).read(), now: 0) == nil)
        var w = LowBatteryWatch(environment: ["JARVIS_LOW_BATTERY": "20"])
        #expect(w.check(.init(percent: 21, state: .discharging), now: 10_000) == nil)
        #expect(w.check(.init(percent: 15, state: .charging), now: 10_000) == nil)
        #expect(w.check(.init(percent: 15, state: .ac), now: 10_000) == nil)
        #expect(w.check(nil, now: 10_000) == nil)   // no battery
        #expect(w.check(.init(percent: 20, state: .discharging), now: 10_000)
                == "Battery at 20 percent, sir — you may want to plug in.")
        #expect(w.check(.init(percent: 12, state: .discharging), now: 10_000 + 3600) == nil)
        #expect(w.check(.init(percent: 12, state: .discharging), now: 10_000 + 3601) != nil)
    }

    struct FakeCalendar: UpcomingEventsSource {
        let events: [UpcomingEvent]?
        func events(from start: Date, to end: Date) async -> [UpcomingEvent]? {
            events?.filter { $0.start >= start.timeIntervalSince1970 && $0.start < end.timeIntervalSince1970 }
        }
    }

    @Test("meeting alerts: each event once, minutes rounded, none without the calendar")
    func meetings() async {
        var m = MeetingAlerts(environment: ["JARVIS_MEETING_ALERTS": "10"])
        #expect(m.window == 600)
        let now = Self.at(9)
        let cal = FakeCalendar(events: [UpcomingEvent(title: "Invented stand-up", start: now + 290),
                                        UpcomingEvent(title: "One-minute sync", start: now + 40),
                                        UpcomingEvent(title: "  ", start: now + 100),
                                        UpcomingEvent(title: "Later", start: now + 3600)])
        let lines = m.check(await cal.events(from: Self.date(now), to: Self.date(now + m.window)), now: now)
        #expect(lines == ["Sir, Invented stand-up starts in about 5 minutes.", "Sir, One-minute sync starts in about 1 minute."])
        #expect(m.check(await cal.events(from: Self.date(now + 120), to: Self.date(now + 120 + m.window)), now: now + 120).isEmpty)
        #expect(m.check(await FakeCalendar(events: nil).events(from: Self.date(now), to: Self.date(now + 600)), now: now).isEmpty)
        var off = MeetingAlerts(environment: [:])
        #expect(off.check([UpcomingEvent(title: "x", start: now + 60)], now: now).isEmpty)
    }

    @Test("the voiceprint reminder: once a day, 10:00 to 21:59, only without a voiceprint")
    func voiceprint() {
        let r = VoiceprintReminder()
        #expect(r.check(enrolled: false, lastDay: nil, now: Self.at(9, 59), timeZone: Self.tz) == nil)
        let due = r.check(enrolled: false, lastDay: nil, now: Self.at(10), timeZone: Self.tz)
        #expect(due?.line == VoiceprintReminder.line && due?.day == "2026-10-03")
        #expect(r.check(enrolled: false, lastDay: "2026-10-03", now: Self.at(15), timeZone: Self.tz) == nil)
        #expect(r.check(enrolled: false, lastDay: "2026-10-02", now: Self.at(21, 59), timeZone: Self.tz) != nil)
        #expect(r.check(enrolled: false, lastDay: nil, now: Self.at(22), timeZone: Self.tz) == nil)
        #expect(r.check(enrolled: true, lastDay: nil, now: Self.at(12), timeZone: Self.tz) == nil)
    }

    @Test("the timed briefing: HH:MM, next occurrence, invalid is off")
    func timedBriefing() {
        #expect(TimedBriefing(environment: [:]).minute == nil)
        let t = TimedBriefing(environment: ["JARVIS_BRIEFING_TIME": "08:30"])
        #expect(t.secondsUntilNext(now: Self.at(8), timeZone: Self.tz) == 1800)
        #expect(t.secondsUntilNext(now: Self.at(8, 30), timeZone: Self.tz) == 86_400)   // now counts as passed
        #expect(t.secondsUntilNext(now: Self.at(9), timeZone: Self.tz) == 84_600)
        for raw in ["8:3", "24:00", "noon", "08:60"] {
            let bad = TimedBriefing(environment: ["JARVIS_BRIEFING_TIME": raw])
            #expect(bad.invalid && bad.minute == nil, "\(raw)")
        }
    }
}
