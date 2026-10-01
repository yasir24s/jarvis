import Foundation

/// Whether the Mac is in a state for background reading (D-51 P3): the file scanner backs off
/// while the thermal state is serious or critical, or Low Power Mode is on.
public struct PowerConditions: Sendable, Equatable {
    public var thermal: ProcessInfo.ThermalState
    public var lowPowerMode: Bool

    public init(thermal: ProcessInfo.ThermalState = .nominal, lowPowerMode: Bool = false) {
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }

    public var allowsBackgroundWork: Bool {
        !lowPowerMode && thermal != .serious && thermal != .critical
    }

    @Sendable public static func current() -> PowerConditions {
        let info = ProcessInfo.processInfo
        return PowerConditions(thermal: info.thermalState, lowPowerMode: info.isLowPowerModeEnabled)
    }
}
