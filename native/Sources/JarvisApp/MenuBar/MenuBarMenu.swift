import AppKit
import JarvisChat
import SwiftUI

/// The menu-bar menu (plan: M02-M04 §3.12): Open Chat, the last backend, the "Speak replies"
/// toggle, M8's "Stop Speaking", M0's state-root and lock lines, and Quit. DEBUG builds add
/// "Test confirmation".
struct MenuBarMenu: View {
    let model: AppModel
    let chat: ChatViewModel
    @Bindable var speak: SpeakRepliesToggle
    /// Stops the reply being spoken and anything queued (AppDelegate.stopSpeaking).
    let stopSpeaking: () -> Void
    #if DEBUG
    /// Stashes the harmless test confirmation (`TestConfirmation`); DEBUG builds only.
    let testConfirmation: () -> Void
    #endif
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Chat") {
            openWindow(id: ChatView.windowID)
            NSApp.activate()
        }
        Text(chat.backendLine)
        // The input to the user's speak policy (SpeakPolicy.swift); it persists across launches.
        Toggle("Speak replies", isOn: $speak.isOn)
        Button("Stop Speaking") {
            stopSpeaking()
        }
        Divider()
        Text("State: \(model.stateRoot)")
        Text("Lock: \(model.lockHolder)")
        #if DEBUG
        Divider()
        Button(TestConfirmation.menuTitle) {
            testConfirmation()
            openWindow(id: ChatView.windowID)
            NSApp.activate()
        }
        #endif
        Divider()
        Button("Quit JARVIS") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
