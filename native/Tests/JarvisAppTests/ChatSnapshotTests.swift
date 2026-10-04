import AppKit
import Foundation
@testable import JarvisApp
import JarvisBrain
import JarvisChat
import JarvisTools
import SwiftUI
import Testing

/// A submitter whose turns stream a fixed reply for each message, for the snapshots.
actor ScriptedSubmitter: TurnSubmitting {
    private let replies: [String: String]

    init(_ replies: [String: String]) {
        self.replies = replies
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        let turn = TurnContext(channel: input.channel)
        await accepted?(turn)
        let reply = replies[input.text] ?? "Very good, sir."
        await sink.delta(reply)
        await turn.close()
        return .reply(reply)
    }
}

/// A submitter whose first turn streams a little and then runs until it is stopped; later
/// turns answer at once. For the Stop snapshots.
actor StoppableSubmitter: TurnSubmitting {
    private var calls = 0
    private(set) var inputs: [UserInput] = []
    let firstShown: String
    let later: String

    init(firstShown: String, later: String) {
        self.firstShown = firstShown
        self.later = later
    }

    func submit(_ input: UserInput, sink: any ReplySink,
                accepted: (@Sendable (TurnContext) async -> Void)?) async -> TurnOutcome {
        calls += 1
        inputs.append(input)
        let turn = TurnContext(channel: input.channel)
        await accepted?(turn)
        if calls == 1 {
            await sink.delta(firstShown)
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            await turn.close()
            return .reply(firstShown)
        }
        await sink.delta(later)
        await turn.close()
        return .reply(later)
    }
}

/// An owner check that is always available and always passes; nothing is shown.
struct PassingAuthenticator: TextConfirmAuthenticator {
    func canAuthenticate() -> Bool { true }
    func authenticate(reason: String) async -> Bool { true }
}

/// UI1: the chat window as it draws, written to `UI1_SNAPSHOT_DIR` for the eye.
@Suite("UI1 chat snapshots", .serialized, .enabled(if: UISnapshot.enabled))
@MainActor
struct ChatSnapshotTests {
    static let replies = [
        "What's on my calendar this afternoon?":
            "You have **two** things, sir: the design review at 2 pm and a call with the bank at 4. "
            + "Shall I move the call? The [calendar](https://example.invalid/cal) has the details.",
        "Remind me to send the slides.": "Done, sir. I'll remind you at 5 pm to send the slides.",
    ]

    static func model() async -> ChatViewModel {
        let model = ChatViewModel(submitter: ScriptedSubmitter(replies), minimumGap: .zero)
        for message in ["What's on my calendar this afternoon?", "Remind me to send the slides."] {
            model.draft.text = message
            await model.send()?.value
        }
        return model
    }

    @Test func theme() async throws {
        let model = await Self.model()
        model.post("A note he posted himself, outside any turn.")
        let url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 620),
                                             name: "ui1-part1-theme")
        print("UI1 snapshot \(url.path)")
    }

    @Test func visibleBrainSpeechAndGrowingDraft() async throws {
        let suite = "chat-controls-snapshot-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let brain = BrainSetting(defaults: defaults, claudeEnabled: true)
        brain.choice = .chatgpt
        let mute = SpeechMute(defaults: defaults, cancel: {})
        let speak = SpeakRepliesToggle(defaults: defaults)
        speak.isOn = true
        let model = await Self.model()
        let view = ChatView(model: model, brain: brain, mute: mute, speak: speak)
        for (name, draft) in [
            ("compact", ""),
            ("expanded", Array(repeating: "A longer draft wraps without sending it.", count: 12)
                .joined(separator: " ")),
            ("shrunk", "Short again."),
        ] {
            model.draft.text = draft
            let url = try await UISnapshot.write(view, size: CGSize(width: 560, height: 620),
                                                 name: "ui1-controls-\(name)")
            print("UI1 snapshot \(url.path)")
        }
        mute.stop()
        let muted = try await UISnapshot.write(view, size: CGSize(width: 560, height: 620),
                                               name: "ui1-controls-muted")
        print("UI1 snapshot \(muted.path)")
        mute.resume()
        speak.isOn = false
        let silent = try await UISnapshot.write(view, size: CGSize(width: 560, height: 620),
                                                name: "ui1-controls-typed-silent")
        print("UI1 snapshot \(silent.path)")
    }

    /// UI1 part 4: while he writes, the button is Stop; a message sent then stops him, keeps his
    /// partial reply marked stopped, and goes after it as added context.
    @Test func stopAndAddContext() async throws {
        let submitter = StoppableSubmitter(firstShown: "Flights to Rome next week start at",
                                           later: "In euros, sir: from €89 return, on Tuesday morning.")
        let model = ChatViewModel(submitter: submitter, minimumGap: .zero)
        model.draft.text = "Find me flights to Rome next week"
        let first = try #require(model.send())
        for _ in 0..<200 where model.messages.last?.text.isEmpty ?? true {
            try await Task.sleep(for: .milliseconds(5))
        }
        model.draft.text = "in euros please"
        var url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 420),
                                             name: "ui1-part4-replying-stop-button")
        print("UI1 snapshot \(url.path)")
        let second = try #require(model.send())
        await first.value
        await second.value
        #expect(model.messages.map(\.stopped) == [false, true, false, false])
        #expect(await submitter.inputs.map(\.addsContext) == [false, true])
        url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 420),
                                         name: "ui1-part4-stopped-then-context")
        print("UI1 snapshot \(url.path)")
    }

    /// UI1 part 5: Edit on a hovered message, the edit field, and a message's versions.
    @Test func editAndVersions() async throws {
        let model = await Self.model()
        let first = try #require(model.messages.first { $0.role == .user })
        let noEdit = RowEditing(canEdit: true, versions: nil, versionsEnabled: true, text: nil,
                                begin: {}, cancel: {}, send: {}, show: { _ in })
        let editingText = RowEditing(canEdit: true, versions: nil, versionsEnabled: true,
                                     text: .constant("What's on my calendar tomorrow afternoon?"),
                                     begin: {}, cancel: {}, send: {}, show: { _ in })
        let rows = VStack(alignment: .trailing, spacing: 18) {
            UserMessage(message: first, edit: noEdit, hovering: true)
            UserMessage(message: first, edit: editingText)
        }
        .padding(16)
        .frame(width: 560, alignment: .trailing)
        .background(JarvisTheme.navy.color)
        .foregroundStyle(JarvisTheme.ice.color)
        .font(JarvisTheme.body)
        var url = try await UISnapshot.write(rows, size: CGSize(width: 560, height: 200), name: "ui1-part5-edit")
        print("UI1 snapshot \(url.path)")

        await model.edit(first.id, to: "What's on my calendar tomorrow afternoon?")?.value
        url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 520),
                                         name: "ui1-part5-version-2-of-2")
        print("UI1 snapshot \(url.path)")
        let edited = try #require(model.messages.first { $0.role == .user })
        model.showVersion(0, of: edited.id)
        url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 520),
                                         name: "ui1-part5-version-1-of-2")
        print("UI1 snapshot \(url.path)")
    }

    @Test func confirmationCardIsGold() async throws {
        let model = await Self.model()
        let gate = ConfirmationGate()
        model.watchConfirmations(gate, authenticator: PassingAuthenticator())
        await TestConfirmation.stash(on: gate)
        for _ in 0..<50 where model.pending == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.pending != nil)
        let url = try await UISnapshot.write(ChatView(model: model), size: CGSize(width: 560, height: 620),
                                             name: "ui1-part1-card")
        print("UI1 snapshot \(url.path)")
    }
}
