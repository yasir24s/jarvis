import CoreGraphics
import Foundation
import ImageIO
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

/// A screen that "captures" a fixture image (or fails). Counts its captures.
final class FixtureScreen: ScreenCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private let image: CGImage?
    private var count = 0

    init(_ image: CGImage?) { self.image = image }

    /// A PNG from Tests/Fixtures/golden, decoded the way `_ocr_image` decodes it.
    convenience init(fixture relative: String?) throws {
        guard let relative else { self.init(nil); return }
        self.init(try FixtureScreen.decode(relative))
    }

    static func decode(_ relative: String) throws -> CGImage {
        let url = M5Fixture.url("x").deletingLastPathComponent().appending(path: relative)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    var captures: Int { lock.withLock { count } }

    func captureMainDisplay() async -> CGImage? {
        lock.withLock { count += 1 }
        return image
    }
}

/// Canned OCR text, for the reply rules the fixture images cannot reach. Counts its calls.
final class FakeRecognizer: TextRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let text: String
    private var count = 0

    init(_ text: String) { self.text = text }

    var calls: Int { lock.withLock { count } }

    func recognizeText(in image: CGImage) async -> String {
        lock.withLock { count += 1 }
        return text
    }
}

/// A child-process runner that never starts a process: each call gets the next canned output
/// (the last one repeats), and every argv is recorded.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [ProcessOutput?]
    private var recorded: [[String]] = []

    init(_ outputs: [ProcessOutput?]) { self.outputs = outputs }

    /// One successful run that prints `stdout`.
    convenience init(stdout: String) {
        self.init([ProcessOutput(stdout: Data(stdout.utf8), stderr: Data(), status: 0, timedOut: false, truncated: false)])
    }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ argv: [String], timeout: Double) async -> ProcessOutput? {
        lock.withLock {
            recorded.append(argv)
            return outputs.count > 1 ? outputs.removeFirst() : outputs.first ?? nil
        }
    }
}

struct StubBrowser: DefaultBrowserLookup {
    var name = ""
    func defaultBrowserName() async -> String { name }
}

extension ToolPlatform {
    /// Fakes for everything; each test swaps in the reader it exercises. The default home is a
    /// path that does not exist, so nothing can be written under it by accident, and the
    /// default app index lists nothing.
    static func fake(system: any SystemProbing = FakeSystemProbe(),
                     clipboard: any ClipboardReading = FakeClipboard(nil),
                     screen: any ScreenCapturing = FixtureScreen(nil),
                     recognizer: any TextRecognizing = FakeRecognizer(""),
                     home: String = "/nonexistent/jarvis-test-home",
                     apps: AppIndex = AppIndex(runner: FakeRunner(stdout: ""), loadPlist: { _ in nil }),
                     browser: any DefaultBrowserLookup = StubBrowser(),
                     spotlightRunner: any CommandRunning = FakeRunner(stdout: ""),
                     userHome: @escaping @Sendable (String) -> String? = { _ in nil }) -> ToolPlatform {
        ToolPlatform(system: system, clipboard: clipboard, screen: screen, recognizer: recognizer, home: home,
                     apps: apps, browser: browser, spotlightRunner: spotlightRunner, userHome: userHome,
                     commandRunner: FakeRunner(stdout: ""), scriptRunner: FakeStdinRunner())
    }
}

actor FakeStdinRunner: StdinCommandRunning {
    struct Call: Sendable, Equatable { let argv: [String]; let input: Data; let timeout: Double }
    var calls: [Call] = []
    var output: ProcessOutput?
    init(output: ProcessOutput? = ProcessOutput(stdout: Data(), stderr: Data(), status: 0,
                                               timedOut: false, truncated: false)) { self.output = output }
    func run(_ argv: [String], timeout: Double) async -> ProcessOutput? {
        await run(argv, input: Data(), timeout: timeout)
    }
    func run(_ argv: [String], input: Data, timeout: Double) async -> ProcessOutput? {
        calls.append(Call(argv: argv, input: input, timeout: timeout))
        return output
    }
}
