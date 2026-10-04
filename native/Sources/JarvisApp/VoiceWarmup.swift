import Darwin
import Foundation
import JarvisCore
import JarvisVoice

/// Live fix 5: the first Qwen reply of the first live session waited 10.1 s for its first audio,
/// later ones 0.8 to 1.8 s, because the helper loads its model (and runs its warm-up line) on
/// first use. Shortly after launch, once JARVIS is idle, the helper is started and loaded, unless
/// memory is short: then it waits and looks again, and gives up after `attempts`.
@MainActor
final class QwenPrewarm {
    struct Hooks {
        /// Qwen is the voice in use.
        var usesQwen: @MainActor () -> Bool
        /// No turn runs, nothing is spoken, nobody is talking to him.
        var isIdle: @MainActor () -> Bool
        /// The share of memory free, in percent; nil when it cannot be read.
        var memoryFreePercent: @MainActor () -> Int?
        /// Starts the helper and loads the model (`AppVoice.warm`).
        var warm: @MainActor () -> Void
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .suspending) }
        var log: @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }
    }

    /// After launch, before the first look.
    static let delay: Duration = .seconds(20)
    /// Between looks while JARVIS is busy or memory is short.
    static let retry: Duration = .seconds(60)
    static let attempts = 10
    /// The same share the build lock waits for (memory_pressure's free percentage).
    static let minimumFreePercent = 20

    private let hooks: Hooks

    init(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// Runs the pre-warm on a task of its own; cancel it to give up.
    @discardableResult
    func start() -> Task<Void, Never> {
        let hooks = self.hooks
        return Task { @MainActor in
            do {
                try await hooks.sleep(Self.delay)
                var short = false
                for _ in 0..<Self.attempts {
                    guard hooks.usesQwen() else { return }
                    if hooks.isIdle() {
                        let free = hooks.memoryFreePercent()
                        if let free, free < Self.minimumFreePercent {
                            if !short { hooks.log("voice: Qwen pre-warm waits: \(free)% of memory free") }
                            short = true
                        } else {
                            hooks.warm()
                            hooks.log("voice: pre-warming the Qwen helper (" + (free.map { "\($0)% of memory free" } ?? "memory unknown") + ")")
                            return
                        }
                    }
                    try await hooks.sleep(Self.retry)
                }
                hooks.log("voice: Qwen pre-warm gave up; the first reply loads the model")
            } catch {
                return   // cancelled
            }
        }
    }

    /// `kern.memorystatus_level`: the free percentage `memory_pressure` reports.
    nonisolated static func systemFreePercent() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }
}

/// Live fix 5: in the first live session a typed reply waited 1682 ms for voice processing to
/// switch on, because the switch began only when the reply's speech was being generated. When a
/// turn starts whose reply will be spoken, the switch starts now, so it runs while the brain
/// thinks. It is held until the turn ends (the reply's own hold takes over, inside the hub's
/// tail) or `limit` passes, whichever is first, and released exactly once.
@MainActor
final class VoiceProcessingAhead {
    static let limit: Duration = .seconds(60)

    private let willStart: @MainActor () -> Void
    private let ended: @MainActor () -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var holding = false
    private var token = 0

    init(willStart: @escaping @MainActor () -> Void, ended: @escaping @MainActor () -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .suspending) }) {
        self.willStart = willStart
        self.ended = ended
        self.sleep = sleep
    }

    var isHolding: Bool { holding }

    /// A turn whose reply will be spoken has started.
    func turnStarting() {
        guard !holding else { return }
        holding = true
        token += 1
        let mine = token
        willStart()
        let sleep = self.sleep
        Task { @MainActor [weak self] in
            try? await sleep(Self.limit)
            self?.release(mine)
        }
    }

    /// The turn ended.
    func turnOver() {
        release(token)
    }

    private func release(_ mine: Int) {
        guard holding, mine == token else { return }
        holding = false
        ended()
    }
}

/// V9: the first reply after an idle spell broke up. Live (Claude brain, Qwen voice, the same
/// 213-character reply), the first pass after idle was delivered at 0.88x real time with 11
/// underruns (1565 ms), the immediate repeat with none: the helper generates slower the first time
/// after sitting idle. When a turn starts whose reply a cloud brain writes and Qwen speaks, and the
/// helper has been idle more than `idleLimit`, it generates a short throwaway line
/// (`QwenEngine.warmUp`) while the brain thinks. The reply's first request cuts it short, so it
/// never delays the reply; nothing it generates is played.
@MainActor
final class TurnStartWarmup {
    struct Hooks {
        /// Qwen is the voice in use.
        var usesQwen: @MainActor () -> Bool
        /// Claude or ChatGPT writes the reply (on-device, the warm-up would compete with
        /// Foundation Models).
        var cloudBrain: @MainActor () -> Bool
        /// Stop Speaking is on.
        var muted: @MainActor () -> Bool
        /// The share of memory free, in percent; nil when it cannot be read.
        var memoryFreePercent: @MainActor () -> Int?
        /// Seconds since the helper last worked (`QwenEngine.idleSeconds`).
        var idleSeconds: @Sendable () async -> Double?
        /// Runs the warm-up; true when it finished (`QwenEngine.warmUp`).
        var warmUp: @Sendable () async -> Bool
        /// V9 part 3: the next reply's voice starts cold (`SpeechPlayer.expectColdVoice`).
        var coldVoice: @Sendable (Bool) async -> Void = { _ in }
        var log: @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }
    }

    /// Idle longer than this, the helper's next generation runs cold.
    static let idleLimit = 120.0

    private let hooks: Hooks
    private var running: Task<Void, Never>?

    init(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// A user turn started (a typed send, push-to-talk, the wake word).
    @discardableResult
    func turnStarting() -> Task<Void, Never>? {
        guard running == nil, hooks.usesQwen(), !hooks.muted() else { return nil }
        let cloud = hooks.cloudBrain()
        let free = hooks.memoryFreePercent()
        let memoryShort = free.map { $0 < QwenPrewarm.minimumFreePercent } ?? false
        let hooks = self.hooks
        let task = Task { @MainActor [weak self] in
            defer { self?.running = nil }
            guard let idle = await hooks.idleSeconds(), idle > Self.idleLimit else {
                await hooks.coldVoice(false)
                return
            }
            // Cold until a warm-up finishes: one cut short by the reply leaves it cold.
            await hooks.coldVoice(true)
            guard cloud, !memoryShort else {
                hooks.log("voice: helper idle \(Int(idle)) s, no warm-up (" + (cloud ? "memory short" : "on-device brain")
                          + "): the reply's pre-roll starts at x\(EnginePlayer.coldStartRate)")
                return
            }
            let started = ContinuousClock.now
            let finished = await hooks.warmUp()
            if finished { await hooks.coldVoice(false) }
            let took = String(format: "%.1f", (ContinuousClock.now - started) / .seconds(1))
            hooks.log("voice: warm-up at turn start (idle \(Int(idle)) s), took \(took) s"
                      + (finished ? "" : " (cut short)"))
        }
        running = task
        return task
    }
}
