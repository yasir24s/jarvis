import Foundation
import JarvisBrain
import JarvisChat
import JarvisCore
import JarvisTools
import Testing

/// The confirmation card (plan §3.4, §3.12) on a real `ConfirmationGate`, with a fake owner
/// check: nothing here shows a system sheet, starts a brain or opens a window.
@Suite("M4 confirmation card (plan 3.4)", .timeLimit(.minutes(1)))
@MainActor
struct ConfirmationCardTests {
    static let desc = "delete test.txt permanently"

    /// A chat watching `gate`, with one confirmation pending whose action is logged and
    /// returns "Done, sir.".
    static func rig(_ authenticator: any TextConfirmAuthenticator, gate: ConfirmationGate = ConfirmationGate(),
                    actions: ActionLog = ActionLog()) async throws -> (ChatViewModel, ConfirmationGate, FakeCoordinator) {
        let coordinator = confirmingCoordinator(gate, authenticator: authenticator)
        let model = ChatViewModel(submitter: coordinator)
        model.watchConfirmations(gate, authenticator: authenticator)
        await gate.stash(desc: desc, action: { await actions.ran(); return "Done, sir." },
                         turn: TurnContext(channel: .text))
        #expect(await eventually { model.pending != nil })
        return (model, gate, coordinator)
    }

    @Test("a stashed confirmation shows on the card with its description and 25 s to go")
    func cardShowsThePendingConfirmation() async throws {
        // The gate's deadline is on the continuous clock, which counts through system sleep, so
        // the check brackets the stash instead of reading the clock after it.
        let before = ContinuousClock.now
        let (model, gate, _) = try await Self.rig(FakeTextAuthenticator(answer: true))
        let after = ContinuousClock.now
        let pending = try #require(model.pending)
        #expect(pending.desc == Self.desc)
        #expect(await gate.pending == pending)
        #expect(before.advanced(by: .seconds(25)) <= pending.deadline)
        #expect(pending.deadline <= after.advanced(by: .seconds(25)))
        #expect(TextConfirmation.secondsLeft(until: pending.deadline, now: pending.deadline.advanced(by: .seconds(-25))) == 25)
    }

    @Test("the countdown rounds up and stops at 0")
    func countdown() {
        let start = ContinuousClock.now
        let deadline = start.advanced(by: .seconds(25))
        #expect(TextConfirmation.secondsLeft(until: deadline, now: start) == 25)
        #expect(TextConfirmation.secondsLeft(until: deadline, now: start.advanced(by: .milliseconds(500))) == 25)
        #expect(TextConfirmation.secondsLeft(until: deadline, now: start.advanced(by: .milliseconds(24_001))) == 1)
        #expect(TextConfirmation.secondsLeft(until: deadline, now: deadline) == 0)
        #expect(TextConfirmation.secondsLeft(until: deadline, now: deadline.advanced(by: .seconds(5))) == 0)
    }

