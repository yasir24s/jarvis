import Foundation
import JarvisCore
@testable import JarvisTools
import SQLite3
import Synchronization
import Testing

/// EventKit stand-in: answers what the case says and records every window and create.
final class FakeCalendar: CalendarStoring {
    let entries: [CalendarEntry]?
    let createAnswer: Bool?
    private let log = Mutex<(windows: [[Double]], created: [[JSONValue]])>(([], []))

    init(entries: [CalendarEntry]? = nil, createAnswer: Bool? = nil) {
        self.entries = entries
        self.createAnswer = createAnswer
    }

    var windows: [[Double]] { log.withLock { $0.windows } }
    var created: [[JSONValue]] { log.withLock { $0.created } }

    func events(from start: Date, to end: Date) async -> [CalendarEntry]? {
        log.withLock { $0.windows.append([start.timeIntervalSince1970, end.timeIntervalSince1970]) }
        return entries
    }

    func create(title: String, start: Date, seconds: Int) async -> Bool? {
        log.withLock { $0.created.append([.string(title), .double(start.timeIntervalSince1970), .int(Int64(seconds))]) }
        return createAnswer
    }
}

/// PB: get_messages, get_calendar, find_contact, send_message, send_email and create_event
/// against Python's replies and AppleScripts (tools/golden_pb_personal.py). Contacts and
/// EventKit are fakes (none here means Python's AppleScript path, which is what Python ran);
/// Messages is a real SQLite file built in a temporary folder from the case's statements. Every
/// osascript goes to a recording fake, so nothing is sent, created or launched.
@Suite("PB personal tools (golden)")
struct PersonalToolsGoldenTests {
    static let epoch: Double = 1_790_582_400

    struct Run {
        let text: String
        let gated: Bool
        let scripts: [String]
    }

    /// Calls `tool` on a gateway over `platform`; a gated call is confirmed by voice, so the
    /// reply compared is what the confirmed action said, as Python (which never asked) said it.
    static func call(_ tool: String, _ args: JSONObject, platform: ToolPlatform, scripts: ScriptedRunner) async throws -> Run {
        let sandbox = try ToolCoreSandbox(clock: ManualClock(epoch))
        defer { sandbox.remove() }
        let gate = ConfirmationGate()
        let gateway = ToolGateway(confirmationGate: gate, log: { _ in })
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: ManualClock(epoch),
                                    timeZone: TimeZone(identifier: "Europe/London")!, platform: platform)
        let turn = TurnContext(channel: .voice)
        let result = await gateway.call(tool, args, turn: turn, origin: .model(.claude))
        guard result.record.outcome == .gated else { return Run(text: result.text, gated: false, scripts: await scripts.scripts) }
        #expect(await scripts.scripts.allSatisfy { !Py.contains($0, "send ") && !Py.contains($0, "make new event") },
                "nothing is sent or created before the user confirms")
        guard case .handled(let text) = await gate.consume("confirm", via: .voice, runIn: turn) else {
            Issue.record("the confirmation did not run")
            return Run(text: "", gated: true, scripts: [])
        }
        return Run(text: text, gated: true, scripts: await scripts.scripts)
    }

    @Test(arguments: try M5Fixture.cases("pb_messages"))
    func messages(_ c: M5Fixture.Case) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "pb-messages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "chat.db").path(percentEncoded: false)
        if let sql = c.input["sql"]?.arrayValue {
            var db: OpaquePointer?
            #expect(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
            for statement in sql.compactMap(\.stringValue) {
                #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
            }
            sqlite3_close_v2(db)
        }
        var platform = ToolPlatform.fake()
        platform.messages = LiveMessages(path: path)
        let scripts = ScriptedRunner([])
        let run = try await Self.call("get_messages", JSONObject(), platform: platform, scripts: scripts)
        #expect(run.text == c.expected.string("text"), "\(c.name)")
    }

    @Test(arguments: try M5Fixture.cases("pb_calendar"))
    func calendar(_ c: M5Fixture.Case) async throws {
        let entries = c.input["events"]?.arrayValue?.map { e -> CalendarEntry in
            let f = e.arrayValue ?? []
            return CalendarEntry(title: f[0].stringValue ?? "", start: f[1].pyFloat ?? 0, allDay: f[2] == .bool(true))
        }
        let fake = FakeCalendar(entries: entries)
        let scripts = ScriptedRunner((c.input["outputs"]?.arrayValue ?? []).compactMap(\.stringValue))
        var platform = ToolPlatform.fake()
        platform.calendar = fake
        platform.scriptRunner = scripts
        let run = try await Self.call("get_calendar", JSONObject(), platform: platform, scripts: scripts)
        #expect(run.text == c.expected.string("text"), "\(c.name)")
        #expect(run.scripts == (c.expected["scripts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        #expect(fake.windows == [(c.expected["window"]?.arrayValue ?? []).compactMap(\.pyFloat)], "\(c.name)")
    }

    @Test(arguments: try M5Fixture.cases("pb_contacts"))
    func contacts(_ c: M5Fixture.Case) async throws {
        let tool = try #require(c.input.string("tool"))
        let ek: Bool? = if case .bool(let b)? = c.input["ek"] { b } else { nil }
        let fake = FakeCalendar(createAnswer: ek)
        let scripts = ScriptedRunner((c.input["outputs"]?.arrayValue ?? []).compactMap(\.stringValue))
        var platform = ToolPlatform.fake()
        platform.calendar = fake
        platform.scriptRunner = scripts
        let run = try await Self.call(tool, c.input.object("args") ?? JSONObject(), platform: platform, scripts: scripts)
        let want = try #require(c.expected.string("text"))
        #expect(run.text == want, "\(c.name)")
        #expect(run.scripts == (c.expected["scripts"]?.arrayValue ?? []).compactMap(\.stringValue), "\(c.name)")
        let created = (c.expected["created"]?.arrayValue ?? []).map { row in
            (row.arrayValue ?? []).enumerated().map { i, v in i == 1 ? JSONValue.double(v.pyFloat ?? 0) : v }
        }
        #expect(fake.created == created, "\(c.name)")
        // What is sent or written is gated: every reply that reports a send, a failed send or an
        // event (made or not) came through the confirmation; every early answer did not.
        let acted = Py.startsWith(want, "Message sent") || Py.startsWith(want, "Email sent")
            || Py.startsWith(want, "Scheduled") || Py.contains(want, "couldn't send")
            || Py.contains(want, "couldn't create")
        #expect(run.gated == acted, "\(c.name)")
    }
}
