import AppKit
import JarvisTools

/// TV tools: the TV app's process for `LiveTVAccessibility`, through AppKit (which JarvisTools
/// does not import): its pid from the running apps, opening it with NSWorkspace, and the
/// click and scroll events for elements that list no AX actions.
struct LiveTVAppProcess: TVAppProcess {
    func pid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: LiveTVAccessibility.bundleID).first?.processIdentifier
    }

    /// Brings TV forward, launching it if needed. Success means TV is running: macOS's cooperative
    /// activation can refuse `NSRunningApplication.activate()` from an app that isn't frontmost, so
    /// its Bool is not a failure signal. Opening through NSWorkspace brings a running app forward too.
    func activate() async -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: LiveTVAccessibility.bundleID).first?.activate()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: URL(filePath: LiveTVAccessibility.appPath),
                                                          configuration: config)
        return pid() != nil
    }

    /// A left click (down, then up) at a screen point, through the HID event tap.
    func click(x: Double, y: Double) async -> Bool {
        let point = CGPoint(x: x, y: y)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return false }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// A horizontal scroll (pixels; negative scrolls the content left, showing what is to the
    /// right) at a screen point.
    func scroll(horizontal: Int, x: Double, y: Double) async -> Bool {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                  wheel1: 0, wheel2: Int32(horizontal), wheel3: 0) else { return false }
        event.location = CGPoint(x: x, y: y)
        event.post(tap: .cghidEventTap)
        return true
    }
}
