import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// P1 piece 4: a typed dismissal ends the conversation. TurnCoordinator answers "Always a
/// pleasure, sir." without the brain (no interaction counted, as Python's voice loop), then
/// calls the conversation-ended hook, whose distillation runs in the background.
@Suite("P1 dismissal in the turn coordinator", .timeLimit(.minutes(1)))
struct DismissalTurnTests {
    /// Four turns, so CoreState's distillation is due (4+ turns, 900 s since the last).
    static let fourTurns = #"[{"role":"user","content":"tell me a joke"},{"role":"assistant","content":"I would, sir, but you would laugh."},{"role":"user","content":"ha, that was good"},{"role":"assistant","content":"I do try, sir."}]"#

    struct Rig {
        let harness: CoreHarness
        let events: EventLog
        let claude: FakeClaudeBrain
        let local: FakeLocalBrain
        let fastPath: FakeFastPath
        let gate = ConfirmationGate()
        let online = OnlineProbe(true)
        let sink: EventSink
        let coordinator: TurnCoordinator

        init(history: String = CoreHarness.seedHistory, onConversationEnded: (@Sendable () -> Void)?) throws {
            events = EventLog()
            let research = EventCounter(events)
            harness = try CoreHarness(research: research, files: ["history.json": history])
            claude = FakeClaudeBrain(reply: "Claude reply, sir.", events: events)
            local = FakeLocalBrain(.reply("Local reply, sir."), events: events)
            fastPath = FakeFastPath(reply: nil)
            sink = EventSink(events)
            let router = BrainRouter(core: harness.core, config: ClaudeConfig(environment: [:]), claude: claude,
                                     local: local, backend: EventBackend(events), research: research, log: { _ in })
            let online = online
            coordinator = TurnCoordinator(brain: router, fastPath: fastPath, confirmations: gate,
                                          textAuthenticator: FakeAuthenticator(answer: true), online: { online.ask() },
                                          onConversationEnded: onConversationEnded)
        }

        func submit(_ text: String, _ channel: Channel = .text) async -> TurnOutcome {
            await coordinator.submit(UserInput(text: text, channel: channel), sink: sink)
        }
    }

    @Test(arguments: ["That's all, JARVIS.", "thanks", "Thank you, sir.", "Goodbye JARVIS!", "stand down"])
    func typedDismissalAnswersWithoutTheBrain(_ text: String) async throws {
        let ended = Counter()
        let rig = try Rig(onConversationEnded: { ended.bump() })
        defer { rig.harness.remove() }
        let history = rig.harness.historyFile()

        let outcome = await rig.submit(text)

        #expect(outcome == .dismissed("Always a pleasure, sir."))
        #expect(rig.events.events == ["sink Always a pleasure, sir."])    // no brain, no bump
        #expect(ended.value == 1)
        #expect(await rig.fastPath.texts.isEmpty)
        #expect(rig.online.count == 0)
        #expect(rig.harness.historyFile() == history)
    }

    /// Not a dismissal as a whole: an ordinary turn, and the conversation goes on.
    @Test(arguments: ["thanks, now open Safari", "thank you for the help", "that's all for now"])
    func partOfAMessageIsNotADismissal(_ text: String) async throws {
        let ended = Counter()
        let rig = try Rig(onConversationEnded: { ended.bump() })
        defer { rig.harness.remove() }

        let outcome = await rig.submit(text)

        #expect(outcome == .reply("Claude reply, sir."))
        #expect(rig.events.events.contains("bump interactions+1"))
        #expect(ended.value == 0)
    }

    /// The text rule belongs to the text channel. The voice loop (M8) applies is_dismiss itself.
    @Test func theVoiceChannelIsNotTheTextRule() async throws {
        let ended = Counter()
        let rig = try Rig(onConversationEnded: { ended.bump() })
        defer { rig.harness.remove() }

        #expect(await rig.submit("that's all, jarvis", .voice) == .reply("Claude reply, sir."))
        #expect(ended.value == 0)
    }

    /// A typed dismissal clears a pending confirmation, as any typed message that is not a
    /// yes does; the action never runs.
    @Test func aDismissalClearsAPendingConfirmation() async throws {
        let ended = Counter()
        let rig = try Rig(onConversationEnded: { ended.bump() })
        defer { rig.harness.remove() }
        let action = TurnCoordinatorTests.Action("Deleted, sir.")
        await rig.gate.stash(desc: TurnCoordinatorTests.desc, action: action.body, turn: TurnContext(channel: .text))

        #expect(await rig.submit("That's all, JARVIS.") == .dismissed("Always a pleasure, sir."))
        #expect(await rig.gate.pending == nil)
        #expect(await rig.submit("yes") == .reply("Claude reply, sir."))
        #expect(!action.didRun)
        #expect(ended.value == 1)
    }

