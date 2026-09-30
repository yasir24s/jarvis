import Foundation
import JarvisCore

/// The battery state word pmset prints after `NN%;`, which `_get_system_info("battery")`
/// captures with `(\d+)%;?\s*(\w+)` (plan: M05-M06 §2a, §3.5). The native probe reads IOKit and
/// names the state the way pmset would, so Python's word map applies unchanged.
enum BatteryState: String, Sendable, Equatable, CaseIterable {
    case charging, discharging, charged, acAttached, finishing

    /// What the regex's `(\w+)` captures from pmset's phrase ("AC attached" -> "AC",
    /// "finishing charge" -> "finishing").
    var pmsetWord: String {
        switch self {
        case .charging: "charging"
        case .discharging: "discharging"
        case .charged: "charged"
        case .acAttached: "AC"
        case .finishing: "finishing"
        }
    }

    /// §3.5's mapping from the IOPS description. Finishing wins over charging (pmset shows
    /// "finishing charge" for a charge that is still running), a full charge over plain AC.
    static func from(isCharging: Bool, isCharged: Bool, isFinishingCharge: Bool, onACPower: Bool) -> BatteryState {
        if isFinishingCharge { return .finishing }
        if isCharging { return .charging }
        if isCharged { return .charged }
        if onACPower { return .acAttached }
        return .discharging
    }
}

struct BatteryReading: Sendable, Equatable {
    let percent: Int
    let state: BatteryState
}

/// `host_statistics64(HOST_VM_INFO64)` and `hw.memsize`. vm_stat's "Pages free" is
/// `freeCount - speculativeCount`; `_system_report` adds "Pages inactive" to it.
struct MemoryReading: Sendable, Equatable {
    let memsize: UInt64
    let pageSize: UInt64
    let freeCount: UInt64
    let speculativeCount: UInt64
    let inactiveCount: UInt64
}

/// `statvfs(home)`, as `shutil.disk_usage`: free = f_bavail·f_frsize, total = f_blocks·f_frsize.
struct DiskReading: Sendable, Equatable {
    let free: UInt64
    let total: UInt64
}

/// The machine readings the system tools format. The live probe reads IOKit, Mach, sysctl,
/// statvfs, CoreWLAN and `ps`; tests inject fakes, so no test reads the real battery,
/// processor, disk or network.
protocol SystemProbing: Sendable {
    /// The first internal battery, or nil when there is none (pmset prints no `NN%;` line).
    func battery() async -> BatteryReading?
    /// top's "user" field as the reply prints it ("18.97"), or nil when there is no reading.
    func cpuUserField() async -> String?
    /// `networksetup -getairportnetwork en0` stdout, unstripped ("" when unknown).
    func wifiStatus() async -> String
    func memory() async -> MemoryReading?
    func disk() async -> DiskReading?
    /// ioreg's `"CycleCount" = N` on AppleSmartBattery, or nil.
    func batteryCycleCount() async -> Int?
    /// `kern.boottime`'s `sec`, or nil.
    func bootTime() async -> Int?
    /// `ps -Aro %cpu,comm` stdout decoded as `text=True` would, or nil when it failed.
    func processTable() async -> String?
}

/// The Python-exact sentences of `_get_system_info` (jarvis.py 1285-1333) and `_system_report`
/// (3312-3363). Pure: the golden suite m5_sysinfo feeds these the numbers the fixture holds.
enum SystemText {
    static let noInformation = "No information."

    /// `f"Battery at {m.group(1)} percent, {st}."` with the charging/discharging/charged map
    /// (keyed on the lowercased word; any other word is kept as captured).
    static func battery(_ reading: BatteryReading?) -> String? {
        guard let reading else { return nil }
        let word = reading.state.pmsetWord
        let map = ["charging": "charging", "discharging": "on battery", "charged": "fully charged"]
        return "Battery at \(reading.percent) percent, \(map[Py.lower(word)] ?? word)."
    }

    /// `" ".join(parts) or "No information."` for a single part.
    static func batteryReply(_ reading: BatteryReading?) -> String {
        battery(reading) ?? noInformation
    }

    static func cpu(_ field: String?) -> String {
        field.map { "CPU user load \($0) percent." } ?? "CPU info unavailable."
    }

    /// The native reading's field: `%.2f` of the user share (§3.5). top prints its hundredths
    /// unpadded (4.08 as "4.8"); the native field does not copy that (DEV-M5-01).
    static func cpuField(userPercent: Double) -> String {
        String(format: "%.2f", userPercent)
    }

    /// `r.stdout.strip() or "Wi-Fi status unknown."`.
    static func wifi(_ stdout: String) -> String {
        let text = Py.strip(stdout)
        return text.isEmpty ? "Wi-Fi status unknown." : text
    }

    /// `f"Memory, {used:.1f} of {total / (1024 ** 3):.0f} gigabytes in use."`.
    static func memory(_ m: MemoryReading) -> String {
        // Python works in exact integers and divides once; below 2^53 these doubles are exact.
        let freePages = Int64(m.freeCount) - Int64(m.speculativeCount) + Int64(m.inactiveCount)
        let used = (Double(m.memsize) - Double(freePages) * Double(m.pageSize)) / 1_073_741_824
        return "Memory, \(fixed(used, 1)) of \(fixed(Double(m.memsize) / 1_073_741_824, 0)) gigabytes in use."
    }

