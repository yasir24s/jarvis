import AppKit
import JarvisTools

/// PA batch A, `_quit_all_apps()`: the running apps NSWorkspace lists, asked to quit
/// (`terminate`, which lets an app ask to save) by QuickReplies' rules.
@MainActor
enum QuickApps {
    static func quitAll() -> String {
        let apps = NSWorkspace.shared.runningApplications
        return QuickReplies.quitAll(apps: apps.map { (name: $0.localizedName ?? "", policy: $0.activationPolicy.rawValue) },
                                    terminate: { apps[$0].terminate() })
    }
}
