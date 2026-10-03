import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// F1: set_reminder and set_alarm write alarms.json, and ReminderSchedule speaks each entry as
/// it comes due. Every clock is a ManualClock and every "speech" a recorded line: nothing plays.
@Suite("SpokenRemindersTests")
struct SpokenRemindersTests {
    static let zone = TimeZone(identifier: "Europe/London")!

    /// The epoch of a local time in `zone`. 2026-10-03 is a Saturday.
    static func at(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute, second: 0)
        return cal.date(from: c)!.timeIntervalSince1970
    }

    static func parse(_ text: String, now: Double) -> Double? {
        WhenParser.parse(text, now: Date(timeIntervalSince1970: now), timeZone: zone)?.timeIntervalSince1970
    }

    // MARK: WhenParser (_parse_when)

    @Test func parsesPythonsForms() {
        let now = Self.at(3, 15)
        #expect(Self.parse("in 10 minutes", now: now) == now + 600)
        #expect(Self.parse("in 2 hours", now: now) == now + 7200)
        #expect(Self.parse("at 5pm", now: now) == Self.at(3, 17))
        #expect(Self.parse("at 5:30 pm", now: now) == Self.at(3, 17, 30))
        #expect(Self.parse("at 9am", now: now) == Self.at(4, 9))          // passed today: tomorrow
        #expect(Self.parse("tomorrow at 8am", now: now) == Self.at(4, 8))
        #expect(Self.parse("tomorrow", now: now) == Self.at(4, 9))
        #expect(Self.parse("on friday at 2pm", now: now) == Self.at(9, 14))
        #expect(Self.parse("saturday", now: now) == Self.at(10, 9))       // said on a Saturday: next week
        #expect(Self.parse("at 18:00", now: now) == Self.at(3, 18))
        #expect(Self.parse("whenever suits", now: now) == nil)
        #expect(Self.parse("at 25", now: now) == nil)
    }

    /// The F1 departures: "p.m." is pm, and a bare hour that has passed today means the afternoon.
    @Test func bareHourMeansTheNextOneSaid() {
        #expect(Self.parse("at 6", now: Self.at(3, 15)) == Self.at(3, 18))
        #expect(Self.parse("at 6", now: Self.at(3, 19)) == Self.at(4, 6))
        #expect(Self.parse("at 6", now: Self.at(3, 4)) == Self.at(3, 6))
        #expect(Self.parse("at 7 p.m.", now: Self.at(3, 8)) == Self.at(3, 19))
        #expect(Self.parse("at 7 a.m.", now: Self.at(3, 8)) == Self.at(4, 7))
    }

    // MARK: AlarmBook

    @Test func addWritesPythonsShapeWithTheReminderKind() throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        #expect(book.add(at: Date(timeIntervalSince1970: Self.at(3, 18)), label: "call a friend", kind: .reminder))
        #expect(book.add(at: Date(timeIntervalSince1970: Self.at(5, 7)), label: "", repeats: "weekdays", kind: .alarm))
        let text = try String(contentsOfFile: sandbox.store.path(.alarms), encoding: .utf8)
        #expect(text == #"[{"time": "2026-10-03T18:00:00", "label": "call a friend", "kind": "reminder"}, "#
            + #"{"time": "2026-10-05T07:00:00", "label": "", "repeat": "weekdays"}]"#)
    }

    @Test func takeDueRemovesOneOffsAndRollsRepeatsForward() throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        // As Python wrote them: microseconds, no kind; one entry it could not have parsed.
        try #"[{"time": "2026-10-02T07:00:00.250000", "label": "gym", "repeat": "weekdays"}, "#
            .appending(#"{"time": "2026-10-03T18:00:00", "label": "call", "kind": "reminder"}, "#)
            .appending(#"{"time": "not a time", "label": "x"}, {"time": "2026-10-03T07:30:00", "label": "tea", "repeat": "daily"}]"#)
            .write(toFile: sandbox.store.path(.alarms), atomically: true, encoding: .utf8)
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        #expect(book.takeDue(at: Date(timeIntervalSince1970: Self.at(3, 6))).map(\.label) == ["gym"])
        let afterFirst = book.entries()
        // Friday's weekday alarm rolls past the weekend to Monday.
        #expect(afterFirst.first { $0.label == "gym" }?.stamp == "2026-10-05T07:00:00")
        #expect(afterFirst.first { $0.label == "gym" }?.kind == .alarm)
        let due = book.takeDue(at: Date(timeIntervalSince1970: Self.at(3, 18)))
        #expect(due.map(\.label) == ["call", "tea"])
        #expect(due.first?.kind == .reminder)
        let text = try String(contentsOfFile: sandbox.store.path(.alarms), encoding: .utf8)
        #expect(text == #"[{"time": "2026-10-05T07:00:00", "label": "gym", "repeat": "weekdays"}, "#
            + #"{"time": "not a time", "label": "x"}, {"time": "2026-10-04T07:30:00", "label": "tea", "repeat": "daily"}]"#)
        #expect(book.takeDue(at: Date(timeIntervalSince1970: Self.at(3, 18))).isEmpty)
    }

    @Test func aFileThatIsNotAListIsNeverOverwritten() throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        try #"{"time": "2026-10-03T18:00:00"}"#.write(toFile: sandbox.store.path(.alarms), atomically: true,
                                                       encoding: .utf8)
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        #expect(!book.add(at: Date(timeIntervalSince1970: Self.at(3, 18)), label: "x", kind: .alarm))
        #expect(book.takeDue(at: Date(timeIntervalSince1970: Self.at(4, 0))).isEmpty)
        #expect(try String(contentsOfFile: sandbox.store.path(.alarms), encoding: .utf8)
            == #"{"time": "2026-10-03T18:00:00"}"#)
    }

    @Test func dueLaterTodayIsTodaysRestSoonestFirst() throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 20)), label: "late", kind: .reminder)
        book.add(at: Date(timeIntervalSince1970: Self.at(4, 9)), label: "tomorrow", kind: .reminder)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 17)), label: "soon", kind: .alarm)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 8)), label: "gone", kind: .alarm)
        #expect(book.dueLaterToday(Date(timeIntervalSince1970: Self.at(3, 9))).map(\.label) == ["soon", "late"])
    }

    // MARK: the tools, through the gateway

    private static func gateway(_ sandbox: ToolCoreSandbox, clock: ManualClock) async -> (ToolGateway, AlarmBook) {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        let book = AlarmBook(store: sandbox.store, timeZone: zone)
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: clock, timeZone: zone, alarms: book)
        return (gateway, book)
    }

    private static func call(_ gateway: ToolGateway, _ name: String, _ args: [String: String]) async -> String {
        let object = JSONObject(args.sorted { $0.key < $1.key }.map { .init(key: $0.key, value: .string($0.value)) })
        let result = await gateway.call(name, object, turn: TurnContext(channel: .voice), origin: .model(.claude))
        #expect(!result.isError)
        return result.text
    }

    @Test func setReminderAndSetAlarmAnswerAsPythonDid() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let clock = ManualClock(Self.at(3, 15))
        let (gateway, book) = await Self.gateway(sandbox, clock: clock)
        #expect(await Self.call(gateway, "set_reminder", ["text": "call a friend", "when": "at 6"])
            == "Reminder set for 6:00 PM, sir.")
        #expect(await Self.call(gateway, "set_reminder", ["text": "stretch in 10 minutes"])
            == "Reminder set for 3:10 PM, sir.")
        #expect(await Self.call(gateway, "set_alarm", ["when": "7 a.m. every weekday", "label": "work"])
            == "Alarm set for 7:00 AM on weekdays, sir.")
        #expect(await Self.call(gateway, "set_alarm", ["when": "every day at 6:30am"])
            == "Alarm set for 6:30 AM every day, sir.")
        #expect(await Self.call(gateway, "set_reminder", ["text": "water the plants"]) == SetReminder.askWhen)
        #expect(await Self.call(gateway, "set_alarm", ["when": "soon"]) == SetAlarm.askWhen)
        let entries = book.entries()
        #expect(entries.map(\.label) == ["call a friend", "stretch in 10 minutes", "work", ""])
        #expect(entries.map(\.kind) == [.reminder, .reminder, .alarm, .alarm])
        #expect(entries.map(\.repeats) == [nil, nil, "weekdays", "daily"])
        // As in Python, the first occurrence is simply the next 7am (a Sunday here); only the
        // roll-forward skips weekends.
        #expect(entries[2].stamp == "2026-10-04T07:00:00")
    }

    // MARK: ReminderSchedule

    @Test func linesAreHisVoice() {
        let reminder = AlarmEntry(stamp: "", time: Date(), label: "call a friend.", repeats: nil, kind: .reminder)
        let alarm = AlarmEntry(stamp: "", time: Date(), label: "", repeats: nil, kind: .alarm)
        let labelled = AlarmEntry(stamp: "", time: Date(), label: "Work", repeats: nil, kind: .alarm)
        #expect(ReminderSchedule.line(for: reminder) == "Sir, you asked me to remind you: call a friend.")
        #expect(ReminderSchedule.line(for: alarm) == "Alarm, sir. It's time.")
        #expect(ReminderSchedule.line(for: labelled) == "Alarm, sir. Work.")
    }

    @Test func aReminderSetByTheToolIsSpokenWhenDueAndOnlyOnce() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let clock = ManualClock(Self.at(3, 15))
        let (gateway, book) = await Self.gateway(sandbox, clock: clock)
        _ = await Self.call(gateway, "set_reminder", ["text": "call a friend", "when": "at 6pm"])
        let spoken = Mutex<[String]>([])
        let schedule = ReminderSchedule(book: book, clock: clock, announce: { line in spoken.withLock { $0.append(line) } },
                                        log: { _ in })
        #expect(await schedule.check().isEmpty)
        clock.set(Self.at(3, 17, 59))
        #expect(await schedule.check().isEmpty)
        clock.set(Self.at(3, 18) + 4)
        #expect(await schedule.check() == ["Sir, you asked me to remind you: call a friend."])
        #expect(await schedule.check().isEmpty)
        #expect(spoken.withLock { $0 } == ["Sir, you asked me to remind you: call a friend."])
        #expect(book.entries().isEmpty)
    }

    /// What came due while JARVIS was quit: spoken at launch under two hours late, else logged
    /// (without its label).
    @Test func launchSpeaksUnderTwoHoursLateAndLogsTheRest() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 12)), label: "private thing", kind: .reminder)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 13, 30)), label: "recent", kind: .reminder)
        let logged = Mutex<[String]>([])
        let clock = ManualClock(Self.at(3, 15))
        let schedule = ReminderSchedule(book: book, clock: clock, announce: { _ in },
                                        log: { line in logged.withLock { $0.append(line) } })
        #expect(await schedule.check() == ["Sir, you asked me to remind you: recent."])
        let lines = logged.withLock { $0 }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("180 min ago") == true)
        #expect(lines.first?.contains("private") == false)
        #expect(book.entries().isEmpty)
    }

    /// The loop compares the wall clock on every tick: a reminder due after a few ticks (or after
    /// the Mac slept through it) is spoken on the next one. The fake sleep moves the clock on.
    @Test func theLoopSpeaksOnTheFirstTickAfterTheDueTime() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let clock = ManualClock(Self.at(3, 15))
        let book = AlarmBook(store: sandbox.store, timeZone: Self.zone)
        book.add(at: Date(timeIntervalSince1970: Self.at(3, 15) + 25), label: "kettle", kind: .reminder)
        let (stream, continuation) = AsyncStream.makeStream(of: (String, Double).self)
        let ticks = Mutex(0)
        let schedule = ReminderSchedule(
            book: book, clock: clock,
            sleep: { duration in
                ticks.withLock { $0 += 1 }
                clock.set(clock.now() + Double(duration.components.seconds))
                await Task.yield()
                try Task.checkCancellation()
            },
            announce: { line in continuation.yield((line, clock.now())) }, log: { _ in })
        schedule.start()
        var heard: (String, Double)?
        for await event in stream {
            heard = event
            break
        }
        schedule.stop()
        #expect(heard?.0 == "Sir, you asked me to remind you: kettle.")
        // Checked at +0, +10, +20, +30: spoken on the +30 check, the first after +25.
        #expect(heard?.1 == Self.at(3, 15) + 30)
    }
}
