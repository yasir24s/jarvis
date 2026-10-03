import Darwin
import Foundation
import JarvisCore

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
