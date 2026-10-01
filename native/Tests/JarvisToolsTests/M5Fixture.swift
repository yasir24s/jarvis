import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// The M5 awareness golden fixtures (tools/golden_m5_*.py), found from #filePath because this
/// target has no JarvisTestSupport.
enum M5Fixture {
    struct Case: Sendable, CustomStringConvertible {
        let name: String
        let input: JSONObject
        let expected: JSONObject
        var description: String { name }
    }

    static func url(_ suite: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Fixtures/golden/\(suite).golden.json")
    }

    static func envelope(_ suite: String) throws -> JSONObject {
        let envelope = try #require(try PyJSON.loads(Data(contentsOf: url(suite))).objectValue)
        #expect(envelope["suite"]?.stringValue == suite)
        return envelope
    }

    static func cases(_ suite: String) throws -> [Case] {
        try #require(envelope(suite)["cases"]?.arrayValue).map { value in
            let c = try #require(value.objectValue)
            return Case(name: try #require(c["name"]?.stringValue),
                        input: try #require(c["input"]?.objectValue),
                        expected: try #require(c["expected"]?.objectValue))
        }
    }

    /// A gateway with every built-in body registered over `platform`.
    static func gateway(_ platform: ToolPlatform, clock: any JarvisClock = ManualClock(0),
                        sandbox: ToolCoreSandbox) async -> ToolGateway {
        let gateway = ToolGateway(confirmationGate: ConfirmationGate(), log: { _ in })
        await BuiltInTools.register(on: gateway, core: sandbox.core, clock: clock,
                                    timeZone: TimeZone(identifier: "Europe/London")!, platform: platform)
        return gateway
    }
}

extension JSONObject {
    func int(_ key: String) -> Int? { if case .int(let i)? = self[key] { Int(i) } else { nil } }
    func uint(_ key: String) -> UInt64? { int(key).map { UInt64($0) } }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func object(_ key: String) -> JSONObject? { self[key]?.objectValue }
    func double(_ key: String) -> Double? { self[key]?.pyFloat }
}

/// Canned machine readings. Every M5 test that needs the platform gets this, never the live
/// probe, so no test reads the real battery, processor, disk, Wi-Fi or process table.
struct FakeSystemProbe: SystemProbing {
    var batteryReading: BatteryReading?
    var cpu: String?
    var wifi = ""
    var memoryReading: MemoryReading?
    var diskReading: DiskReading?
    var cycle: Int?
    var boot: Int?
    var table: String?

    func battery() async -> BatteryReading? { batteryReading }
    func cpuUserField() async -> String? { cpu }
    func wifiStatus() async -> String { wifi }
    func memory() async -> MemoryReading? { memoryReading }
    func disk() async -> DiskReading? { diskReading }
    func batteryCycleCount() async -> Int? { cycle }
    func bootTime() async -> Int? { boot }
    func processTable() async -> String? { table }
}

/// A canned pasteboard: the plain-text flavor bytes, or nil for none. Counts its reads.
final class FakeClipboard: ClipboardReading, @unchecked Sendable {
    private let lock = NSLock()
    private let data: Data?
    private var count = 0

    init(_ data: Data?) { self.data = data }

    var reads: Int { lock.withLock { count } }

    func plainTextData() async -> Data? {
        lock.withLock { count += 1 }
        return data
    }
}

extension ToolPlatform {
    /// Fakes for everything; each test swaps in the reader it exercises.
    static func fake(system: any SystemProbing = FakeSystemProbe(),
                     clipboard: any ClipboardReading = FakeClipboard(nil)) -> ToolPlatform {
        ToolPlatform(system: system, clipboard: clipboard)
    }
}
