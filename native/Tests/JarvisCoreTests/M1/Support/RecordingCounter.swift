import JarvisCore
import Synchronization

/// A `ResearchCounting` that records every bump in call order (M01 §3.6, §8 R10): the order
/// is what the dataset's usage.json key order depends on, so tests compare the whole list.
final class RecordingCounter: ResearchCounting {
    struct Bump: Equatable, Sendable, CustomStringConvertible {
        let key: String
        let n: Int
        var description: String { "\(key)+\(n)" }
    }

    private let log = Mutex<[Bump]>([])

    func bump(_ key: String, by n: Int) {
        log.withLock { $0.append(Bump(key: key, n: n)) }
    }

    /// Every bump so far, oldest first.
    var bumps: [Bump] { log.withLock { $0 } }

    func reset() { log.withLock { $0.removeAll() } }
}
