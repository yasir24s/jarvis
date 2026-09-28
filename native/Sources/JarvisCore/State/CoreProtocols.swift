import Foundation
import Synchronization

// Protocols injected into Core (plan: M01 §3.6). Everything Core needs from the outside world
// (the time, the dataset counters, the single-instance lease, the frontmost app, the persona
// LLM) comes in through one of these, so every golden test can pin it.

// MARK: - Clock (decision D-26: canonical for M1)

/// `time.time()`: epoch seconds as a Double.
public protocol JarvisClock: Sendable {
    func now() -> Double
}

/// The wall clock, computed exactly as CPython's `time.time()` does on macOS:
/// `clock_gettime(CLOCK_REALTIME)` → ns = sec·1e9 + nsec (Int64) → `PyTime_AsSecondsDouble`,
/// which divides as integers when ns is a whole second and as `Double(ns) / 1e9` otherwise.
public struct SystemClock: JarvisClock {
    public init() {}

    public func now() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        return SystemClock.seconds(ns: Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec))
    }

    /// CPython's `PyTime_AsSecondsDouble` (Python/pytime.c).
    static func seconds(ns: Int64) -> Double {
        if ns % 1_000_000_000 == 0 {
            return Double(ns / 1_000_000_000)
        }
        return Double(ns) / 1e9
    }
}

/// A clock the test (or the golden harness replay) sets by hand.
public final class ManualClock: JarvisClock {
    private let t: Mutex<Double>

    public init(_ t: Double) {
        self.t = Mutex(t)
    }

    public func now() -> Double {
        t.withLock { $0 }
    }

    public func set(_ t: Double) {
        self.t.withLock { $0 = t }
    }

    public func advance(_ dt: Double) {
        t.withLock { $0 += dt }
    }
}

// MARK: - Dataset counters

/// Bumps one research counter (`research/usage.json[day][key] += n`).
/// SYNCHRONOUS, ordered and never throws: the order of bumps decides the key order inside
/// `usage.json[day]`, and so the file's bytes (M01 §8 R10). Implemented by the dataset
/// section (M01b); M1 tests use `RecordingCounter`.
public protocol ResearchCounting: Sendable {
    func bump(_ key: String, by n: Int)
}

// MARK: - Real-state lease

/// Proof that this process may write the real state files: it holds M0's single-instance
/// guard. `StateStore` requires `isHeld` at construction for a real repo root and re-checks
/// it before every save.
public protocol StateLease: Sendable {
    var isHeld: Bool { get }
}

/// The lease backed by M0's `InstanceLock`: holding the lock is the lease.
///
/// The flock lives on the lock file's inode, so the lease also counts as lost when the path
/// no longer names the inode that was locked (the file was deleted or replaced: another
/// process could then lock the new file and believe it is alone). `release()` drops the lock.
public final class InstanceLockLease: StateLease {
    private struct State {
        var lock: InstanceLock?
        let identity: (dev: dev_t, ino: ino_t)?
    }

    private let state: Mutex<State>

    /// `lock` must have just been acquired: the inode its path names now is the one recorded.
    public init(_ lock: InstanceLock) {
        state = Mutex(State(lock: lock, identity: InstanceLockLease.identity(of: lock.url)))
    }

    public var isHeld: Bool {
        state.withLock { s in
            guard let lock = s.lock, let held = s.identity,
                  let now = InstanceLockLease.identity(of: lock.url) else { return false }
            return now.dev == held.dev && now.ino == held.ino
        }
    }

    /// Gives the lease up: `isHeld` is false from then on. The lease drops its reference to
    /// the lock, so the flock is released as soon as no one else holds the `InstanceLock`.
    public func release() {
        state.withLock { $0.lock = nil }
    }

    private static func identity(of url: URL) -> (dev: dev_t, ino: ino_t)? {
        var st = stat()
        guard stat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }
}

// MARK: - Frontmost app

/// `_front_app`: the frontmost application's localized name, "" when unknown.
/// `WorkspaceFrontApp` (JarvisApp) is the real binding.
public protocol FrontAppProviding: Sendable {
    func frontmostAppName() async -> String
}

// MARK: - Persona LLM

/// The LLM used by personality consolidation and distillation (M01 §8 R9).
public protocol PersonaLLM: Sendable {
    /// One-shot completion, temperature 0 (greedy). Throws on any failure or timeout.
    func complete(system: String, user: String, timeout: Duration) async throws -> String
}