    @Test("Confirm sends \"confirm\" as a typed turn; a passed owner check runs the action")
    func confirmApproved() async throws {
        let authenticator = FakeTextAuthenticator(answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = try await Self.rig(authenticator, actions: actions)
        model.draft.text = "half a sentence"
        let turn = try #require(model.confirmPending())
        await turn.value
        #expect(await coordinator.inputs == [UserInput(text: "confirm", channel: .text)])
        #expect(authenticator.reasons == [Self.desc])
        #expect(await actions.runs == 1)
        #expect(model.messages.map(\.text) == ["confirm", "Done, sir."])
        #expect(model.draft.text == "half a sentence")
        #expect(await gate.pending == nil)
        #expect(await eventually { model.pending == nil })
    }

    @Test("a failed owner check cancels, and the action does not run")
    func confirmDenied() async throws {
        let authenticator = FakeTextAuthenticator(answer: false)
        let actions = ActionLog()
        let (model, gate, _) = try await Self.rig(authenticator, actions: actions)
        model.draft.text = "yes do it"
        await model.send()?.value
        #expect(authenticator.reasons == [Self.desc])
        #expect(await actions.runs == 0)
        #expect(model.messages.map(\.text) == ["yes do it", "Confirmation cancelled, sir."])
        #expect(await gate.pending == nil)
        #expect(await eventually { model.pending == nil })
    }

    @Test("each owner check is counted: text_confirm_approved or text_confirm_denied", arguments: [true, false])
    func ownerChecksAreCounted(answer: Bool) async throws {
        let research = ResearchRecorder()
        let authenticator = CountingTextAuthenticator(FakeTextAuthenticator(answer: answer), research: research)
        let (model, _, _) = try await Self.rig(authenticator)
        model.draft.text = "confirm"
        await model.send()?.value
        let counter = answer ? TextConfirmation.approvedCounter : TextConfirmation.deniedCounter
        #expect(research.counts == [counter: 1])
        #expect(TextConfirmation.approvedCounter == "text_confirm_approved")
        #expect(TextConfirmation.deniedCounter == "text_confirm_denied")
    }

    @Test("Cancel clears the gate's slot and adds a local \"Cancelled.\" row; nothing is sent or counted")
    func cancel() async throws {
        let research = ResearchRecorder()
        let inner = FakeTextAuthenticator(answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = try await Self.rig(CountingTextAuthenticator(inner, research: research),
                                                            actions: actions)
        let task = try #require(model.cancelPending())
        #expect(model.pending == nil)
        await task.value
        #expect(await gate.pending == nil)
        #expect(await coordinator.inputs.isEmpty)
        #expect(inner.reasons.isEmpty)
        #expect(await actions.runs == 0)
        #expect(research.counts.isEmpty)
        #expect(model.messages.map(\.role) == [.system])
        #expect(model.messages.map(\.text) == ["Cancelled."])
        #expect(model.cancelPending() == nil)
    }

    @Test("other typed text clears the card and goes to the brain as usual")
    func otherTextCancelsTheSlot() async throws {
        let authenticator = FakeTextAuthenticator(answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = try await Self.rig(authenticator, actions: actions)
        model.draft.text = "what time is it"
        await model.send()?.value
        #expect(await coordinator.inputs.map(\.text) == ["what time is it"])
        #expect(authenticator.reasons.isEmpty)
        #expect(await actions.runs == 0)
        #expect(model.messages.map(\.text) == ["what time is it", "It is three o'clock, sir."])
        #expect(await gate.pending == nil)
        #expect(await eventually { model.pending == nil })
    }

    @Test("a card past its deadline sends nothing and goes")
    func staleCard() async throws {
        let authenticator = FakeTextAuthenticator(answer: true)
        let (model, gate, coordinator) = try await Self.rig(authenticator)
        let pending = try #require(model.pending)
        #expect(!TextConfirmation.isStale(pending, now: pending.deadline))
        let late = pending.deadline.advanced(by: .seconds(1))
        #expect(TextConfirmation.isStale(pending, now: late))
        #expect(model.confirmPending(now: late) == nil)
        #expect(model.pending == nil)
        #expect(model.messages.isEmpty)
        #expect(await coordinator.inputs.isEmpty)
        #expect(authenticator.reasons.isEmpty)
        // The gate's slot is left for the gate: its own rule (checked at submission) drops it.
        #expect(await gate.pending == pending)
    }

    @Test("with no owner check on this Mac, a typed affirmation is refused and the confirmation stays pending",
          arguments: ["confirm", "  Yes, go ahead"])
    func cannotVerify(typed: String) async throws {
        let authenticator = FakeTextAuthenticator(available: false, answer: true)
        let actions = ActionLog()
        let (model, gate, coordinator) = try await Self.rig(authenticator, actions: actions)
        model.draft.text = typed
        #expect(model.send() == nil)
        #expect(model.messages.map(\.text) == [Py.strip(typed), TextConfirmation.cannotVerify])
        #expect(TextConfirmation.cannotVerify == "I can't verify it's you at the keyboard, sir — say 'confirm' instead.")
        #expect(model.draft == ComposerDraft())
        #expect(model.confirmPending() == nil)
        #expect(model.messages.map(\.text).suffix(2) == ["confirm", TextConfirmation.cannotVerify])
        #expect(await coordinator.inputs.isEmpty)
        #expect(authenticator.reasons.isEmpty)
        #expect(await actions.runs == 0)
        #expect(model.pending != nil)
        #expect(await gate.pending != nil)
        #expect(!model.responding)
    }

    #if DEBUG
    @Test("the DEBUG test confirmation shows on the card and its only effect is its fixed reply")
    func debugTestConfirmation() async throws {
        let gate = ConfirmationGate()
        let authenticator = FakeTextAuthenticator(answer: true)
        let model = ChatViewModel(submitter: confirmingCoordinator(gate, authenticator: authenticator))
        model.watchConfirmations(gate, authenticator: authenticator)
        await TestConfirmation.stash(on: gate)
        #expect(await eventually { model.pending != nil })
        #expect(model.pending?.desc == TestConfirmation.desc)
        await model.confirmPending()?.value
        #expect(model.messages.map(\.text) == ["confirm", "Test confirmation approved, sir."])
        #expect(authenticator.reasons == [TestConfirmation.desc])
        #expect(TestConfirmation.menuTitle == "Test confirmation")
    }
    #endif

    @Test("the system sheet's settings: reason, fallback button, 60 s limit")
    func sheetSettings() {
        #expect(TextConfirmation.localizedReason(Self.desc) == "confirm: delete test.txt permanently")
        #expect(TextConfirmation.fallbackTitle == "Use Password")
        #expect(TextConfirmation.promptTimeout == .seconds(60))
        #expect(Affirmation.matches(TextConfirmation.confirmInput))
        #expect(!Affirmation.matches(TextConfirmation.cancelInput))
    }
}
