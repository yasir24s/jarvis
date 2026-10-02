import AppKit
import Carbon.HIToolbox
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import Synchronization
import SwiftUI
import Testing

/// M9a part 3: which key events ⌥Space push-to-talk takes in the chat window.
@Suite("M9 ⌥Space")
struct OptionSpaceTests {
    static let space = UInt16(kVK_Space)

    @Test("⌥Space down in the key chat window begins; its repeats are swallowed; its key-up ends")
    func holds() {
        #expect(OptionSpace.action(keyDown: true, keyCode: Self.space, modifiers: .option, isRepeat: false,
                                   inKeyChatWindow: true, held: false) == .began)
        #expect(OptionSpace.action(keyDown: true, keyCode: Self.space, modifiers: .option, isRepeat: true,
                                   inKeyChatWindow: true, held: true) == .swallow)
        // Option let go first: Space's key-up still ends it.
        #expect(OptionSpace.action(keyDown: false, keyCode: Self.space, modifiers: [], isRepeat: false,
                                   inKeyChatWindow: true, held: true) == .ended)
        // Caps Lock and the function key do not count as modifiers.
        #expect(OptionSpace.action(keyDown: true, keyCode: Self.space, modifiers: [.option, .capsLock, .function],
                                   isRepeat: false, inKeyChatWindow: true, held: false) == .began)
    }

    @Test("everything else passes through")
    func passes() {
        // Plain Space types a space; ⇧⌥Space and ⌘⌥Space are other shortcuts.
        for mods: NSEvent.ModifierFlags in [[], .shift, [.option, .shift], [.option, .command], .control] {
            #expect(OptionSpace.action(keyDown: true, keyCode: Self.space, modifiers: mods, isRepeat: false,
                                       inKeyChatWindow: true, held: false) == .pass)
        }
        // Another window, or the chat window while not key.
        #expect(OptionSpace.action(keyDown: true, keyCode: Self.space, modifiers: .option, isRepeat: false,
                                   inKeyChatWindow: false, held: false) == .pass)
        // Another key, and a stray key-up.
        #expect(OptionSpace.action(keyDown: true, keyCode: UInt16(kVK_ANSI_J), modifiers: .option, isRepeat: false,
                                   inKeyChatWindow: true, held: false) == .pass)
        #expect(OptionSpace.action(keyDown: false, keyCode: Self.space, modifiers: .option, isRepeat: false,
                                   inKeyChatWindow: true, held: false) == .pass)
    }
}

/// A listener for the snapshots: opens at once, and the test sends its level and live text.
final class SnapshotListener: VoiceListening, @unchecked Sendable {
    private let hooks = Mutex<((@Sendable (Double) -> Void)?, (@Sendable (String) -> Void)?)>((nil, nil))
    let answer: ListeningAccess

    init(access: ListeningAccess = .granted) {
        answer = access
    }

    func access() async -> ListeningAccess { answer }

    func begin(level: @escaping @Sendable (Double) -> Void,
               preview: @escaping @Sendable (String) -> Void) async throws {
        hooks.withLock { $0 = (level, preview) }
    }

    func finish() async -> HeardOutcome { .nothing(dropped: 0) }
    func cancel() async {}

    func send(level: Double, preview: String) {
        let (l, p) = hooks.withLock { $0 }
        l?(level)
        p?(preview)
    }
}

/// M9a: the composer's mic button, the live text, a notice, and the HUD listening, written to
/// `UI1_SNAPSHOT_DIR` for the eye.
@Suite("M9 push-to-talk snapshots", .serialized, .enabled(if: UISnapshot.enabled))
@MainActor
struct PushToTalkSnapshotTests {
    static func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func composerStates() async throws {
        let model = await ChatSnapshotTests.model()
        let sleepLong: PushToTalkModel.Sleep = { _ in try await Task.sleep(for: .seconds(600)) }

        let idle = PushToTalkModel(sleep: sleepLong)
        idle.connect(SnapshotListener())
        var url = try await UISnapshot.write(ChatView(model: model, talk: idle), size: CGSize(width: 560, height: 420),
                                             name: "m9-part3-mic-idle")
        print("M9 snapshot \(url.path)")

        let listener = SnapshotListener()
        let listening = PushToTalkModel(sleep: sleepLong)
        listening.connect(listener)
        listening.toggle()
        await Self.settle { listening.phase == .listening }
        listener.send(level: 0.7, preview: "Remind me to call the bank at four")
        await Self.settle { listening.preview.hasPrefix("Remind") }
        url = try await UISnapshot.write(ChatView(model: model, talk: listening), size: CGSize(width: 560, height: 420),
                                         name: "m9-part3-mic-listening")
        print("M9 snapshot \(url.path)")

        let quiet = PushToTalkModel(sleep: sleepLong)
        quiet.connect(listener)
        quiet.toggle()
        await Self.settle { quiet.phase == .listening }
        url = try await UISnapshot.write(ChatView(model: model, talk: quiet), size: CGSize(width: 560, height: 420),
                                         name: "m9-part3-mic-listening-empty")
        print("M9 snapshot \(url.path)")
        quiet.toggle()
        await Self.settle { quiet.notice != nil }
        url = try await UISnapshot.write(ChatView(model: model, talk: quiet), size: CGSize(width: 560, height: 420),
                                         name: "m9-part3-mic-nothing-heard")
        print("M9 snapshot \(url.path)")
    }

