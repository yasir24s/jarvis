import AppKit
import JarvisChat
import SwiftUI

/// The menu-bar menu (plan: M02-M04 §3.12): Open Chat, the last backend, M0's state-root and
/// lock lines, and Quit.
struct MenuBarMenu: View {
    let model: AppModel
    let chat: ChatViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Chat") {
            openWindow(id: ChatView.windowID)
            NSApp.activate()
        }
        Text(chat.backendLine)
        // The "Speak replies" toggle (plan §3.12, the SpeakPolicy batch) goes here.
        Divider()
        Text("State: \(model.stateRoot)")
        Text("Lock: \(model.lockHolder)")
        Divider()
        Button("Quit JARVIS") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
