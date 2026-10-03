import AppKit
import EventKit
import Foundation
import IOKit.ps
import JarvisChat
import JarvisCore

/// Batch C part 1: the timers and notifications behind `BackgroundAlerts`: the unlock greeting
/// (loginwindow's distributed lock notifications, as Python's `_install_lock_observer`), the
/// low-battery warning, meeting alerts, the voiceprint reminder and the briefing at a set time.
/// Lines go out through `announce` (the ReminderAnnouncer: spoken after any reply being written,
/// or posted in the chat without a voice). Quiet hours drop every line but the unlock greeting.
@MainActor
final class BackgroundLoops {
    struct Hooks {
        var announce: @MainActor (String) -> Void
        var enrolled: @MainActor () -> Bool
        var briefing: @MainActor () -> Void
        var log: @MainActor (String) -> Void
    }

    private let environment: [String: String]
    private let quiet: QuietWindow
    private let battery: any BatterySource
    private let calendar: any UpcomingEventsSource
    private let defaults: UserDefaults
    private let hooks: Hooks
    private let timeZone: TimeZone = .autoupdatingCurrent
    private var greeting: UnlockGreeting
    private var batteryWatch: LowBatteryWatch
    private var meetings: MeetingAlerts
    private var tasks: [Task<Void, Never>] = []
    private var observers: [NSObjectProtocol] = []

    init(environment: [String: String], quiet: QuietWindow, battery: any BatterySource = PowerSourceBattery(),
         calendar: any UpcomingEventsSource = EventKitUpcoming(), defaults: UserDefaults = FileLearningConsent.appDefaults,
         hooks: Hooks) {
        self.environment = environment
        self.quiet = quiet
        self.battery = battery
        self.calendar = calendar
        self.defaults = defaults
        self.hooks = hooks
        greeting = UnlockGreeting(environment: environment)
        batteryWatch = LowBatteryWatch(environment: environment)
        meetings = MeetingAlerts(environment: environment)
    }

    private var now: Double { Date().timeIntervalSince1970 }

    func start() {
        startLockObserver()
        if batteryWatch.enabled {
            tasks.append(loop(every: LowBatteryWatch.interval) { [weak self] in
                guard let self else { return }
                if let line = self.batteryWatch.check(self.battery.read(), now: self.now) { self.say(line) }
            })
        }
        if meetings.enabled {
            let calendar = calendar, window = meetings.window
            tasks.append(loop(every: MeetingAlerts.interval) { [weak self] in
                let start = Date()
                let events = await calendar.events(from: start, to: start.addingTimeInterval(window))
                guard let self else { return }
                for line in self.meetings.check(events, now: self.now) { self.say(line) }
            })
        }
        // Python waits two minutes for startup to settle before its first check.
        tasks.append(loop(every: VoiceprintReminder.interval, firstAfter: 120) { [weak self] in
            guard let self else { return }
            let last = self.defaults.string(forKey: VoiceprintReminder.defaultsKey)
            guard !self.quiet.isQuiet(self.now, self.timeZone),
                  let due = VoiceprintReminder().check(enrolled: self.hooks.enrolled(), lastDay: last,
                                                      now: self.now, timeZone: self.timeZone) else { return }
            self.defaults.set(due.day, forKey: VoiceprintReminder.defaultsKey)
            self.hooks.announce(due.line)
        })
        let timed = TimedBriefing(environment: environment)
        if timed.invalid {
            hooks.log("background: invalid JARVIS_BRIEFING_TIME (want \"HH:MM\"); the timed briefing is off")
        } else if timed.minute != nil {
            tasks.append(Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, let wait = timed.secondsUntilNext(now: self.now, timeZone: self.timeZone) else { return }
                    try? await Task.sleep(for: .seconds(max(1, wait)), clock: .suspending)
                    if Task.isCancelled { return }
                    if self.quiet.isQuiet(self.now, self.timeZone) {
                        self.hooks.log("background: the timed briefing fell in quiet hours; skipped")
                    } else {
                        self.hooks.briefing()
                    }
                    try? await Task.sleep(for: .seconds(61), clock: .suspending)
                }
            })
        }
        hooks.log("background: unlock greeting \(greeting.enabled ? "on" : "off"), low battery "
                  + (batteryWatch.enabled ? "at \(batteryWatch.threshold)%" : "off") + ", meeting alerts "
                  + (meetings.enabled ? "\(meetings.leadMinutes) min ahead" : "off") + ", timed briefing "
                  + (timed.minute != nil ? "on" : "off"))
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        let center = DistributedNotificationCenter.default()
        observers.forEach { center.removeObserver($0) }
        observers = []
    }

    /// A line, unless quiet hours hold it back.
    private func say(_ line: String) {
        guard !quiet.isQuiet(now, timeZone) else {
            hooks.log("background: a line fell in quiet hours; dropped")
            return
        }
        hooks.announce(line)
    }

    private func loop(every interval: Double, firstAfter: Double? = nil,
                      _ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(firstAfter ?? interval), clock: .suspending)
            while !Task.isCancelled {
                await body()
                try? await Task.sleep(for: .seconds(interval), clock: .suspending)
            }
        }
    }

    private func startLockObserver() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.greeting.locked(at: self.now)
            }
        })
        observers.append(center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self, let line = self.greeting.unlocked(at: self.now, timeZone: self.timeZone) else { return }
                self.hooks.announce(line)
            }
        })
    }
}

/// The battery through IOKit's power sources (what `pmset -g batt` reads); nil without one.
struct PowerSourceBattery: BatterySource {
    func read() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let onAC = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let charged = d[kIOPSIsChargedKey] as? Bool ?? false
            let state: BatteryReading.State = charged ? .charged : charging ? .charging : onAC ? .ac : .discharging
            return BatteryReading(percent: percent, state: state)
        }
        return nil
    }
}

/// Meeting alerts' calendar until batch B's calendar tool lands: EventKit, read only once full
/// access has been granted (this never asks for it; batch B's tool and setup do).
struct EventKitUpcoming: UpcomingEventsSource {
    func events(from start: Date, to end: Date) async -> [UpcomingEvent]? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return nil }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map {
            UpcomingEvent(title: $0.title ?? "", start: $0.startDate.timeIntervalSince1970, allDay: $0.isAllDay)
        }
    }
}
