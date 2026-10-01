import Foundation
import Synchronization

/// Whether a turn is running, for background work that must not compete with one (D-51 P3:
/// every file read waits while a turn runs). `TurnCoordinator.submit` brackets each accepted
/// turn with `begin()` and `end()`.
public final class TurnActivity: Sendable {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    /// How often a waiter looks again while a turn runs.
    public static let pollInterval: Duration = .milliseconds(500)

    private let running = Mutex(0)

    public init() {}

    public func begin() {
        running.withLock { $0 += 1 }
    }

    public func end() {
        running.withLock { $0 = max(0, $0 - 1) }
    }

    public var isRunning: Bool { running.withLock { $0 > 0 } }

    /// Returns once no turn is running, at once when none is; throws when cancelled.
    public func waitUntilIdle(sleep: Sleep = { try await Task.sleep(for: $0, clock: .suspending) }) async throws {
        while isRunning {
            try await sleep(Self.pollInterval)
        }
        try Task.checkCancellation()
    }
}
