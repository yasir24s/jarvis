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

/// PR2: the running apps for the fast path's quit commands (`_quit_app`, `_quit_kind`), read on
/// the main actor as QuickApps reads them.
struct LiveRunningApps: RunningAppsControlling {
    func runningApps() async -> [RunningApp] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map {
                RunningApp(name: $0.localizedName ?? "", regular: $0.activationPolicy == .regular,
                           pid: $0.processIdentifier)
            }
        }
    }

    func terminate(_ app: RunningApp) async -> Bool {
        await MainActor.run { NSRunningApplication(processIdentifier: app.pid)?.terminate() ?? false }
    }
}
