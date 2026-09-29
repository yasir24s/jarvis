/// Batches streamed deltas into UI updates at 30 Hz or less (plan: M02-M04 §3.12). The first
/// delta shows at once; after an update, text that arrives within `minimumGap` is held until
/// the gap has passed, then shown in one update. The end of a turn shows everything.
public struct DeltaCoalescer: Sendable {
    /// The shortest gap between two updates: 1/30 s.
    public static let interval: Duration = .seconds(1) / 30

    public enum Step: Sendable, Equatable {
        /// Update the row now.
        case publish
        /// Hold the text; update the row at this instant.
        case hold(until: ContinuousClock.Instant)
    }

    public let minimumGap: Duration
    /// The text the row shows.
    public private(set) var shown = ""
    /// Text received since the last update.
    public private(set) var pending = ""
    private var lastPublish: ContinuousClock.Instant?

    public init(minimumGap: Duration = DeltaCoalescer.interval) {
        self.minimumGap = minimumGap
    }

    /// Everything received so far, shown or not.
    public var text: String { shown + pending }

    /// Takes one delta and says whether the row may update now.
    public mutating func append(_ delta: String, at now: ContinuousClock.Instant) -> Step {
        pending += delta
        if let last = lastPublish, now < last + minimumGap {
            return .hold(until: last + minimumGap)
        }
        return .publish
    }

    /// Moves the held text onto the row and returns the row's new text.
    public mutating func publish(at now: ContinuousClock.Instant) -> String {
        shown += pending
        pending = ""
        lastPublish = now
        return shown
    }
}
