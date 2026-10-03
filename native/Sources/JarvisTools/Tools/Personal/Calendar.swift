@preconcurrency import EventKit
import Foundation
import JarvisCore

/// One event as `_ek_events` returns it: the title ("Untitled" when it has none), the start
/// as a Unix time, and whether it lasts all day.
struct CalendarEntry: Sendable, Equatable {
    let title: String
    let start: Double
    let allDay: Bool
}

/// The calendar through EventKit. Both calls answer nil when EventKit cannot be used (no full
/// access), so the tools fall back to Python's Calendar AppleScript, as `_ek_events` and
/// `_ek_create` returning None do.
protocol CalendarStoring: Sendable {
    /// Every event overlapping `start..<end`, sorted by start (stable).
    func events(from start: Date, to end: Date) async -> [CalendarEntry]?
    /// True when the event was saved, false when EventKit refused it.
    func create(title: String, start: Date, seconds: Int) async -> Bool?
}

/// What a platform has before the app gives it EventKit: none, so the AppleScript path runs
/// (over the platform's script runner, a fake in tests).
struct NoCalendar: CalendarStoring {
    func events(from start: Date, to end: Date) async -> [CalendarEntry]? { nil }
    func create(title: String, start: Date, seconds: Int) async -> Bool? { nil }
}

/// One `EKEventStore` for the process (`_ek()`), asking for full access the first time
/// (NSCalendarsFullAccessUsageDescription), waiting at most 12 seconds, as `_ek_authorized`.
actor LiveCalendar: CalendarStoring {
    static let shared = LiveCalendar()
    private let store = EKEventStore()

    private func authorized() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .restricted, .denied: return false
        default: break
        }
        let store = self.store
        let granted = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await store.requestFullAccessToEvents()) ?? false }
            group.addTask { try? await Task.sleep(for: .seconds(12)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        return granted || EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func events(from start: Date, to end: Date) async -> [CalendarEntry]? {
        guard await authorized() else { return nil }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let entries = store.events(matching: predicate).map { event in
            CalendarEntry(title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled",
                          start: event.startDate?.timeIntervalSince1970 ?? 0, allDay: event.isAllDay)
        }
        return entries.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
    }

    func create(title: String, start: Date, seconds: Int) async -> Bool? {
        guard await authorized() else { return nil }
        guard let calendar = store.defaultCalendarForNewEvents else { return false }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(Double(seconds))
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent)
            return true
        } catch {
            return false
        }
    }
}

/// `get_calendar`, Python's `_calendar_today` (jarvis.py 3100-3136): today's events from local
/// midnight for one day, through EventKit, else Calendar's AppleScript (with one cold-start retry).
struct GetCalendar: ToolImpl {
    static let name = "get_calendar"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let script = "set output to \"\"\n"
        + "set startD to (current date) - (time of (current date))\n"
        + "set endD to startD + (1 * days)\n"
        + "tell application \"Calendar\"\n"
        + "  launch\n"
        + "  repeat with c in calendars\n"
        + "    repeat with e in (every event of c whose start date ≥ startD and start date < endD)\n"
        + "      set output to output & (summary of e) & \" at \" & (time string of (start date of e)) & \". \"\n"
        + "    end repeat\n"
        + "  end repeat\n"
        + "end tell\nreturn output"
    let calendar: any CalendarStoring
    let scripts: AppleScriptRunner
    let clock: any JarvisClock
    let timeZone: TimeZone
    let pause: @Sendable (Double) async -> Void

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: Date(timeIntervalSince1970: clock.now()))
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        if let events = await calendar.events(from: start, to: end) {
            if events.isEmpty { return .text("You have nothing on your calendar today, sir.") }
            let parts = events.map { e in
                e.allDay ? "\(e.title), all day"
                    : "\(e.title) at \(AlarmTime.spoken(Date(timeIntervalSince1970: e.start), timeZone))"
            }
            return .text("Today's schedule. " + parts.joined(separator: ". ") + ".")
        }
        var out = await scripts.run(Self.script)
        if AppleScriptText.errored(out) {
            await AppleScriptText.ensureRunning("Calendar", scripts: scripts, pause: pause)
            out = await scripts.run(Self.script)
        }
        if AppleScriptText.errored(out) {
            return .text("I couldn't reach Calendar, sir — you may need to grant JARVIS calendar "
                + "access in System Settings, Privacy and Security.")
        }
        if out.isEmpty || Py.eq(Py.strip(out), "Done.") { return .text("You have nothing on your calendar today, sir.") }
        return .text("Today's schedule. " + out)
    }
}

