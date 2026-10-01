import Foundation
import JarvisCore
import Synchronization

/// P6 (DEV-P6-04, proposed): chats are compiled into memory without "that's all, JARVIS". When
/// no turn has begun or ended for `idleAfter` (30 minutes; counted from `start()` before the
/// first turn) and the archive holds messages from the user that facts.json has not compiled,
/// P2's compile (`FactCompiler.compile`) runs in the background, after any running turn. Once
/// per idle stretch: the next stretch starts with the next turn. The dismissal trigger is
/// unchanged, and the two cannot overlap (`FactCompiler` runs one compile at a time).
///
/// The app starts it once the brain has started and stops it at quit, before the lock is
/// released. The sleep and the clock are injected, so a test runs an hour in milliseconds.
public final class IdleCompile: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How long the chat must be idle.
    public static let idleAfter: Double = 30 * 60
    /// How often the loop looks.
    public static let checkEvery: Duration = .seconds(60)

    private struct State {
        var started: Double?
        var handled: Double?            // the idle stretch (its last activity) already looked at
        var stopped = false
        var loop: Task<Void, Never>?
    }

    private let turns: TurnActivity
    private let pending: @Sendable () -> Bool
    private let compile: @Sendable () async -> FactCompiler.Outcome
    private let clock: any JarvisClock
    private let sleep: Sleep
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - turns: the coordinator's turn activity: whether a turn runs, and when one last began
    ///     or ended.
    ///   - pending: whether the archive holds user messages past facts.json's `compiled_through`.
    ///   - compile: P2's compile.
    public init(turns: TurnActivity, pending: @escaping @Sendable () -> Bool,
                compile: @escaping @Sendable () async -> FactCompiler.Outcome,
                clock: any JarvisClock = SystemClock(),
                sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .continuous) },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.turns = turns
        self.pending = pending
        self.compile = compile
        self.clock = clock
        self.sleep = sleep
        self.log = log
    }

    /// Over the app's memory store and compiler.
    public convenience init(compiler: FactCompiler, memory: MemoryStore, turns: TurnActivity,
                            clock: any JarvisClock = SystemClock(),
                            sleep: @escaping Sleep = { try await Task.sleep(for: $0, clock: .continuous) },
                            log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.init(turns: turns, pending: { Self.uncompiled(memory) }, compile: { await compiler.compile() },
                  clock: clock, sleep: sleep, log: log)
    }

    /// True when the archive past facts.json's `compiled_through` holds a message from the user.
    public static func uncompiled(_ memory: MemoryStore) -> Bool {
        guard let facts = memory.loadFacts() else { return false }
        return memory.archive(after: facts.compiledThrough).entries.contains { $0.role == .user }
    }

    /// Starts the loop. Once: a second call, or one after `stop()`, does nothing.
    public func start() {
        let started = state.withLock { s -> Bool in
            guard s.started == nil, !s.stopped else { return false }
            s.started = clock.now()
            s.loop = Task.detached(priority: .utility) { [weak self] in
                do {
                    while !Task.isCancelled {
                        guard let self else { return }
                        try await self.sleep(Self.checkEvery)
                        await self.check()
                    }
                } catch {
                    // The sleep throws once stop() has cancelled the task: the loop is over.
                }
            }
            return true
        }
        guard started else { return }
        log("Idle compile started: chats are compiled after \(Int(Self.idleAfter / 60)) idle minutes")
    }

    /// One look. When no turn runs, the chat has been idle `idleAfter` since its last activity
    /// (or since `start()`), and this stretch has not been looked at: if user messages are
    /// waiting, waits out any turn that has begun, then compiles. Returns the compile's outcome;
    /// nil when none ran.
    @discardableResult
    public func check() async -> FactCompiler.Outcome? {
        let now = clock.now()
        let stretch = state.withLock { s -> Double? in
            guard let started = s.started, !s.stopped, !turns.isRunning else { return nil }
            let last = turns.lastActivity ?? started
            guard now - last >= Self.idleAfter, s.handled != last else { return nil }
            s.handled = last
            return last
        }
        guard let stretch, pending() else { return nil }
        do { try await turns.waitUntilIdle(sleep: sleep) } catch { return nil }
        guard !state.withLock({ $0.stopped }) else { return nil }
        log("memory: the chat has been idle \(Int((now - stretch) / 60)) minutes; compiling it")
        return await compile()
    }

    /// Cancels the loop and a compile in flight (applicationWillTerminate, before the lock is
    /// released). None starts after.
    public func stop() {
        let loop = state.withLock { s -> Task<Void, Never>? in
            s.stopped = true
            defer { s.loop = nil }
            return s.loop
        }
        guard let loop else { return }
        loop.cancel()
        log("Idle compile stopped")
    }
}
