import Foundation
import IOKit.ps

/// W1 part 5: whether the Mac runs on its battery now (IOKit's providing power source), so the
/// background reading waits for mains power. A Mac with no battery is never on it.
public enum PowerSource {
    @Sendable public static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        else { return false }
        return type == kIOPMBatteryPowerKey
    }
}
