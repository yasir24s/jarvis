import Foundation
import JarvisCore
import JarvisTools

/// Batch C part 6: `JARVIS --probe-airplay`, the self-test's probe alone, headless: every rung
/// loads and looks up (classes, selectors, Music's dictionary, the Accessibility permission) and
/// prints what it covers. It starts nothing, discovers nothing and writes no state.
enum AirPlayProbeMain {
    static let flag = "--probe-airplay"

    static func run() -> Int32 {
        print("macOS build: \(DisplayRoutes.osBuild())")
        let rungs: [any DisplayRouteDriver] = [PrivateFrameworkRung(), ScriptableRung(), AccessibilityRung()]
        for p in rungs.map({ $0.probe() }) {
            print("\(p.kind.rawValue): covers " + (p.covers.isEmpty ? "nothing" : p.covers.map(\.rawValue).joined(separator: ", ")))
            for line in p.log { print("  \(line)") }
        }
        return 0
    }
}
