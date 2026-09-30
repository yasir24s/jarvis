import Foundation
import JarvisCore
@testable import JarvisTools
import Synchronization
import Testing

/// `get_time` (B4) against the m3_get_time fixture: what the REAL `_get_system_info("time")`
/// returned at each pinned instant, under the suite's TZ (Europe/London).
@Suite("GetTimeTests")
struct GetTimeTests {
    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let epoch: Double
        let text: String
        var description: String { name }
    }

    /// This target has no JarvisTestSupport, so the fixture is found from #filePath.
    static func fixture() throws -> (timeZone: TimeZone, cases: [Case]) {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/golden/m3_get_time.golden.json")
        let envelope = try #require(try PyJSON.loads(Data(contentsOf: url)).objectValue)
        #expect(envelope["suite"]?.stringValue == "m3_get_time")
        let tz = try #require(envelope["clock"]?.objectValue?["tz"]?.stringValue)
        let cases = try #require(envelope["cases"]?.arrayValue).map { value in
            let c = try #require(value.objectValue)
            return Case(name: try #require(c["name"]?.stringValue),
                        epoch: try #require(c["input"]?.objectValue?["epoch"]?.pyFloat),
                        text: try #require(c["expected"]?.objectValue?["text"]?.stringValue))
        }
        return (try #require(TimeZone(identifier: tz)), cases)
    }

    @Test func fixtureHoldsEveryCase() throws {
        #expect(try Self.fixture().cases.count == 41)
    }

    @Test func goldenCasesThroughGetTime() throws {
        let (zone, cases) = try Self.fixture()
        for c in cases {
            #expect(GetTime(clock: ManualClock(c.epoch), timeZone: zone).text() == c.text, "\(c)")
        }
    }

    @Test func goldenCasesThroughTheGateway() async throws {
        let (zone, cases) = try Self.fixture()
        let clock = ManualClock(0)
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: clock, timeZone: zone)
        for c in cases {
            clock.set(c.epoch)
            let result = await gateway.call("get_time", JSONObject(), turn: TurnContext(channel: .voice),
                                            origin: .model(.claude))
            #expect(result.text == c.text, "\(c)")
            #expect(!result.isError, "\(c)")
            #expect(result.record.outcome == .ran, "\(c)")
        }
        // Python's execute_tool ignores get_time's arguments.
        let first = try #require(cases.first)
        clock.set(first.epoch)
        let args = JSONObject([.init(key: "info_type", value: .string("all"))])
        let ignored = await gateway.call("get_time", args, turn: TurnContext(channel: .text), origin: .model(.local))
        #expect(ignored.text == first.text)
    }

    /// The gateway lists the generated catalog entry once the body is registered, not before.
    @Test func registeredSchemaIsTheGeneratedCatalogEntry() async throws {
        let catalog = try #require(ToolCatalog.tools.first { $0.name == "get_time" })
        #expect(GetTime.schema == catalog)
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        #expect(await gateway.toolList().first { $0.name == "get_time" } == ToolSchema(name: "get_time"))
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: ManualClock(0),
                                    timeZone: try Self.fixture().timeZone)
        let listed = await gateway.toolList()
        #expect(listed.map(\.name) == DataSourceMap.toolNames)
        #expect(listed.first { $0.name == "get_time" } == catalog)
    }

    /// Python's EXECUTOR_TOOLS does not hold get_time, so the injection guard lets it run after
    /// untrusted content; nor does UNTRUSTED_TOOLS, so it neither adds nor clears the taint.
    @Test(arguments: [BackendKind.local, BackendKind.claude])
    func runsOnATaintedTurn(_ backend: BackendKind) async throws {
        let (zone, cases) = try Self.fixture()
        let c = try #require(cases.first)
        let log = TimeLog()
        let counter = TimeCounter()
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: log.sink, research: counter)
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: ManualClock(c.epoch), timeZone: zone)
        let turn = TurnContext(channel: .voice, startTainted: true)
        #expect(!TaintPolicy.executors.contains("get_time"))
        #expect(!TaintPolicy.untrusted.contains("get_time"))

        let result = await gateway.call("get_time", JSONObject(), turn: turn, origin: .model(backend))

        #expect(result.text == c.text)
        #expect(!result.isError)
        #expect(result.record.outcome == .ran)
        #expect(await turn.tainted)
        #expect(await turn.summary().taintedBy == ["paste"])
        #expect(log.all.isEmpty)
        #expect(counter.bumps.isEmpty)
    }
}

private final class TimeLog: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }
}

private final class TimeCounter: ResearchCounting {
    private let bumpsStorage = Mutex<[String]>([])

    var bumps: [String] { bumpsStorage.withLock { $0 } }

    func bump(_ key: String, by n: Int) {
        bumpsStorage.withLock { $0.append("\(key)+\(n)") }
    }
}
