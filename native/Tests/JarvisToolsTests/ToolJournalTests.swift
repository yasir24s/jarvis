import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// P6b part 5: every call the gateway handles is noted in the task journal (memory/journal.jsonl,
/// in a sandbox, never the real one): ran, gated, blocked or failed, with its arguments
/// summarised and the start of its reply, except a reading tool's reply, which is never kept. A
/// confirmed call is noted again when it runs. The tools are fakes under real names.
@Suite("P6b task journal at the gateway")
struct ToolJournalTests {
    static let epoch: Double = 1_790_582_400                           // 2026-09-28 08:00 UTC

    private struct Clock: ToolImpl {
        static let name = "get_time"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("It is eight o'clock, sir.") }
    }

    private struct Reader: ToolImpl {
        static let name = "read_file"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .text("THE FILE SAYS: the wifi password is hunter2")
        }
    }

    private struct Broken: ToolImpl {
        struct Jammed: Error {}
        static let name = "take_screenshot"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { throw Jammed() }
    }

    private struct Command: ToolImpl {
        static let name = "run_command"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome { .text("removed") }
    }

    private struct Mover: ToolImpl {
        static let name = "move_file"
        static let schema = ToolSchema(name: name)
        func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
            .needsConfirmation(desc: "That will move it") { "moved" }
        }
    }

    struct Rig {
        let sandbox: ToolCoreSandbox
        let memory: MemoryStore
        let gate = ConfirmationGate()
        let gateway: ToolGateway

        init() async throws {
            let clock = ManualClock(ToolJournalTests.epoch)
            sandbox = try ToolCoreSandbox(clock: clock)
            memory = MemoryStore(store: sandbox.store, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
            gateway = ToolGateway(confirmationGate: gate, log: { _ in }, journal: ToolJournal(memory: memory))
            await gateway.register(Clock())
            await gateway.register(Reader())
            await gateway.register(Broken())
            await gateway.register(Command())
            await gateway.register(Mover())
        }

        func call(_ name: String, _ pairs: (String, JSONValue)..., turn: TurnContext) async -> ToolCallResult {
            await gateway.call(name, JSONObject(pairs.map { .init(key: $0.0, value: $0.1) }), turn: turn,
                               origin: .model(.claude))
        }

        var lines: [JournalEntry] { memory.journalEntries() }
        var raw: String {
            String(decoding: FileManager.default.contents(atPath: sandbox.store.path(.journal)) ?? Data(), as: UTF8.self)
        }
    }

    @Test func everyCallIsNotedWithItsOutcome() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let turn = TurnContext(channel: .voice)
        let time = await rig.call("get_time", ("zone", .string("Europe/London")), turn: turn)
        let read = await rig.call("read_file", ("path", .string("~/invented.txt")), turn: turn)
        let write = await rig.call("write_file", ("path", .string("~/out.txt")), ("content", .string("x")), turn: turn)
        let fresh = TurnContext(channel: .voice)
        let guarded = await rig.call("run_command", ("command", .string("rm -rf /")), turn: fresh)
        let unknown = await rig.call("no_such_tool", turn: fresh)
        let broken = await rig.call("take_screenshot", turn: fresh)
        #expect([time, read, write, guarded, unknown, broken].map(\.record.outcome)
                == [.ran, .ran, .blockedTaint, .blockedGuard, .unknown, .failed])

        let lines = rig.lines
        #expect(lines.map(\.tool) == ["get_time", "read_file", "write_file", "run_command", "no_such_tool", "take_screenshot"])
        #expect(lines.map(\.outcome) == [.ran, .ran, .blocked, .blocked, .failed, .failed])
        #expect(lines.map(\.args) == ["zone: Europe/London", "path: ~/invented.txt", "path: ~/out.txt; content: x",
                                      "command: rm -rf /", "", ""])
        #expect(lines[0].reply == "It is eight o'clock, sir.")
        #expect(lines[1].reply == nil)                                    // what was read is never kept
        for (line, result) in zip(lines.dropFirst(2), [write, guarded, unknown, broken]) {
            #expect(line.reply == JournalEntry.excerpt(result.text))
        }
        #expect(lines.allSatisfy { $0.date == "2026-09-28" && $0.time == "08:00" && $0.timestamp == Self.epoch })
        #expect(!rig.raw.contains("hunter2") && !rig.raw.contains("THE FILE SAYS"))
    }

    /// A gated call is noted when it is asked for, and again when the user confirms and it runs:
    /// run_command's own confirmation, and a tool's.
    @Test func aConfirmedCallIsNotedAgainWhenItRuns() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let turn = TurnContext(channel: .voice)
        let command = await rig.call("run_command", ("command", .string("rm ~/invented.txt")), turn: turn)
        #expect(command.record.outcome == .gated)
        #expect(await rig.gate.consume("confirm", via: .voice, runIn: turn) == .handled("removed"))
        let move = await rig.call("move_file", ("from", .string("~/a.txt")), ("to", .string("~/b.txt")), turn: turn)
        #expect(move.record.outcome == .gated)
        #expect(await rig.gate.consume("confirm", via: .voice, runIn: turn) == .handled("moved"))
        #expect(rig.lines.map(\.tool) == ["run_command", "run_command", "move_file", "move_file"])
        #expect(rig.lines.map(\.outcome) == [.gated, .ran, .gated, .ran])
        #expect(rig.lines.map(\.args) == ["command: rm ~/invented.txt", "command: rm ~/invented.txt",
                                          "from: ~/a.txt; to: ~/b.txt", "from: ~/a.txt; to: ~/b.txt"])
        #expect(rig.lines.map(\.reply) == [JournalEntry.excerpt(command.text), "removed",
                                           JournalEntry.excerpt(move.text), "moved"])
    }

    /// Secrets in the arguments or the reply are masked before anything is written.
    @Test func secretsNeverReachTheJournal() async throws {
        let rig = try await Rig()
        defer { rig.sandbox.remove() }
        let turn = TurnContext(channel: .voice)
        _ = await rig.call("get_time", ("note", .string("my password is hunter2")), turn: turn)
        #expect(rig.lines.first?.args == "note: my password is \(Redactor.mask)")
        #expect(!rig.raw.contains("hunter2"))
    }
}
