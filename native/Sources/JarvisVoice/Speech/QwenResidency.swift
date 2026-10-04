import Foundation
import JarvisCore

/// V10: keeps the Qwen model resident. Live (8 GB Mac), after about 10 min idle the helper's whole
/// 1.8 GB model had been swapped out, and the next reply paged it back in: the warm-up took 7.4 s
/// and the reply ran at 0.63x real time. The helper wires the model in memory while resident is
/// on (`QwenEngine.setResident`). This turns it off while the voice is F5, once speech has been
/// muted longer than `mutedLimit`, or while memory is critically short (under `criticalFreePercent`
/// free), and on again when none of those holds. It looks every `interval`.
@MainActor
public final class QwenResidency {
    public struct Hooks {
        /// Qwen is the voice in use.
        var usesQwen: @MainActor () -> Bool
        /// Stop Speaking is on.
        var muted: @MainActor () -> Bool
        /// The share of memory free, in percent; nil when it cannot be read.
        var memoryFreePercent: @MainActor () -> Int?
        /// Tells the engine (`QwenEngine.setResident`).
        var setResident: @Sendable (Bool) async -> Void
        var now: @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .suspending) }
        var log: @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }

        public init(usesQwen: @escaping @MainActor () -> Bool, muted: @escaping @MainActor () -> Bool,
                    memoryFreePercent: @escaping @MainActor () -> Int?, setResident: @escaping @Sendable (Bool) async -> Void,
                    now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
                    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, clock: .suspending) },
                    log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }) {
            self.usesQwen = usesQwen
            self.muted = muted
            self.memoryFreePercent = memoryFreePercent
            self.setResident = setResident
            self.now = now
            self.sleep = sleep
            self.log = log
        }
    }

    public static let interval: Duration = .seconds(30)
    /// Muted longer than this, the model may go to swap.
    public static let mutedLimit: Duration = .seconds(600)
    /// Under this share free, memory is critically short and the wired model is let go.
    public static let criticalFreePercent = 10

    private let hooks: Hooks
    private var mutedSince: ContinuousClock.Instant?
    /// What the engine was last told; the engine starts with resident on.
    public private(set) var resident = true

    public init(_ hooks: Hooks) {
        self.hooks = hooks
    }

    /// Why resident should be off now, or nil when it should be on.
    public func reasonOff() -> String? {
        let now = hooks.now()
        if hooks.muted() {
            if mutedSince == nil { mutedSince = now }
        } else {
            mutedSince = nil
        }
        if !hooks.usesQwen() { return "the voice is F5" }
        if let since = mutedSince, now - since > Self.mutedLimit { return "speech muted over \(Int(Self.mutedLimit / .seconds(60))) min" }
        if let free = hooks.memoryFreePercent(), free < Self.criticalFreePercent { return "\(free)% of memory free" }
        return nil
    }

    /// One look: tells the engine when the answer changed.
    public func check() async {
        let reason = reasonOff()
        let want = reason == nil
        guard want != resident else { return }
        resident = want
        hooks.log("voice: Qwen model resident " + (want ? "on" : "off (\(reason ?? ""))"))
        await hooks.setResident(want)
    }

    /// Looks every `interval` until cancelled.
    @discardableResult
    public func start() -> Task<Void, Never> {
        let hooks = self.hooks
        return Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.check()
                do { try await hooks.sleep(Self.interval) } catch { return }
            }
        }
    }
}
