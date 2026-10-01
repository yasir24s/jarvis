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
            }, onWindow: { appDelegate.chatWindowAppeared($0) })
        }
        // U1: after a live update the window is open only if it was before the swap.
        .defaultLaunchBehavior(ChatLaunch.opensWindow(arguments: CommandLine.arguments,
                                                      resume: AppDelegate.resumeAtLaunch?.state) ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            // The app menu's "Stop Speaking" (M8), the same as the menu-bar item.
            CommandGroup(after: .appInfo) {
                Button("Stop Speaking") { appDelegate.stopSpeaking() }
                // P6: the user's consent to learning from their files, as in the menu-bar menu.
                FileLearningToggle(consent: appDelegate.fileLearning)
                // U1: "Update Ready" and "Update Now" while a staged build waits.
                UpdateMenuItems(updates: appDelegate.updates)
            }
        }

        MenuBarExtra("JARVIS", systemImage: "circle.hexagongrid.fill") {
            #if DEBUG
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat, speak: appDelegate.speakReplies,
                        learn: appDelegate.fileLearning, updates: appDelegate.updates,
                        stopSpeaking: { appDelegate.stopSpeaking() },
                        testConfirmation: { appDelegate.stashTestConfirmation() })
            #else
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat, speak: appDelegate.speakReplies,
                        learn: appDelegate.fileLearning, updates: appDelegate.updates,
                        stopSpeaking: { appDelegate.stopSpeaking() })
            #endif
        }
        .menuBarExtraStyle(.menu)
    }
}
