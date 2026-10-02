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
