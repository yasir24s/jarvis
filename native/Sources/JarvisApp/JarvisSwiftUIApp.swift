import SwiftUI

/// The menu-bar agent (plan: M00 §3.9). Launched by `Entry.main()`, not `@main`, so the
/// headless flags never create an NSApplication. M0 only needs the menu to be observable;
/// M4 grows it.
struct JarvisSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("JARVIS", systemImage: "circle.hexagongrid") {
            JarvisMenu(model: appDelegate.model)
        }
    }
}

private struct JarvisMenu: View {
    let model: AppModel

    var body: some View {
        Text("State: \(model.stateRoot)")
        Text("Lock: \(model.lockHolder)")
        Divider()
        Button("Quit JARVIS") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
