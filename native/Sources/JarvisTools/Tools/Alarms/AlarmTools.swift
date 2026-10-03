import Foundation
import JarvisCore

/// `set_reminder` (F1). Python created an Apple Reminder through AppleScript on macOS
/// (`_create_reminder`, jarvis.py 2955-2973), which only ever showed Reminders' silent
/// notification. Native keeps the reminder in JARVIS's own alarms.json, as Python did on
/// Windows, marked `"kind": "reminder"`, and ReminderSchedule speaks it when it comes due. The
/// time comes from `when`, else from the text (`_parse_when(when_text or text)`). With no time
/// in either, nothing is saved and he asks for one (Python made an undated Apple Reminder).
struct SetReminder: ToolImpl {
    static let name = "set_reminder"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let askWhen = "When should I remind you, sir? Try 'at 5pm' or 'in 10 minutes'."
    static let failed = "I couldn't set that reminder, sir."

    let book: AlarmBook
    let clock: any JarvisClock
    let timeZone: TimeZone

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        var text = Py.strip(PyArgs.str(args["text"] ?? .string("")))
        if text.isEmpty { text = "Reminder" }
        let whenText = PyArgs.str(args["when"] ?? .string(""))
        let now = Date(timeIntervalSince1970: clock.now())
        guard let when = WhenParser.parse(whenText.isEmpty ? text : whenText, now: now, timeZone: timeZone) else {
            return .text(Self.askWhen)
        }
        guard book.add(at: when, label: text, kind: .reminder) else { return .text(Self.failed) }
        return .text("Reminder set for \(AlarmTime.spoken(when, timeZone)), sir.")
    }
}

/// `set_alarm` (F1), Python's `set_alarm` (jarvis.py 4057-4078): "every day" / "weekdays"
/// make it repeat, a time with no "at", "in" or "tomorrow" gets "at " in front, and the entry
/// goes into alarms.json. ReminderSchedule speaks it ("Alarm, sir. …") when it comes due.
/// Python also played the Funk sound four times; native only speaks.
struct SetAlarm: ToolImpl {
    static let name = "set_alarm"
    static let schema = BuiltInTools.catalogSchema(named: name)
    static let askWhen = "When should I set the alarm for, sir? Try 'at 7 a.m.' or 'in 30 minutes'."
    static let failed = "I couldn't set that alarm, sir."
    private static let weekdaysPattern = #"\b(every weekday|each weekday|weekdays)\b"#
    private static let dailyPattern = #"\b(every day|each day|daily|every morning|every night)\b"#
    private static let repeatPattern = #"\b(every weekday|each weekday|weekdays|every day|each day|daily|every morning|every night)\b"#

    let book: AlarmBook
    let clock: any JarvisClock
    let timeZone: TimeZone

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        var wt = PyArgs.str(args["when"] ?? .string("")).lowercased()
        let label = PyArgs.str(args["label"] ?? .string(""))
        var repeats: String?
        if Self.matches(Self.weekdaysPattern, wt) {
            repeats = "weekdays"
        } else if Self.matches(Self.dailyPattern, wt) {
            repeats = "daily"
        }
        if repeats != nil {
            wt = Self.replacing(Self.repeatPattern, in: wt).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        if !Self.matches(#"\b(at|in|tomorrow)\b"#, wt) { wt = "at " + wt }
        let now = Date(timeIntervalSince1970: clock.now())
        guard let when = WhenParser.parse(wt, now: now, timeZone: timeZone) else { return .text(Self.askWhen) }
        guard book.add(at: when, label: label, repeats: repeats, kind: .alarm) else { return .text(Self.failed) }
        let suffix = repeats == "daily" ? " every day" : repeats == "weekdays" ? " on weekdays" : ""
        return .text("Alarm set for \(AlarmTime.spoken(when, timeZone))\(suffix), sir.")
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func replacing(_ pattern: String, in text: String) -> String {
        text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
}

/// `dt.strftime('%I:%M %p').lstrip('0')`: "6:00 PM".
enum AlarmTime {
    static func spoken(_ date: Date, _ timeZone: TimeZone) -> String {
        Py.lstrip(PyTime.strftime("%I:%M %p", date, timeZone: timeZone), "0")
    }
}
