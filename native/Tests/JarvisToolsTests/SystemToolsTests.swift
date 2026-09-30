import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// T5.5: get_battery, get_cpu_usage, get_wifi_status and run_diagnostics against m5_sysinfo,
/// what the REAL `execute_tool` returned over canned pmset/top/networksetup/sysctl/vm_stat/
/// ioreg/ps output. The Swift side gets the same readings as numbers, through a fake probe.
@Suite("SystemToolsTests")
struct SystemToolsTests {
    static let suite = "m5_sysinfo"

    /// pmset's phrase in the fixture -> the state the IOKit probe reports.
    static let states: [String: BatteryState] = [
        "discharging": .discharging, "charging": .charging, "charged": .charged,
        "AC attached": .acAttached, "finishing charge": .finishing,
    ]

    static func probe(_ input: JSONObject) throws -> FakeSystemProbe {
        var probe = FakeSystemProbe()
        if let b = input.object("battery") {
            let phrase = try #require(b.string("state"))
            probe.batteryReading = BatteryReading(percent: try #require(b.int("percent")),
                                                  state: try #require(states[phrase]))
        }
        if input.string("cpu") != nil {
            probe.cpu = SystemText.cpuField(userPercent: try #require(input.double("cpu_value")))
        }
        probe.wifi = input.string("wifi") ?? ""
        if let m = input.object("memory") {
            probe.memoryReading = MemoryReading(memsize: try #require(m.uint("memsize")),
                                                pageSize: try #require(m.uint("page")),
                                                freeCount: try #require(m.uint("free_count")),
                                                speculativeCount: try #require(m.uint("speculative")),
                                                inactiveCount: try #require(m.uint("inactive")))
        }
        if let d = input.object("disk") {
            probe.diskReading = DiskReading(free: try #require(d.uint("free")), total: try #require(d.uint("total")))
        }
        probe.cycle = input.int("cycle")
        probe.boot = input.int("boot")
        probe.table = input.string("ps")
        return probe
    }

    /// Python's text, or the native text where the case records a deviation.
    static func want(_ c: M5Fixture.Case) throws -> String {
        c.expected.string("deviation") != nil ? try #require(c.expected.string("native_text"))
            : try #require(c.expected.string("text"))
    }

    @Test func fixtureHoldsEveryCase() throws {
        let cases = try M5Fixture.cases(Self.suite)
        #expect(cases.count == 51)
        let tools = Dictionary(grouping: cases) { $0.input.string("tool") ?? "" }.mapValues(\.count)
        #expect(tools == ["get_battery": 8, "get_cpu_usage": 9, "get_wifi_status": 5, "run_diagnostics": 29])
        // DEV-M5-01: top prints its hundredths unpadded; the native field is %.2f.
        let deviations = cases.filter { $0.expected.string("deviation") != nil }
        #expect(deviations.map(\.name) == ["cpu/whole_hundredths_zero", "cpu/unpadded_08",
                                           "cpu/unpadded_07_two_digit", "cpu/full_load", "diagnostics/cpu_unpadded"])
        #expect(deviations.allSatisfy { $0.expected.string("deviation") == "DEV-M5-01" })
    }

    @Test func goldenCasesThroughTheFormatters() async throws {
        for c in try M5Fixture.cases(Self.suite) {
            let probe = try Self.probe(c.input)
            let text: String
            switch try #require(c.input.string("tool")) {
            case "get_battery": text = SystemText.batteryReply(await probe.battery())
            case "get_cpu_usage": text = SystemText.cpu(await probe.cpuUserField())
            case "get_wifi_status": text = SystemText.wifi(await probe.wifiStatus())
            default:
                let now = try #require(c.input.double("now"))
                text = Diagnostics.report(await Diagnostics.gather(probe, clock: ManualClock(now)))
            }
            #expect(text == (try Self.want(c)), "\(c)")
        }
    }

    @Test func goldenCasesThroughTheGateway() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        for c in try M5Fixture.cases(Self.suite) {
            let clock = ManualClock(try #require(c.input.double("now")))
            let gateway = await M5Fixture.gateway(.fake(system: try Self.probe(c.input)), clock: clock, sandbox: sandbox)
            let turn = TurnContext(channel: .voice)
            let result = await gateway.call(try #require(c.input.string("tool")), JSONObject(), turn: turn,
                                            origin: .model(.claude))
            #expect(result.text == (try Self.want(c)), "\(c)")
            #expect(!result.isError, "\(c)")
            #expect(result.record.outcome == .ran, "\(c)")
            #expect(await turn.tainted == false, "\(c): none of the system tools taints the turn")
        }
    }

    /// The four bodies list the generated catalog entries, and nothing else changed.
    @Test func registeredSchemasAreTheCatalogEntries() async throws {
        let sandbox = try ToolCoreSandbox()
        defer { sandbox.remove() }
        let gateway = await M5Fixture.gateway(.fake(), sandbox: sandbox)
        let listed = await gateway.toolList()
        #expect(listed.map(\.name) == DataSourceMap.toolNames)
        for schema in [GetBattery.schema, GetCPUUsage.schema, GetWiFiStatus.schema, RunDiagnostics.schema] {
            let catalog = try #require(ToolCatalog.tools.first { $0.name == schema.name })
            #expect(schema == catalog)
            #expect(listed.first { $0.name == schema.name } == catalog)
        }
    }

    /// §3.5's IOPS mapping: each state gives the word pmset prints, so Python's map applies.
    @Test func batteryStateFromIOKitFlags() {
        #expect(BatteryState.from(isCharging: false, isCharged: false, isFinishingCharge: false, onACPower: false) == .discharging)
        #expect(BatteryState.from(isCharging: true, isCharged: false, isFinishingCharge: false, onACPower: true) == .charging)
        #expect(BatteryState.from(isCharging: false, isCharged: true, isFinishingCharge: false, onACPower: true) == .charged)
        #expect(BatteryState.from(isCharging: false, isCharged: false, isFinishingCharge: false, onACPower: true) == .acAttached)
        #expect(BatteryState.from(isCharging: true, isCharged: false, isFinishingCharge: true, onACPower: true) == .finishing)
        #expect(BatteryState.allCases.map(\.pmsetWord) == ["charging", "discharging", "charged", "AC", "finishing"])
    }

    @Test func pythonSplitAndFloatHelpers() {
        #expect(SystemText.splitOnce("  40.3 /a b/c  d ") == ["40.3", "/a b/c  d "])
        #expect(SystemText.splitOnce(" 12.0") == ["12.0"])
        #expect(SystemText.splitOnce("   ") == [])
        #expect(SystemText.pyFloat("12.5") == 12.5)
        #expect(SystemText.pyFloat("0x10") == nil)
        #expect(SystemText.pyFloat("") == nil)
        #expect(SystemText.pyFloat("1e3") == 1000)
        #expect(SystemText.floorDiv(-30, 86_400) == -1)
        #expect(SystemText.floorMod(-30, 86_400) == 86_370)
    }
}
