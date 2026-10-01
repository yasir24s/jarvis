import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import JarvisTools
import Synchronization
import Testing

/// D-51 P3, piece 6: BrainAssembly builds the file scanner only with both a memory store and
/// the app's file setup, its coordinator marks turns on the activity the scanner waits on, and
/// a started scanner stops promptly (the app stops it at quit, before the lock is released).
/// Nothing here walks the real home folder or runs a model.
@Suite("P3 file scanner wiring in BrainAssembly", .timeLimit(.minutes(1)))
struct FileScannerWiringTests {
    /// What a turn saw of the activity, set once the assembly exists.
    final class Seen: Sendable {
        let activity = Mutex<TurnActivity?>(nil)
        let running = Mutex<[Bool]>([])
    }

    static func assembly(_ harness: CoreHarness, memory: MemoryStore?, files: FileScanSetup?,
                         onTurnStart: (@Sendable (TurnContext) -> Void)? = nil) -> BrainAssembly {
        let dir = harness.sandbox.root
        return BrainAssembly(core: harness.core, research: NullCounter(), config: ClaudeConfig(environment: [:]),
                             environment: [:], runDirectory: dir.appending(path: "run", directoryHint: .isDirectory),
                             claudeWorkingDirectory: dir.appending(path: "claude-cwd", directoryHint: .isDirectory),
                             claudeExecutable: URL(fileURLWithPath: "/nonexistent/claude"),
                             localBrain: { _ in FakeLocalBrain(.reply("Local reply, sir.")) },
                             personaWriter: ScriptedWriter(), memory: memory, files: files,
                             embedding: MemoryWiringTests.TableEmbedding(table: [:]),
                             textAuthenticator: FakeAuthenticator(answer: false), online: { false },
                             onTurnStart: onTurnStart, log: { _, _ in })
    }

    @Test func theScannerNeedsBothTheMemoryAndTheFileSetup() throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let home = try TempHome()
        defer { home.remove() }
        let memory = MemoryStore(store: harness.store)
        let files = FileScanSetup(home: home.root, stateRoot: harness.sandbox.root, store: harness.store,
                                  extractors: TextExtractors([PlainTextExtractor()]))
        #expect(Self.assembly(harness, memory: memory, files: files).fileScanner != nil)
        #expect(Self.assembly(harness, memory: memory, files: nil).fileScanner == nil)
        #expect(Self.assembly(harness, memory: nil, files: files).fileScanner == nil)
    }

    @Test func theCoordinatorMarksEachTurnOnTheActivity() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let seen = Seen()
        let assembly = Self.assembly(harness, memory: nil, files: nil, onTurnStart: { _ in
            seen.running.withLock { $0.append(seen.activity.withLock { $0?.isRunning ?? false }) }
        })
        seen.activity.withLock { $0 = assembly.turnActivity }
        #expect(!assembly.turnActivity.isRunning)
        _ = await assembly.coordinator.submit(UserInput(text: "what's on today?", channel: .text), sink: RecordingSink())
        #expect(seen.running.withLock { $0 } == [true])                 // running while the turn ran
        #expect(!assembly.turnActivity.isRunning)
    }

    @Test func aStartedScannerStopsPromptlyWithNothingRead() async throws {
        let harness = try CoreHarness(research: NullCounter())
        defer { harness.remove() }
        let home = try TempHome()
        defer { home.remove() }
        try home.write("Documents/notes.md", "Hive notes.")
        let memory = MemoryStore(store: harness.store)
        let files = FileScanSetup(home: home.root, stateRoot: harness.sandbox.root, store: harness.store,
                                  extractors: TextExtractors([PlainTextExtractor()]))
        let scanner = try #require(Self.assembly(harness, memory: memory, files: files).fileScanner)
        scanner.start()                                                // waits startDelay (120 s) first
        let clock = SuspendingClock()
        let t0 = clock.now
        await scanner.stop()
        #expect(t0.duration(to: clock.now) < .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: harness.store.path(.filesIndex)))
    }
}
