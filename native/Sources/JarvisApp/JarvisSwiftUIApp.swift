import SwiftUI

/// The menu-bar agent (plan: M00 §3.9, M02-M04 §3.12). Launched by `Entry.main()`, not
/// `@main`, so the headless flags never create an NSApplication. The menu opens the chat
/// window; there is no Dock icon (`.accessory`, and `LSUIElement` in the bundle).
struct JarvisSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("JARVIS", systemImage: "circle.hexagongrid.fill") {
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat)
        }
        .menuBarExtraStyle(.menu)

        // Opened from the menu only: not at launch, and not restored at the next launch.
        Window("JARVIS", id: ChatView.windowID) {
            ChatView(model: appDelegate.chat)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
