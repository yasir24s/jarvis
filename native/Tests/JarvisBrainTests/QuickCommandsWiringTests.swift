import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// PA batch A: BrainAssembly builds the quick commands on its own confirmation gate, so a
/// destructive one is confirmed through the coordinator like any other, and anything the fast
/// path does not carry still reaches the brain. Nothing is deleted, run or spoken: the voice
/// hook only counts.
@Suite("PA quick commands wiring in BrainAssembly", .timeLimit(.minutes(1)))
struct QuickCommandsWiringTests {
    final class Count: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    static func assembly(_ harness: CoreHarness, owner: Bool, forgot: Count) -> BrainAssembly {
        let dir = harness.sandbox.root
        let timers = QuickTimers(clock: ManualClock(CoreHarness.epoch),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
        let hooks = QuickCommands.Hooks(forgetVoice: {
            forgot.add()
            return QuickReplies.voiceCleared
        })
        return BrainAssembly(core: harness.core, research: NullCounter(), config: ClaudeConfig(environment: [:]),
                             environment: [:], runDirectory: dir.appending(path: "run", directoryHint: .isDirectory),
                             claudeWorkingDirectory: dir.appending(path: "claude-cwd", directoryHint: .isDirectory),
                             claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                             localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) },
                             personaWriter: ScriptedWriter(),
                             embedding: MemoryWiringTests.TableEmbedding(table: [:]),
                             textAuthenticator: FakeAuthenticator(answer: owner),
                             makeFastPath: { gate in
                                 QuickCommands(core: harness.core, confirmations: gate, timers: timers, alarms: nil,
                                               hooks: hooks, online: { false }, log: { _ in })
                             },
                             online: { false }, log: { _, _ in })
    }

    @Test(arguments: [true, false])
    func forgetMyVoiceIsConfirmedThroughTheCoordinator(_ owner: Bool) async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let forgot = Count()
        let assembly = Self.assembly(harness, owner: owner, forgot: forgot)
        let coordinator = assembly.coordinator
        let first = await coordinator.submit(UserInput(text: "Forget my voice.", channel: .text), sink: RecordingSink())
        #expect(first == .fastPath(GuardStrings.gatePrompt(QuickReplies.forgetVoiceDesc)))
        #expect(forgot.value == 0)
        let second = await coordinator.submit(UserInput(text: "confirm", channel: .text), sink: RecordingSink())
        #expect(second == .confirmation(owner ? QuickReplies.voiceCleared : "Confirmation cancelled, sir."))
        #expect(forgot.value == (owner ? 1 : 0))
    }

    @Test func aTimerIsInstantAndAnythingElseReachesTheBrain() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let coordinator = Self.assembly(harness, owner: false, forgot: Count()).coordinator
        let timer = await coordinator.submit(UserInput(text: "set a timer for 5 minutes", channel: .text),
                                             sink: RecordingSink())
        #expect(timer == .fastPath("Timer set for 5 minutes, sir."))
        let other = await coordinator.submit(UserInput(text: "tell me a joke", channel: .text), sink: RecordingSink())
        #expect(other == .reply("Local reply, sir."))
    }
}
