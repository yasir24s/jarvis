import Foundation
import Synchronization

/// One entry of alarms.json, as F1 reads it.
public struct AlarmEntry: Sendable, Equatable {
    /// A JARVIS alarm (`set_alarm`) or a reminder (`set_reminder`). Python's entries have no
    /// `kind` and are alarms; F1 writes `"kind": "reminder"` on a reminder (Python ignores it).
    public enum Kind: String, Sendable {
        case alarm
        case reminder
    }

    /// The entry's `time` exactly as stored: its identity in the file.
    public let stamp: String
    public let time: Date
    public let label: String
    /// Python's `repeat`: "daily" or "weekdays", nil for a one-off.
    public let repeats: String?
    public let kind: Kind

    public init(stamp: String, time: Date, label: String, repeats: String?, kind: Kind) {
        self.stamp = stamp
        self.time = time
        self.label = label
        self.repeats = repeats
        self.kind = kind
    }
}

/// JARVIS's alarms and reminders in alarms.json (M1 owns the file's schema and write style:
/// `[{"time": naive local isoformat, "label": str, "repeat": "daily"|"weekdays"}]`, compact).
/// F1 adds the optional `"kind": "reminder"`. Every change is one load, modify and save under a
/// lock, so two writers never lose each other's entry (Python's read-modify-write had that race).
/// An entry that is not an object or whose time does not parse is kept in the file as it is,
/// and never fires. A file that is not a JSON list is never overwritten.
public final class AlarmBook: Sendable {
    private let store: StateStore
    private let timeZone: TimeZone
    private let lock = Mutex(())

    public init(store: StateStore, timeZone: TimeZone) {
        self.store = store
        self.timeZone = timeZone
    }

    /// Adds an entry. False when the file could not be read as a list or was not written.
    @discardableResult
    public func add(at time: Date, label: String, repeats: String? = nil, kind: AlarmEntry.Kind) -> Bool {
        lock.withLock { _ in
            guard var list = loadList() else { return false }
            var entry = JSONObject()
            entry["time"] = .string(Self.stamp(time, timeZone))
            entry["label"] = .string(label)
            if let repeats { entry["repeat"] = .string(repeats) }
            if kind == .reminder { entry["kind"] = .string(kind.rawValue) }
            list.append(.object(entry))
            return store.save(.alarms, .array(list))
        }
    }

    /// Every entry that parses, in file order.
    public func entries() -> [AlarmEntry] {
        lock.withLock { _ in (loadList() ?? []).compactMap { entry($0) } }
    }

    /// The entries due at `now` (time ≤ now), taken out of the file: a one-off is removed, and a
    /// repeating one rolls forward to its first occurrence after `now` (Python's `_fire_alarm`
    /// and `reschedule_alarms`). The file is written only when something was due.
    public func takeDue(at now: Date) -> [AlarmEntry] {
        lock.withLock { _ in
            guard let list = loadList() else { return [] }
            var due: [AlarmEntry] = []
            var keep: [JSONValue] = []
            for value in list {
                guard let e = entry(value), e.time <= now, case .object(var object) = value else {
                    keep.append(value)
                    continue
                }
                due.append(e)
                if let repeats = e.repeats {
                    var next = e.time
                    while next <= now { next = Self.nextRepeat(next, repeats, timeZone) }
                    object["time"] = .string(Self.stamp(next, timeZone))   // dict(x, time=…): same position
                    keep.append(.object(object))
                }
            }
            if !due.isEmpty { store.save(.alarms, .array(keep)) }
            return due
        }
    }

    /// The entries due later on `now`'s day (local), soonest first: the briefing's agenda.
    public func dueLaterToday(_ now: Date) -> [AlarmEntry] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return entries().filter { $0.time >= now && cal.isDate($0.time, inSameDayAs: now) }
            .sorted { $0.time < $1.time }
    }

    /// The list in the file; [] when there is none or it does not parse (Python's `except: []`),
    /// nil when it parses as something other than a list.
    private func loadList() -> [JSONValue]? {
        switch store.load(.alarms) {
        case nil: []
        case .array(let list)?: list
        default: nil
        }
    }

    private func entry(_ value: JSONValue) -> AlarmEntry? {
        guard case .object(let o) = value, let stamp = o["time"]?.stringValue,
              let time = Self.date(stamp, timeZone) else { return nil }
        let repeats = o["repeat"]?.stringValue.flatMap { $0 == "daily" || $0 == "weekdays" ? $0 : nil }
        let kind = o["kind"]?.stringValue.flatMap(AlarmEntry.Kind.init(rawValue:)) ?? .alarm
        return AlarmEntry(stamp: stamp, time: time, label: o["label"]?.stringValue ?? "", repeats: repeats,
                          kind: kind)
    }

    /// `_next_repeat`: the next day, skipping Saturday and Sunday for "weekdays".
    static func nextRepeat(_ date: Date, _ repeats: String, _ timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var next = cal.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(86_400)
        if repeats == "weekdays" {
            while cal.isDateInWeekend(next) { next = cal.date(byAdding: .day, value: 1, to: next) ?? next }
        }
        return next
    }

    /// Python's naive `datetime.isoformat()` at whole seconds: "2026-10-03T18:00:00".
    public static func stamp(_ date: Date, _ timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// `datetime.fromisoformat` for the naive forms Python writes: "YYYY-MM-DDTHH:MM[:SS[.ffffff]]",
    /// read as local time in `timeZone`.
    public static func date(_ stamp: String, _ timeZone: TimeZone) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: stamp, range: NSRange(stamp.startIndex..., in: stamp)) else { return nil }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: stamp).map { String(stamp[$0]) } }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var c = DateComponents()
        c.year = Int(group(1) ?? "")
        c.month = Int(group(2) ?? "")
        c.day = Int(group(3) ?? "")
        c.hour = Int(group(4) ?? "")
        c.minute = Int(group(5) ?? "")
        c.second = Int(group(6) ?? "0")
        guard let month = c.month, (1...12).contains(month), let hour = c.hour, hour <= 23,
              let minute = c.minute, minute <= 59, let base = cal.date(from: c) else { return nil }
        let fraction = group(7).map { Double("0." + $0) ?? 0 } ?? 0
        return base.addingTimeInterval(fraction)
    }
}
