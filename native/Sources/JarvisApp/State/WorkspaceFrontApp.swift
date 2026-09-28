import AppKit
import JarvisCore

/// The real `FrontAppProviding` (plan: M01 §3.6, T13): jarvis.py `_front_app`, which reads
/// `NSWorkspace.sharedWorkspace().frontmostApplication()` and returns
/// `str(app.localizedName()) if app else ""`. NSWorkspace needs no TCC permission. The read
/// hops to the main actor, where AppKit state lives. A running app that has no localized name
/// reads as "None", exactly as Python's `str(None)` does (`AppContextLogic.frontAppName`, the
/// mapping the `m1_history_app` golden suite covers). No frontmost app reads as "".
struct WorkspaceFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String {
        await MainActor.run {
            let app = NSWorkspace.shared.frontmostApplication
            return AppContextLogic.frontAppName(appPresent: app != nil, localizedName: app?.localizedName)
        }
    }
}
