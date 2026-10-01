import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// P6 part 3 (DEV-P6-04, proposed): chats are compiled into memory after 30 idle minutes, not
/// only on "that's all". On a manual clock: not before 30 minutes, once per idle stretch, never
/// while a turn runs, only with user messages waiting, and through P2's real compile on a
/// sandboxed memory folder. Invented messages only.
@Suite("P6 idle compile", .timeLimit(.minutes(1)))
struct IdleCompileTests {
    static let epoch: Double = 1_790_582_400

    /// The loop's 60 s sleep waits until cancelled; the 500 ms turn poll takes a millisecond.
    static let sleep: IdleCompile.Sleep = { d in
        if d == IdleCompile.checkEvery { try await Task.sleep(for: .seconds(86_400)) }
        try await Task.sleep(for: .milliseconds(1))
    }

    final class Calls: Sendable {
        private let n = Mutex(0)
        var count: Int { n.withLock { $0 } }
        func add() { n.withLock { $0 += 1 } }
    }

    final class Flag: Sendable {
        private let v: Mutex<Bool>
        init(_ v: Bool) { self.v = Mutex(v) }
        var value: Bool { v.withLock { $0 } }
        func set(_ x: Bool) { v.withLock { $0 = x } }
    }

    struct Rig {
        let clock = ManualClock(IdleCompileTests.epoch)
        let turns: TurnActivity
        let calls = Calls()
        let waiting = Flag(true)
        let idle: IdleCompile

        init() {
            let clock = clock, calls = calls, waiting = waiting
            turns = TurnActivity(clock: clock)
            idle = IdleCompile(turns: turns, pending: { waiting.value },
                               compile: { calls.add(); return .compiled(added: 1, updated: 0, dropped: 0) },
                               clock: clock, sleep: IdleCompileTests.sleep, log: { _ in })
            idle.start()
        }
    }

    @Test func itCompilesAfterThirtyIdleMinutesOncePerStretch() async {
        let rig = Rig()
        defer { rig.idle.stop() }
        rig.clock.advance(IdleCompile.idleAfter - 1)
        #expect(await rig.idle.check() == nil)
        rig.clock.advance(1)
        #expect(await rig.idle.check() == .compiled(added: 1, updated: 0, dropped: 0))
        rig.clock.advance(3_600)
        #expect(await rig.idle.check() == nil)                    // the same idle stretch
        #expect(rig.calls.count == 1)
        // A turn starts a new stretch.
        rig.turns.begin()
        rig.clock.advance(5)
        rig.turns.end()
        rig.clock.advance(IdleCompile.idleAfter - 1)
        #expect(await rig.idle.check() == nil)
        rig.clock.advance(1)
        #expect(await rig.idle.check() != nil)
        #expect(rig.calls.count == 2)
    }

    @Test func nothingWaitingMeansNoCompile() async {
        let rig = Rig()
        defer { rig.idle.stop() }
        rig.waiting.set(false)
        rig.clock.advance(IdleCompile.idleAfter)
        #expect(await rig.idle.check() == nil)
        #expect(rig.calls.count == 0)
    }

    /// A running turn is never idle; its end starts the 30 minutes again.
    @Test func neverWhileATurnRuns() async {
        let rig = Rig()
        defer { rig.idle.stop() }
        rig.turns.begin()
        rig.clock.advance(IdleCompile.idleAfter * 3)
        #expect(await rig.idle.check() == nil)
        rig.turns.end()
        rig.clock.advance(IdleCompile.idleAfter - 1)
        #expect(await rig.idle.check() == nil)
        rig.clock.advance(1)
        #expect(await rig.idle.check() != nil)
        #expect(rig.calls.count == 1)
    }

    /// A turn that begins once the compile is due is waited out first.
    @Test func itWaitsOutATurnThatBeginsWhenItIsDue() async throws {
        let clock = ManualClock(Self.epoch)
        let turns = TurnActivity(clock: clock)
        let calls = Calls()
        let idle = IdleCompile(turns: turns, pending: { turns.begin(); return true },
                               compile: { calls.add(); return .nothingNew }, clock: clock, sleep: Self.sleep,
                               log: { _ in })
        idle.start()
        defer { idle.stop() }
        clock.advance(IdleCompile.idleAfter)
        let run = Task { await idle.check() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(calls.count == 0)                                  // still waiting on the turn
        turns.end()
        #expect(await run.value == .nothingNew)
        #expect(calls.count == 1)
    }

    @Test func afterStopNothingRuns() async {
        let rig = Rig()
        rig.idle.stop()
        rig.clock.advance(IdleCompile.idleAfter * 2)
        #expect(await rig.idle.check() == nil)
        #expect(rig.calls.count == 0)
    }

    /// Through P2's real compile: the user's messages since `compiled_through` become a fact,
    /// and the offset moves past them. A second idle stretch with nothing new compiles nothing.
    @Test func itRunsP2sCompileOnTheArchive() async throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let clock = ManualClock(Self.epoch)
        let store = try StateStore(root: sb.root.path(percentEncoded: false), lease: nil, clock: clock)
        let memory = MemoryStore(store: store, clock: clock, timeZone: TimeZone(identifier: "UTC")!)
        #expect(memory.archive("I grow invented tomatoes on my balcony.", role: .user, channel: "text"))
        #expect(memory.archive("Splendid, sir.", role: .jarvis, channel: "text"))
        #expect(IdleCompile.uncompiled(memory))
        let compiler = FactCompiler(memory: memory, writer: FixedWriter(text: "The user grows tomatoes on a balcony."),
                                    vectors: FactVectors(embedding: nil), clock: clock, makeID: { "fact-1" },
                                    log: { _ in })
        let turns = TurnActivity(clock: clock)
        let idle = IdleCompile(compiler: compiler, memory: memory, turns: turns, clock: clock, sleep: Self.sleep,
                               log: { _ in })
        idle.start()
        defer { idle.stop() }
        clock.advance(IdleCompile.idleAfter)
        #expect(await idle.check() == .compiled(added: 1, updated: 0, dropped: 0))
        #expect(memory.loadFacts()?.facts.map(\.text) == ["The user grows tomatoes on a balcony."])
        #expect(!IdleCompile.uncompiled(memory))
        turns.begin()
        turns.end()
        clock.advance(IdleCompile.idleAfter)
        #expect(await idle.check() == nil)                         // nothing new from the user
    }

    /// The app's assembly has one exactly when it has a memory store.
    @Test func theAssemblyHasOneOnlyWithAMemoryStore() throws {
        let dir = try ShortTempDir()
        defer { dir.remove() }
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        func assembly(_ memory: MemoryStore?) -> BrainAssembly {
            BrainAssembly(
                core: harness.core, research: NullCounter(), config: ClaudeConfig(environment: [:]), environment: [:],
                runDirectory: dir.url.appending(path: "run", directoryHint: .isDirectory),
                claudeWorkingDirectory: dir.url.appending(path: "claude-cwd", directoryHint: .isDirectory),
                claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) }, personaWriter: ScriptedWriter(),
                memory: memory, factWriter: nil, embedding: MemoryWiringTests.TableEmbedding(table: [:]),
                textAuthenticator: FakeAuthenticator(answer: false), online: { false }, log: { _, _ in })
        }
        #expect(assembly(nil).idleCompile == nil)
        #expect(assembly(MemoryStore(store: harness.store, clock: ManualClock(CoreHarness.epoch))).idleCompile != nil)
    }

    struct FixedWriter: AttributedWriting {
        let text: String
        func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
            AttributedText(text: text, author: .local)
        }
    }
}
