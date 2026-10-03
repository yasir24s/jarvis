import AppKit
import JarvisTools

/// TV tools: the TV app's process for `LiveTVAccessibility`, through AppKit (which JarvisTools
/// does not import): its pid from the running apps, and opening it with NSWorkspace.
struct LiveTVAppProcess: TVAppProcess {
    func pid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: LiveTVAccessibility.bundleID).first?.processIdentifier
    }

    func activate() async -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: LiveTVAccessibility.bundleID).first {
            return app.activate()
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return (try? await NSWorkspace.shared.openApplication(at: URL(filePath: LiveTVAccessibility.appPath),
                                                              configuration: config)) != nil
    }
}
