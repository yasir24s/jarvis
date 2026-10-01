import Foundation
import JarvisCore

/// The tool bodies that exist so far (B4: `get_time`; D-50: `personality_note` and
/// `personality_rewrite`; M5 T5.5: `get_battery`, `get_cpu_usage`, `get_wifi_status`,
/// `run_diagnostics`; T5.6: `read_clipboard`; T5.7: `see_screen`, `take_screenshot`), registered on a gateway in one call, so JarvisBrain and JarvisApp
/// never name a tool type. Every other catalog tool stays listed with no body, and the gateway
/// answers it with its unknown-tool text until M5 or M6 adds one.
public enum BuiltInTools {
    /// Registers every implemented body on `gateway`. `clock` and `timeZone` stand in for what
    /// Python's `datetime.now()` reads; the app passes the system's, tests pin both. `core` owns
    /// the personality file the two personality tools write (through its StateStore).
    public static func register(on gateway: ToolGateway, core: CoreState, clock: any JarvisClock,
                                timeZone: TimeZone) async {
        await register(on: gateway, core: core, clock: clock, timeZone: timeZone, platform: .live)
    }

    /// The same registration over `platform`, the machine-facing readers, so tests register
    /// every body over fakes.
    static func register(on gateway: ToolGateway, core: CoreState, clock: any JarvisClock,
                         timeZone: TimeZone, platform: ToolPlatform) async {
        await gateway.register(GetTime(clock: clock, timeZone: timeZone))
        await gateway.register(PersonalityNote(core: core))
        await gateway.register(PersonalityRewrite(core: core))
        await gateway.register(GetBattery(probe: platform.system))
        await gateway.register(GetCPUUsage(probe: platform.system))
        await gateway.register(GetWiFiStatus(probe: platform.system))
        await gateway.register(RunDiagnostics(probe: platform.system, clock: clock))
        await gateway.register(ReadClipboard(clipboard: platform.clipboard))
        await gateway.register(SeeScreen(capturer: platform.screen, recognizer: platform.recognizer))
        await gateway.register(TakeScreenshot(capturer: platform.screen, clock: clock, timeZone: timeZone,
                                              home: platform.home))
    }

    /// The generated `ToolCatalog` entry for `name`, so no body carries a hand-written schema.
    static func catalogSchema(named name: String) -> ToolSchema {
        ToolCatalog.tools.first { $0.name == name } ?? ToolSchema(name: name)
    }
}

/// What the M5 tool bodies read from the machine, behind protocols. `live` is the app's; tests
/// build one from fakes, so no test reads the real battery, pasteboard, screen or network.
struct ToolPlatform: Sendable {
    var system: any SystemProbing
    var clipboard: any ClipboardReading
    var screen: any ScreenCapturing
    var recognizer: any TextRecognizing
    /// `$HOME`, as Python's `os.path.expanduser` reads it.
    var home: String

    static var live: ToolPlatform {
        ToolPlatform(system: LiveSystemProbe(), clipboard: LivePasteboard(), screen: LiveScreenCapture(),
                     recognizer: VisionTextRecognizer(),
                     home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
    }
}
