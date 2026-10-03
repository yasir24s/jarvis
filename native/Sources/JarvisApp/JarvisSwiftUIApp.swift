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
            ChatView(model: appDelegate.chat, talk: appDelegate.talk, onAppear: { openWindow in
                appDelegate.openChat = { openWindow(id: ChatView.windowID) }
            }, onWindow: { appDelegate.chatWindowAppeared($0) })
        }
        // U1: after a live update the window is open only if it was before the swap. M11: Mic
        // Only Mode keeps it closed.
        .defaultLaunchBehavior(ChatLaunch.opensWindow(arguments: CommandLine.arguments,
                                                      resume: AppDelegate.resumeAtLaunch?.state)
                               && !HandsFreeSettings.micOnlyAtLaunch() ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .commands {
            // The app menu's "Stop Speaking" (M8), M9a's "Brain", P6's file learning, UI1's
            // "Show HUD" and U1's update items, as in the menu-bar menu.
            CommandGroup(after: .appInfo) {
                AppMenuItems(stopSpeaking: { appDelegate.stopSpeaking() }, speakEarly: appDelegate.speakEarly, brain: appDelegate.brainSetting,
                             chatgpt: appDelegate.chatgptAccount, learn: appDelegate.fileLearning, showHUD: appDelegate.showHUD,
                             hud: appDelegate.hud, briefing: appDelegate.morningBriefing, updates: appDelegate.updates, voice: appDelegate.voiceStatus,
                             forgetVoice: { appDelegate.forgetVoice() }, openMemory: { appDelegate.openMemory() }, quietHours: appDelegate.quietHours,
                        openLearningSources: { appDelegate.openLearningSources() },
                        checkAirPlay: { appDelegate.checkAirPlay() }, repairAirPlay: { appDelegate.repairAirPlay() },
                        mute: appDelegate.speechMute, resumeSpeaking: { appDelegate.resumeSpeaking() })
            }
        }

        // M10 part 4: the first-launch setup, while `setupCompleted` is absent, and from the
        // menus' "Set Up JARVIS…".
        Window("Set Up JARVIS", id: SetupView.windowID) {
            SetupView(model: appDelegate.setup)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(SetupCompletion.opensAtLaunch(arguments: CommandLine.arguments) ? .presented : .suppressed)
        .restorationBehavior(.disabled)

        // Stop Speaking sticks: the icon shows a muted speaker while he is muted.
        MenuBarExtra {
            #if DEBUG
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat, speak: appDelegate.speakReplies, speakEarly: appDelegate.speakEarly,
                        brain: appDelegate.brainSetting, chatgpt: appDelegate.chatgptAccount,
                        learn: appDelegate.fileLearning, showHUD: appDelegate.showHUD, hud: appDelegate.hud,
                        briefing: appDelegate.morningBriefing,
                        updates: appDelegate.updates, voice: appDelegate.voiceStatus,
                        forgetVoice: { appDelegate.forgetVoice() },
                        stopSpeaking: { appDelegate.stopSpeaking() },
                        mute: appDelegate.speechMute, resumeSpeaking: { appDelegate.resumeSpeaking() },
                        testConfirmation: { appDelegate.stashTestConfirmation() },
                        openMemory: { appDelegate.openMemory() }, quietHours: appDelegate.quietHours,
                        openLearningSources: { appDelegate.openLearningSources() },
                        checkAirPlay: { appDelegate.checkAirPlay() }, repairAirPlay: { appDelegate.repairAirPlay() })
            #else
            MenuBarMenu(model: appDelegate.model, chat: appDelegate.chat, speak: appDelegate.speakReplies, speakEarly: appDelegate.speakEarly,
                        brain: appDelegate.brainSetting, chatgpt: appDelegate.chatgptAccount,
                        learn: appDelegate.fileLearning, showHUD: appDelegate.showHUD, hud: appDelegate.hud,
                        briefing: appDelegate.morningBriefing,
                        updates: appDelegate.updates, voice: appDelegate.voiceStatus,
                        forgetVoice: { appDelegate.forgetVoice() },
                        stopSpeaking: { appDelegate.stopSpeaking() },
                        mute: appDelegate.speechMute, resumeSpeaking: { appDelegate.resumeSpeaking() },
                        openMemory: { appDelegate.openMemory() }, quietHours: appDelegate.quietHours,
                        openLearningSources: { appDelegate.openLearningSources() },
                        checkAirPlay: { appDelegate.checkAirPlay() }, repairAirPlay: { appDelegate.repairAirPlay() })
            #endif
        } label: {
            MenuBarIcon(mute: appDelegate.speechMute)
        }
        .menuBarExtraStyle(.menu)
    }
}