    /// The reply reaches the sink and the turn returns while the distillation's writer is
    /// still working; the note lands in personality.json once the writer answers.
    @Test func theReplyDoesNotWaitForTheDistillation() async throws {
        let writer = HeldWriter(reply: "The user enjoys a dry joke.")
        let hook = Hook()
        let rig = try Rig(history: Self.fourTurns, onConversationEnded: { hook.call() })
        defer { rig.harness.remove() }
        writer.events = rig.events
        // The hourly loop parks in its first sleep; only the dismissal's distillation runs.
        let schedule = PersonalitySchedule(core: rig.harness.core, writer: writer, clock: ManualClock(CoreHarness.epoch),
                                           sleep: { _ in try await Task.sleep(for: .seconds(3600), clock: .suspending) },
                                           log: { _ in })
        hook.set { schedule.conversationEnded() }
        schedule.start()
        defer { schedule.stop() }

        let outcome = await rig.submit("That's all, JARVIS.")

        #expect(outcome == .dismissed("Always a pleasure, sir."))
        try await waitUntil("the distillation to reach its writer") { writer.calls == 1 }
        #expect(rig.events.events == ["sink Always a pleasure, sir.", "writer asked"])
        #expect(!rig.harness.sandbox.exists("personality.json"))

        writer.release()
        try await waitUntil("the note to be saved") {
            rig.harness.sandbox.personalityNotes() == ["The user enjoys a dry joke"]
        }
        #expect(rig.events.events == ["sink Always a pleasure, sir.", "writer asked", "writer answered"])
        #expect(writer.systems == [PersonaDistill.distillSystem])
    }
}

// MARK: - Fakes

/// A ReplySink that writes "sink <sentence>" to an EventLog, so the order against the
/// writer's events is observable.
actor EventSink: ReplySink {
    let log: EventLog
    init(_ log: EventLog) { self.log = log }
    func sentence(_ text: String) { log.add("sink \(text)") }
    func delta(_ text: String) {}
    func retracted(messageID: String) {}
}

final class Counter: Sendable {
    private let n = Mutex(0)
    func bump() { n.withLock { $0 += 1 } }
    var value: Int { n.withLock { $0 } }
}

/// The coordinator's hook, bound after the schedule exists.
final class Hook: Sendable {
    private let body = Mutex<(@Sendable () -> Void)?>(nil)
    func set(_ f: @escaping @Sendable () -> Void) { body.withLock { $0 = f } }
    func call() { body.withLock { $0 }?() }
}

/// A PersonaLLM that answers only once released, so a test can hold a distillation open.
final class HeldWriter: PersonaLLM {
    private struct State {
        var systems: [String] = []
        var released = false
        var waiting: [CheckedContinuation<Void, Never>] = []
        var events: EventLog?
    }

    let reply: String
    private let state = Mutex(State())

    init(reply: String) { self.reply = reply }

    var calls: Int { state.withLock { $0.systems.count } }
    var systems: [String] { state.withLock { $0.systems } }
    var events: EventLog? {
        get { state.withLock { $0.events } }
        set { state.withLock { $0.events = newValue } }
    }

    func release() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.released = true
            defer { s.waiting = [] }
            return s.waiting
        }
        for c in waiting { c.resume() }
    }

    func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let log = state.withLock { s -> EventLog? in
            s.systems.append(system)
            return s.events
        }
        log?.add("writer asked")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.released { return true }
                s.waiting.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
        log?.add("writer answered")
        return reply
    }
}

extension Sandbox {
    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relative).path(percentEncoded: false))
    }

    /// personality.json's learned notes, or nil while it is missing or unreadable.
    func personalityNotes() -> [String]? {
        guard let text = try? read("personality.json"),
              let p = try? PyJSON.loads(Data(text.utf8)).objectValue else { return nil }
        return p["learned"]?.arrayValue?.compactMap { $0.objectValue?["note"]?.stringValue }
    }
}

/// Polls `done` 1 ms apart; a test failure after `seconds` of awake time (SuspendingClock),
/// never a hang.
func waitUntil(_ what: String, within seconds: Int64 = 30, _ done: () -> Bool) async throws {
    let deadline = SuspendingClock.now.advanced(by: .seconds(seconds))
    while !done() {
        guard SuspendingClock.now < deadline else {
            Issue.record("timed out after \(seconds) s waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}
