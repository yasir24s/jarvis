import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Testing

/// P1 piece 5: BrainAssembly's coordinator hands a typed dismissal to the assembly's
/// PersonalitySchedule, whose distillation writes through CoreState's store. A fake writer
/// stands in for the collaborative one; nothing here runs a model or `claude`.
@Suite("P1 persona wiring in BrainAssembly", .timeLimit(.minutes(1)))
struct PersonaWiringTests {
    static func assembly(core: CoreState, writer: any PersonaLLM, dir: URL) -> BrainAssembly {
        BrainAssembly(core: core, research: NullCounter(), config: ClaudeConfig(environment: [:]), environment: [:],
                      runDirectory: dir.appending(path: "run", directoryHint: .isDirectory),
                      claudeWorkingDirectory: dir.appending(path: "claude-cwd", directoryHint: .isDirectory),
                      claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                      localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) }, personaWriter: writer,
                      textAuthenticator: FakeAuthenticator(answer: false), online: { false }, log: { _, _ in })
    }

    @Test func aTypedDismissalDistillsThroughTheAssembledSchedule() async throws {
        let harness = try CoreHarness(research: NullCounter(), files: ["history.json": DismissalTurnTests.fourTurns])
        defer { harness.remove() }
        let writer = ScriptedWriter(.reply("The user enjoys a dry joke."))
        let assembly = Self.assembly(core: harness.core, writer: writer, dir: harness.sandbox.root)
        assembly.personality.start()
        defer { assembly.personality.stop() }

        let outcome = await assembly.coordinator.submit(UserInput(text: "That's all, JARVIS.", channel: .text),
                                                        sink: RecordingSink())

        #expect(outcome == .dismissed("Always a pleasure, sir."))
        try await waitUntil("the distilled note to be saved") {
            harness.sandbox.personalityNotes() == ["The user enjoys a dry joke"]
        }
        #expect(writer.calls.map(\.system) == [PersonaDistill.distillSystem])
        #expect(writer.calls.first?.timeout == PersonaDistill.distillTimeout)
    }

    /// Until the app starts it, the assembly's schedule does nothing: a dismissal still gets
    /// its reply, and no writer is asked.
    @Test func anUnstartedScheduleDistillsNothing() async throws {
        let harness = try CoreHarness(research: NullCounter(), files: ["history.json": DismissalTurnTests.fourTurns])
        defer { harness.remove() }
        let writer = ScriptedWriter(.reply("The user enjoys a dry joke."))
        let assembly = Self.assembly(core: harness.core, writer: writer, dir: harness.sandbox.root)

        let outcome = await assembly.coordinator.submit(UserInput(text: "thanks", channel: .text), sink: RecordingSink())

        #expect(outcome == .dismissed("Always a pleasure, sir."))
        try await Task.sleep(for: .milliseconds(50))
        #expect(writer.calls.isEmpty)
        #expect(!harness.sandbox.exists("personality.json"))
    }
}
