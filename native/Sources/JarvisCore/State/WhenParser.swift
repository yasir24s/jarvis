import Foundation

/// `_parse_when` (jarvis.py 2913-2952): the time a reminder or an alarm is for, from natural
/// language like "in 10 minutes", "at 5pm", "on friday at 2pm" or "tomorrow". `now` and the
/// time zone are injected, so tests pin the instant. Nil when no time was found.
///
/// Two departures from Python, both so a bare spoken hour means what was said (F1):
/// - "a.m." and "p.m." are read as "am" and "pm" (Python's regex only knew "am"/"pm", so
///   "at 7 p.m." set 7 in the morning).
/// - A bare hour from 1 to 11 with no am/pm that has passed today, while the same hour in the
///   afternoon has not, is the afternoon one: "at 6" said at 3pm is 6pm today, where Python set
///   6am tomorrow.
/// An hour past 23 or a minute past 59 is no time (Python raised from `datetime.replace`).
public enum WhenParser {
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    private static let inPattern = #"in (\d+)\s*(second|sec|minute|min|hour|hr|day)s?"#
    private static let dayPattern = #"\b(?:on\s+|next\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#
    private static let atPattern = #"at (\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.?|p\.m\.?)?"#

    public static func parse(_ text: String, now: Date, timeZone: TimeZone) -> Date? {
        let t = text.lowercased()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        if let m = match(inPattern, t), let n = Int(m[1] ?? "") {
            let unit = m[2] ?? ""
            if unit.hasPrefix("sec") { return now.addingTimeInterval(Double(n)) }
            if unit.hasPrefix("min") { return now.addingTimeInterval(Double(n) * 60) }
            if unit.hasPrefix("hour") || unit.hasPrefix("hr") { return now.addingTimeInterval(Double(n) * 3600) }
            if unit.hasPrefix("day") { return cal.date(byAdding: .day, value: n, to: now) }
        }
        // A weekday must come before the bare "at H", which would otherwise take the time and
        // drop the day.
        if let m = match(dayPattern, t), let day = m[1], let index = weekdays.firstIndex(of: day) {
            let today = (cal.component(.weekday, from: now) + 5) % 7     // Python's weekday(): Monday 0
            var ahead = (index - today + 7) % 7
            if ahead == 0 { ahead = 7 }    // a bare "friday" said on a Friday is next week
            guard let date = cal.date(byAdding: .day, value: ahead, to: now) else { return nil }
            var hour = 9, minute = 0
            if let tm = match(atPattern, t) {
                guard let time = clockTime(tm) else { return nil }
                (hour, minute) = (time.hour, time.minute)
            }
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: date)
        }
        if let m = match(atPattern, t) {
            guard let time = clockTime(m),
                  var when = cal.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) else {
                return nil
            }
            if t.contains("tomorrow") {
                return cal.date(byAdding: .day, value: 1, to: when)
            }
            if when <= now, time.bare, (1...11).contains(time.hour),
               let afternoon = cal.date(bySettingHour: time.hour + 12, minute: time.minute, second: 0, of: now),
               afternoon > now {
                return afternoon
            }
            if when <= now { when = cal.date(byAdding: .day, value: 1, to: when) ?? when }
            return when
        }
        if t.contains("tomorrow"), let date = cal.date(byAdding: .day, value: 1, to: now) {
            return cal.date(bySettingHour: 9, minute: 0, second: 0, of: date)
        }
        return nil
    }

    /// The hour and minute of an `atPattern` match; `bare` when no am/pm was said.
    private static func clockTime(_ m: [String?]) -> (hour: Int, minute: Int, bare: Bool)? {
        guard var hour = Int(m[1] ?? "") else { return nil }
        let minute = Int(m[2] ?? "0") ?? 0
        let ap = m[3]?.first
        if ap == "p" && hour < 12 { hour += 12 }
        if ap == "a" && hour == 12 { hour = 0 }
        guard hour <= 23, minute <= 59 else { return nil }
        return (hour, minute, ap == nil)
    }

    /// The first match's groups (index 0 the whole match), nil for a group that took no part.
    private static func match(_ pattern: String, _ text: String) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }
}
