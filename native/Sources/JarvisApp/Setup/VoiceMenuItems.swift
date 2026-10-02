import AppKit
import JarvisVoice
import SwiftUI

/// M10 part 5: "Voice: enrolled" or "Voice: not enrolled", and "Forget My Voice…" while a
/// voiceprint is enrolled, in the app menu and the menu-bar menu.
struct VoiceMenuItems: View {
    let status: VoiceprintStatus
    let forget: () -> Void

    var body: some View {
        Text(status.menuLine)
        Button(ForgetMyVoice.menuTitle) { forget() }
            .disabled(!status.enrolled)
    }
}

/// Forget My Voice, behind a confirmation. On yes the voiceprint is deleted, with the one the
/// last enrolment kept, and the menus say not enrolled until a new one is recorded.
@MainActor
enum ForgetMyVoice {
    static let menuTitle = "Forget My Voice…"
    static let question = "Forget your voice?"
    static let detail = "JARVIS will delete your voiceprint, and the earlier one kept when you last recorded. "
        + "Until you record a new one with Set Up JARVIS…, he will not know your voice from anyone else's."
    static let confirmTitle = "Forget My Voice"

    /// The question as an alert: true for Forget My Voice, false for Cancel.
    static func askWithAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Asks, then forgets. True when the voiceprint was forgotten.
    @discardableResult
    static func run(ask: () -> Bool, voiceprint: Voiceprint?, status: VoiceprintStatus,
                    log: (String) -> Void = { _ in }) async -> Bool {
        guard status.enrolled, let voiceprint else { return false }
        guard ask() else {
            log("voice: Forget My Voice cancelled")
            return false
        }
        let reply = await voiceprint.forget()
        status.forgotten()
        log("voice: voiceprint forgotten (\(reply))")
        return true
    }
}