    /// `f"Disk, {du.free / (1024 ** 3):.0f} gigabytes free of {du.total / (1024 ** 3):.0f}."`.
    static func disk(_ d: DiskReading) -> String {
        "Disk, \(fixed(Double(d.free) / 1_073_741_824, 0)) gigabytes free of \(fixed(Double(d.total) / 1_073_741_824, 0))."
    }

    /// `up = int(time.time()) - boot`, then Python's floor `//` and `%`.
    static func uptime(boot: Int, now: Double) -> String {
        let up = Int(now.rounded(.towardZero)) - boot
        let d = floorDiv(up, 86_400), h = floorDiv(floorMod(up, 86_400), 3_600)
        let dd = "\(d) day\(d != 1 ? "s" : "")", hh = "\(h) hour\(h != 1 ? "s" : "")"
        return d != 0 ? "Uptime \(dd) \(hh)." : "Uptime \(hh)."
    }

    /// `ps[1].split(None, 1)` → cpu, comm; `basename(comm.strip())`, `float(cpu):.0f`. Nil
    /// wherever Python raises (fewer than two lines or fields, a cpu `float()` rejects), which
    /// `_system_report`'s try drops.
    static func heaviestProcess(_ table: String) -> String? {
        let lines = Py.splitlines(table)
        guard lines.count > 1 else { return nil }
        let fields = splitOnce(lines[1])
        guard fields.count == 2, let cpu = pyFloat(fields[0]) else { return nil }
        let comm = Py.strip(fields[1])
        let name = comm.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? comm
        return "Heaviest process, \(name) at \(fixed(cpu, 0)) percent."
    }

    /// Python's `format(x, ".Nf")`: correctly rounded from the binary value, ties to even,
    /// which is what Darwin's printf does too.
    static func fixed(_ x: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", x)
    }

    /// `s.split(None, 1)`: leading whitespace dropped, one cut at the first whitespace run,
    /// the rest kept from its first non-space character (trailing whitespace included).
    static func splitOnce(_ s: String) -> [String] {
        let scalars = Array(s.unicodeScalars)
        var i = 0
        while i < scalars.count, Py.isSpace(scalars[i]) { i += 1 }
        guard i < scalars.count else { return [] }
        var j = i
        while j < scalars.count, !Py.isSpace(scalars[j]) { j += 1 }
        let head = String(String.UnicodeScalarView(scalars[i..<j]))
        var k = j
        while k < scalars.count, Py.isSpace(scalars[k]) { k += 1 }
        guard k < scalars.count else { return [head] }
        return [head, String(String.UnicodeScalarView(scalars[k...]))]
    }

    /// Python `float(token)` for the decimal forms `ps` prints: optional sign, digits with at
    /// most one point, optional exponent, and inf/nan words. Hex and underscores are refused
    /// (Swift's parser would take hex, Python's `float` does not).
    static func pyFloat(_ token: String) -> Double? {
        let t = Py.strip(token)
        let body = t.hasPrefix("-") || t.hasPrefix("+") ? String(t.dropFirst()) : t
        let lowered = body.lowercased()
        if ["inf", "infinity", "nan"].contains(lowered) { return Double(t.lowercased()) }
        guard !body.isEmpty, body.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) || $0 == "." || $0 == "e" || $0 == "E" || $0 == "-" || $0 == "+" }),
              body.first != "e", body.first != "E" else { return nil }
        return Double(t)
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    static func floorMod(_ a: Int, _ b: Int) -> Int {
        a - floorDiv(a, b) * b
    }
}

/// `_system_report`'s readings, gathered in its order.
struct DiagnosticsReading: Sendable, Equatable {
    var cpuField: String?
    var memory: MemoryReading?
    var disk: DiskReading?
    var battery: BatteryReading?
    var cycleCount: Int?
    var bootTime: Int?
    var now: Double
    var processTable: String?
    var wifi: String
}

enum Diagnostics {
    /// `" ".join(p for p in parts if p)` over Python's parts, each dropped where Python's own
    /// try would drop it. The battery part is `_get_system_info("battery")`, so a Mac with no
    /// battery says "No information." here too.
    static func report(_ r: DiagnosticsReading) -> String {
        var parts = ["Diagnostics complete.", SystemText.cpu(r.cpuField)]
        if let m = r.memory { parts.append(SystemText.memory(m)) }
        if let d = r.disk { parts.append(SystemText.disk(d)) }
        parts.append(SystemText.batteryReply(r.battery))
        if let cycle = r.cycleCount { parts.append("Battery cycle count \(cycle).") }
        if let boot = r.bootTime { parts.append(SystemText.uptime(boot: boot, now: r.now)) }
        if let table = r.processTable, let heaviest = SystemText.heaviestProcess(table) { parts.append(heaviest) }
        parts.append(SystemText.wifi(r.wifi))
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Reads every part from `probe`, in `_system_report`'s order (the CPU sample first).
    static func gather(_ probe: any SystemProbing, clock: any JarvisClock) async -> DiagnosticsReading {
        let cpu = await probe.cpuUserField()
        let memory = await probe.memory()
        let disk = await probe.disk()
        let battery = await probe.battery()
        let cycle = await probe.batteryCycleCount()
        let boot = await probe.bootTime()
        let now = clock.now()
        let table = await probe.processTable()
        let wifi = await probe.wifiStatus()
        return DiagnosticsReading(cpuField: cpu, memory: memory, disk: disk, battery: battery, cycleCount: cycle,
                                  bootTime: boot, now: now, processTable: table, wifi: wifi)
    }
}
