import Foundation
import JarvisCore

/// `get_battery` (plan: M05-M06 §2a, §3.5, A-SYS-1). Python: `_get_system_info("battery")`,
/// pmset's percentage and state word, or "No information." with no battery. The arguments are
/// ignored, as in Python.
struct GetBattery: ToolImpl {
    static let name = "get_battery"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let probe: any SystemProbing

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(SystemText.batteryReply(await probe.battery()))
    }
}

/// `get_cpu_usage` (A-SYS-3). Python: top's "user" percentage, or "CPU info unavailable.".
struct GetCPUUsage: ToolImpl {
    static let name = "get_cpu_usage"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let probe: any SystemProbing

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(SystemText.cpu(await probe.cpuUserField()))
    }
}

/// `get_wifi_status` (A-SYS-4, D-15). Python: networksetup's stdout, stripped, or
/// "Wi-Fi status unknown.".
struct GetWiFiStatus: ToolImpl {
    static let name = "get_wifi_status"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let probe: any SystemProbing

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(SystemText.wifi(await probe.wifiStatus()))
    }
}

/// `run_diagnostics` (A-SYS-5). Python: `_system_report`, each part dropped silently when it
/// fails. `clock` stands in for the `time.time()` of the uptime line.
struct RunDiagnostics: ToolImpl {
    static let name = "run_diagnostics"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let probe: any SystemProbing
    let clock: any JarvisClock

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        .text(Diagnostics.report(await Diagnostics.gather(probe, clock: clock)))
    }
}
