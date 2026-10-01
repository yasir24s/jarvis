import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Captures the main display. Tests inject a fake that returns a fixture image, so no test
/// captures the real screen.
protocol ScreenCapturing: Sendable {
    /// The main display without the cursor, as `screencapture -x` with one path captures it,
    /// or nil when Screen Recording is not granted or the capture fails.
    func captureMainDisplay() async -> CGImage?
}

/// ScreenCaptureKit (plan: M05-M06 §3.5): the shareable display whose ID is
/// `CGMainDisplayID()`, a filter that excludes no window, the display mode's pixel size and no
/// cursor, captured by `SCScreenshotManager`. `CGPreflightScreenCaptureAccess` is checked
/// first, so a missing grant gives Python's failure text instead of a capture attempt (it never
/// prompts; the grant is given in System Settings).
struct LiveScreenCapture: ScreenCapturing {
    func captureMainDisplay() async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        do {
            let content = try await SCShareableContent.current
            let main = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == main }) else { return nil }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            if let mode = CGDisplayCopyDisplayMode(main) {
                configuration.width = mode.pixelWidth
                configuration.height = mode.pixelHeight
            }
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }
}
