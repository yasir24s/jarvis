import JarvisChat
import SwiftUI

/// JARVIS as a regular Mac app (D-43, replacing the plan's menu-bar-only agent): a Dock icon,
/// Cmd-Tab, the standard app menu, the chat as the main window, and the menu-bar item.
/// Launched by `Entry.main()`, not `@main`, so the headless flags never create an
/// NSApplication.
struct JarvisSwiftUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window. It opens at launch unless the app was started with --background
        // (ChatLaunch), and is not restored from the last launch. Closing it leaves JARVIS
        // running; the Dock icon and the menu's Open Chat bring it back.
        Window("JARVIS", id: ChatView.windowID) {
            ChatView(model: appDelegate.chat, onAppear: { openWindow in
                appDelegate.openChat = { openWindow(id: ChatView.windowID) }
            })
        }
        .defaultLaunchBehavior(ChatLaunch.opensWindow(arguments: CommandLine.arguments) ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra("JARVIS", systemImage: "circle.hexagongrid.fill") {
            #if DEBUG
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat,
                        testConfirmation: { appDelegate.stashTestConfirmation() })
            #else
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat)
            #endif
        }
        .menuBarExtraStyle(.menu)
    }
}
