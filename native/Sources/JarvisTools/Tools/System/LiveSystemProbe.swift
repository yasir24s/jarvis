import CoreWLAN
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// The real machine readings (plan: M05-M06 §3.5). Structured sources replace Python's five
/// command spawns: IOKit power sources and the AppleSmartBattery registry entry, Mach host
/// statistics, sysctl, statvfs and CoreWLAN. Only the heaviest-process line keeps `ps`, because
/// the kernel's decayed %cpu is not exposed any other way. Never used by tests.
struct LiveSystemProbe: SystemProbing {
    var runner: any CommandRunning = BoundedRunner()
    /// Where `shutil.disk_usage(os.path.expanduser("~"))` looks: $HOME, as Python reads it.
    var home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()

    func battery() async -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        // pmset lists the internal battery first; the regex takes the first `NN%;` it meets.
        let batteries = descriptions.filter { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let battery = (batteries.isEmpty ? descriptions : batteries).first(where: {
            $0[kIOPSCurrentCapacityKey] is Int && ($0[kIOPSMaxCapacityKey] as? Int ?? 0) > 0
        }), let current = battery[kIOPSCurrentCapacityKey] as? Int,
              let maximum = battery[kIOPSMaxCapacityKey] as? Int else { return nil }
        let percent = Int((Double(current) / Double(maximum) * 100).rounded())
        let state = BatteryState.from(
            isCharging: battery[kIOPSIsChargingKey] as? Bool ?? false,
            isCharged: battery[kIOPSIsChargedKey] as? Bool ?? false,
            isFinishingCharge: battery[kIOPSIsFinishingChargeKey] as? Bool ?? false,
            onACPower: battery[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        return BatteryReading(percent: percent, state: state)
    }

    /// Two `HOST_CPU_LOAD_INFO` samples one second apart, as top's single sample takes about a
    /// second; the user share of all ticks, `%.2f`. Falls back to top's own field.
    func cpuUserField() async -> String? {
        if let first = Self.cpuTicks() {
            try? await Task.sleep(for: .seconds(1))
            if let second = Self.cpuTicks() {
                let delta = zip(second, first).map { $0 &- $1 }
                let total = delta.reduce(0, +)
                if total > 0 {
                    return SystemText.cpuField(userPercent: Double(delta[Int(CPU_STATE_USER)]) / Double(total) * 100)
                }
            }
        }
        guard let output = await runner.run(["/usr/bin/top", "-l", "1", "-n", "0"], timeout: 30),
              let text = String(validating: output.stdout, as: UTF8.self),
              let match = text.firstMatch(of: /CPU usage: ([\d.]+)%/) else { return nil }
        return String(match.1)
    }

    /// `[user, system, idle, nice]` ticks summed over every processor.
    static func cpuTicks() -> [UInt64]? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return [UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)]
    }

    /// networksetup's two forms, from CoreWLAN (D-15; the SSID needs the Location grant, and
    /// without it CoreWLAN reports none, like the broken oracle). No Wi-Fi interface: "".
    func wifiStatus() async -> String {
        guard let interface = CWWiFiClient.shared().interface() else { return "" }
        if let ssid = interface.ssid(), !ssid.isEmpty { return "Current Wi-Fi Network: \(ssid)" }
        return "You are not associated with an AirPort network."
    }

    func memory() async -> MemoryReading? {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0 else { return nil }
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        // vm_stat's "page size of N bytes" is the host page size.
        var pageSize: vm_size_t = 0
        guard result == KERN_SUCCESS, host_page_size(host, &pageSize) == KERN_SUCCESS else { return nil }
        return MemoryReading(memsize: memsize, pageSize: UInt64(pageSize),
                             freeCount: UInt64(vm.free_count), speculativeCount: UInt64(vm.speculative_count),
                             inactiveCount: UInt64(vm.inactive_count))
    }

    func disk() async -> DiskReading? {
        var st = statvfs()
        guard statvfs(home, &st) == 0 else { return nil }
        return DiskReading(free: UInt64(st.f_bavail) * UInt64(st.f_frsize),
                           total: UInt64(st.f_blocks) * UInt64(st.f_frsize))
    }

    func batteryCycleCount() async -> Int? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "CycleCount" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return value as? Int
    }

    func bootTime() async -> Int? {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, u_int(mib.count), &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Int(boot.tv_sec)
    }

    /// Python runs `ps` with a 5 s timeout and `text=True`: a timeout or undecodable output
    /// drops the line.
    func processTable() async -> String? {
        guard let output = await runner.run(["/bin/ps", "-Aro", "%cpu,comm"], timeout: 5), output.completed,
              let text = String(validating: output.stdout, as: UTF8.self) else { return nil }
        return text
    }
}
