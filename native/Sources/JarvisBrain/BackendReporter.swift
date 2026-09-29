import Foundation
import JarvisCore

// Backend reporting (plan: M02-M04 §3.10): jarvis.py's LAST_BACKEND, `_set_backend` and
// `_backend_report`. Golden suites run the real functions: m3_backend_key (the counter) and
// m3_backend_report (the report strings and LAST_BACKEND).

public actor BackendReporter {
    /// The local model's name in `report`, where Python says `MODEL` (plan §3.10).
    public static let localDisplayName = "Apple's on-device model"

    /// `_set_backend`'s counter: `"backend_" + re.sub(r"\W+", "_", name.lower())`.
    /// Counter names come from `ResearchKey` (call sites never build them), so this is
    /// `ResearchKey.backend`; golden suite m3_backend_key runs the real `_set_backend`.
    public static func counterKey(_ name: String) -> String {
        ResearchKey.backend(name)
    }

    /// `LAST_BACKEND`: the backend that served the most recent request, and when it was set.
    /// Python starts it at `{"name": "local", "at": 0.0}`.
    public private(set) var last: (name: String, at: Date) = ("local", Date(timeIntervalSince1970: 0))

    private let research: any ResearchCounting
    private let clock: any JarvisClock
    private let log: @Sendable (String) -> Void

    /// - Parameter log: where the "Backend: <name>" line goes. Tests pass their own.
    public init(research: any ResearchCounting, clock: any JarvisClock = SystemClock(),
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .brain) }) {
        self.research = research
        self.clock = clock
        self.log = log
    }

    /// `_set_backend(name)`: record the name and the time, log it, then bump its counter.
    public func set(_ name: String) {
        last = (name, Date(timeIntervalSince1970: clock.now()))
        log("Backend: \(name)")
        research.bump(Self.counterKey(name), by: 1)
    }

    /// `_backend_report()`, with `localModelName` where Python has `MODEL`. The local sentence
    /// is Python's. The Claude sentence names Claude Code, the CLI native reaches Claude
    /// through, where Python says "the Agent SDK" (DEV-M3-04; README D-11 resolves D-6).
    public func report(localModelName: String) -> String {
        if Py.contains(Py.lower(last.name), "claude") {
            return "The last request was handled by Claude, through Claude Code, sir."
        }
        return "The last request was handled by the local model, sir — \(localModelName)."
    }
}

/// The Claude driver reports the backend through this protocol.
extension BackendReporter: BackendReporting {}
