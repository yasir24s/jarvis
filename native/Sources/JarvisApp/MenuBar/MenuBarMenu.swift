import AppKit
import JarvisBrain
import JarvisChat
import SwiftUI

/// The menu-bar menu (plan: M02-M04 §3.12): Open Chat, M10's "Set Up JARVIS…", "Voice: …" and
/// "Forget My Voice…", the last backend, the "Speak replies" toggle, M9a's "Brain" and B2's
/// ChatGPT sign-in, M8's "Stop Speaking", P6's "Learn About Me From My Files", UI1's
/// "Show HUD", U1's "Update Ready" and "Update Now" while a build waits, M0's state-root and lock
/// lines, and Quit. DEBUG builds add "Test confirmation".
struct MenuBarMenu: View {
    let model: AppModel
    let chat: ChatViewModel
    @Bindable var speak: SpeakRepliesToggle
    /// V5: "Speak First Sentence Early", after "Speak replies".
    let speakEarly: SpeakEarlySetting
    let brain: BrainSetting
    /// B2 part 6: JARVIS's own ChatGPT sign-in, the item after Brain.
    let chatgpt: ChatGPTAccount
    let learn: FileLearningConsent
    let showHUD: ShowHUDSetting
    let hud: HUDModel
    let updates: UpdateWatcher
    /// M10 part 5: the voiceprint's line and Forget My Voice (AppDelegate.forgetVoice).
    let voice: VoiceprintStatus
    let forgetVoice: () -> Void
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
        SetUpItem()
        VoiceMenuItems(status: voice, forget: forgetVoice)
        Text(chat.backendLine)
        // The input to the user's speak policy (SpeakPolicy.swift); it persists across launches.
        Toggle("Speak replies", isOn: $speak.isOn)
        SpeakEarlyToggle(setting: speakEarly)
        BrainPicker(setting: brain)
        ChatGPTSignInItem(account: chatgpt)
        Button("Stop Speaking") {
            stopSpeaking()
        }
        FileLearningToggle(consent: learn)
        ShowHUDToggle(setting: showHUD, hud: hud)
        HandsFreeMenuItems()   // M11 part 5
        UpdateMenuItems(updates: updates)
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

/// The app menu's items after About Jarvis (the CommandGroup in JarvisSwiftUIApp), as a view so
/// the tests can build the menu: M10's "Set Up JARVIS…", "Voice: …" and "Forget My Voice…",
/// M8's "Stop Speaking", M9a's "Brain", P6's file learning, UI1's
/// "Show HUD" and U1's update items, as in the menu-bar menu.
struct AppMenuItems: View {
    let stopSpeaking: () -> Void
    /// V5: "Speak First Sentence Early", after "Stop Speaking" (this menu has no "Speak replies").
    let speakEarly: SpeakEarlySetting
    let brain: BrainSetting
    let chatgpt: ChatGPTAccount
    let learn: FileLearningConsent
    let showHUD: ShowHUDSetting
    let hud: HUDModel
    let updates: UpdateWatcher
    let voice: VoiceprintStatus
    let forgetVoice: () -> Void

    var body: some View {
        SetUpItem()
        VoiceMenuItems(status: voice, forget: forgetVoice)
        Button("Stop Speaking") { stopSpeaking() }
        SpeakEarlyToggle(setting: speakEarly)
        BrainPicker(setting: brain)
        ChatGPTSignInItem(account: chatgpt)
        FileLearningToggle(consent: learn)
        ShowHUDToggle(setting: showHUD, hud: hud)
        HandsFreeMenuItems()   // M11 part 5
        UpdateMenuItems(updates: updates)
    }
}

/// M10 part 4: "Set Up JARVIS…", in the app menu and the menu-bar menu: the setup window again,
/// to re-record the voice or change a choice.
struct SetUpItem: View {
    static let title = "Set Up JARVIS…"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(Self.title) {
            openWindow(id: SetupView.windowID)
            NSApp.activate()
        }
    }
}

/// M9a part 7: "Brain", with Claude, ChatGPT (B2) and On-device and a checkmark on the current
/// one, in the app menu and the menu-bar menu. A brain switched off for the launch
/// (`JARVIS_USE_CLAUDE=0`, `JARVIS_USE_CHATGPT=0`) has its entry disabled, and a pick of it shows
/// On-device; with both off the item is disabled. The help says why.
struct BrainPicker: View {
    @Bindable var setting: BrainSetting

    var body: some View {
        Picker(BrainSetting.menuTitle, selection: Binding(get: { setting.shown }, set: { setting.choice = $0 })) {
            ForEach(BrainChoice.allCases, id: \.self) { choice in
                Text(BrainSetting.title(choice)).tag(choice)
                    .selectionDisabled(setting.isOff(choice))
            }
        }
        .disabled(setting.allOff)
        .help(setting.help)
    }
}

/// B2 part 6: right after "Brain" in both menus: "Sign in to ChatGPT…" (or "Cancel ChatGPT
/// Sign-in" while the browser flow runs), and once JARVIS's own Codex home is signed in, the
/// disabled line "Signed in to ChatGPT" (`ChatGPTAccount`).
struct ChatGPTSignInItem: View {
    let account: ChatGPTAccount

    var body: some View {
        if account.actionable {
            Button(account.title) { account.act() }
                .help(account.help)
        } else {
            Text(account.title)
                .help(account.help)
        }
    }
}

/// P6: "Learn About Me From My Files", with a checkmark while it is on, in the app menu and the
/// menu-bar menu. Switching it changes what the file scanner may read at once.
struct FileLearningToggle: View {
    @Bindable var consent: FileLearningConsent

    var body: some View {
        Toggle(FileLearningConsent.menuTitle, isOn: $consent.isOn)
    }
}

/// U1: while a staged build waits, "Update Ready" and "Update Now", in the app menu and the
/// menu-bar menu. Once Update Now is chosen the item says what the swap still waits for.
struct UpdateMenuItems: View {
    let updates: UpdateWatcher

    var body: some View {
        if updates.ready != nil, !updates.swapping {
            Divider()
            Text("Update Ready")
            if updates.updateNowRequested {
                Text("Update Now: waiting, \(updates.hold?.reason ?? "almost done")")
            } else {
                Button("Update Now") {
                    updates.updateNow()
                }
            }
        }
    }
}

/// UI1 part 3: "Show HUD", with a checkmark while it is on, in the app menu and the menu-bar
/// menu. Switching it off hides the HUD at once.
struct ShowHUDToggle: View {
    @Bindable var setting: ShowHUDSetting
    let hud: HUDModel

    var body: some View {
        Toggle(ShowHUDSetting.menuTitle, isOn: Binding(get: { setting.isOn }, set: { on in
            setting.isOn = on
            hud.enabled = on
        }))
    }
}