    /// Part 5: the microphone denied. The composer says so, and the chat explains it once.
    @Test func microphoneDenied() async throws {
        let model = await ChatSnapshotTests.model()
        let talk = PushToTalkModel(sleep: { _ in try await Task.sleep(for: .seconds(600)) })
        talk.onDenied = { access in
            if let text = PushToTalkModel.explanation(access) { model.post(text) }
        }
        talk.connect(SnapshotListener(access: .microphoneDenied))
        talk.buttonDown()
        talk.buttonUp()
        await Self.settle { talk.notice != nil }
        talk.buttonDown()
        talk.buttonUp()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.messages.filter { $0.text == PushToTalkModel.explanation(.microphoneDenied) }.count == 1)
        let url = try await UISnapshot.write(ChatView(model: model, talk: talk), size: CGSize(width: 560, height: 520),
                                             name: "m9-part5-microphone-denied")
        print("M9 snapshot \(url.path)")
    }

    /// Part 6: a spoken yes on a pending card. The chat notes the owner check; denied, the card
    /// is back with its countdown.
    @Test func spokenConfirmation() async throws {
        let gate = ConfirmationGate()
        let check = SheetSaysNo()
        let model = ChatViewModel(submitter: ConfirmingSubmitter(gate: gate, check: check), minimumGap: .zero)
        model.watchConfirmations(gate, authenticator: check)
        await gate.stash(desc: "Empty the Trash (14 items)", action: { "Emptied, sir." }, turn: TurnContext(channel: .text))
        await Self.settle { model.pending != nil }
        await model.sendVoice("Yes")?.value
        await Self.settle { model.pending != nil }
        let url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 360),
                                             name: "m9-part6-spoken-yes-denied")
        print("M9 snapshot \(url.path)")
    }

    @Test func hudListening() async throws {
        let sleepLong: HUDModel.Sleep = { _ in try await Task.sleep(for: .seconds(600)) }
        for (name, level) in [("quiet", 0.05), ("speech", 0.75)] {
            let hud = HUDModel(sleep: sleepLong)
            hud.listening()
            hud.level(level)
            let view = HUDView(model: hud).background(Color(white: 0.16))
            let url = try await UISnapshot.write(view, size: HUDPanel.size, name: "m9-part3-hud-listening-\(name)",
                                                 settle: .milliseconds(900))
            print("M9 snapshot \(url.path)")
        }
    }
}

/// The owner check, as if the user cancelled the system sheet.
struct SheetSaysNo: TextConfirmAuthenticator {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { false }
}

/// Confirms as TurnCoordinator does: a spoken turn through the voice port with the owner check.
actor ConfirmingSubmitter: TurnSubmitting {
    let gate: ConfirmationGate
    let check: any TextConfirmAuthenticator

    init(gate: ConfirmationGate, check: any TextConfirmAuthenticator) {
        self.gate = gate
        self.check = check
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        let turn = TurnContext(channel: input.channel)
        await accepted?(turn)
        let port: InputPort = input.channel == .text ? .text(authenticator: check) : .voice(confirming: .ownerCheck(check))
        if case .handled(let result) = await gate.consume(input.text, via: port, runIn: turn) {
            await sink.sentence(result)
            await turn.close()
            return .confirmation(result)
        }
        await sink.sentence("It is three o'clock, sir.")
        await turn.close()
        return .reply("It is three o'clock, sir.")
    }
}