/// `int(v)` for the JSON values a tool can be given, saturating far past any real duration
/// rather than overflowing. Throws Python's TypeError or ValueError text.
enum PyInt {
    static let limit = 1 << 40

    static func value(_ v: JSONValue) throws -> Int {
        switch v {
        case .bool(let b): return b ? 1 : 0
        case .int(let n): return Int(max(Int64(-limit), min(Int64(limit), n)))
        case .bigInt(let s): return s.hasPrefix("-") ? -limit : limit
        case .double(let d):
            guard d.isFinite else {
                throw PyError(description: d.isNaN ? "cannot convert float NaN to integer"
                              : "cannot convert float infinity to integer")
            }
            return Int(max(Double(-limit), min(Double(limit), d.rounded(.towardZero))))
        case .string(let raw):
            var scalars = Array(Py.strip(raw).unicodeScalars)
            var negative = false
            if scalars.first == "-" || scalars.first == "+" { negative = scalars.removeFirst() == "-" }
            var result = 0, digits = 0, separator = false
            for scalar in scalars {
                if scalar == "_", digits > 0, !separator { separator = true; continue }
                guard scalar.properties.numericType == .decimal, let n = scalar.properties.numericValue else {
                    throw PyError(description: "invalid literal for int() with base 10: \(PyRepr.string(raw))")
                }
                result = min(limit, result * 10 + Int(n)); digits += 1; separator = false
            }
            guard digits > 0, !separator else {
                throw PyError(description: "invalid literal for int() with base 10: \(PyRepr.string(raw))")
            }
            return negative ? -result : result
        default:
            throw PyError(description: "int() argument must be a string, a bytes-like object or a real number, "
                + "not '\(PyArgs.typeName(v))'")
        }
    }
}

/// `create_event`, Python's `_create_event` (jarvis.py 3259-3290). Native asks first: the event is
/// written only after the user confirms (Python wrote it at once; D-41, DEVIATIONS).
struct CreateEvent: ToolImpl {
    static let name = "create_event"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let calendar: any CalendarStoring
    let scripts: AppleScriptRunner
    let clock: any JarvisClock
    let timeZone: TimeZone
    let pause: @Sendable (Double) async -> Void

    static func script(title: String, start: Int, end: Int) -> String {
        "tell application \"Calendar\"\n"
            + "  launch\n"
            + "  set c to first calendar whose writable is true\n"
            + "  tell c to make new event with properties {summary:\"\(AppleScriptText.escape(title))\", "
            + "start date:((current date) + \(start)), end date:((current date) + \(end))}\n"
            + "end tell"
    }

    /// `dt.strftime('%A at %I:%M %p').replace(' 0', ' ')`.
    static func spoken(_ date: Date, _ timeZone: TimeZone) -> String {
        PyTime.strftime("%A at %I:%M %p", date, timeZone: timeZone).replacingOccurrences(of: " 0", with: " ")
    }

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let stripped = Py.strip(try PyArgs.stringOrEmpty(args, "title", method: "strip"))
        let title = stripped.isEmpty ? "Event" : stripped
        let whenText = try PyArgs.stringOrEmpty(args, "when", method: "lower")
        let nowSeconds = clock.now()
        guard let when = WhenParser.parse(whenText, now: Date(timeIntervalSince1970: nowSeconds), timeZone: timeZone) else {
            return .text("When should I schedule that for, sir?")
        }
        let minutes = (try? PyInt.value(args["duration_minutes"] ?? .int(60))).map { max(5, $0) }
        let seconds = minutes.map { $0 * 60 } ?? 3600
        let reply = "Scheduled \(title) for \(Self.spoken(when, timeZone)), sir."
        let calendar = self.calendar, scripts = self.scripts, pause = self.pause, clock = self.clock
        return .needsConfirmation(desc: "That will add \(title) to your calendar for \(Self.spoken(when, timeZone))") {
            switch await calendar.create(title: title, start: when, seconds: seconds) {
            case true?: return reply
            case false?: return "I couldn't create that event, sir — check JARVIS's calendar access in Settings."
            case nil: break
            }
            // The offset from "current date" is taken when the user confirms, not when asked.
            let start = max(0, Int((when.timeIntervalSince1970 - clock.now()).rounded(.towardZero)))
            let script = Self.script(title: title, start: start, end: start + seconds)
            var out = await scripts.run(script)
            if AppleScriptText.errored(out) {
                await AppleScriptText.ensureRunning("Calendar", scripts: scripts, pause: pause)
                out = await scripts.run(script)
            }
            if AppleScriptText.errored(out) || AppleScriptText.mentionsError(out) {
                return "I couldn't create that event, sir — check Calendar automation permission."
            }
            return reply
        }
    }
}
