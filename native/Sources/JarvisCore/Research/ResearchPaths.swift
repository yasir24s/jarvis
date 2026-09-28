import Foundation

// Where the dissertation dataset lives (plan: M01b §3.2). M0's `StatePaths` already owns
// RESEARCH_DIR / RESEARCH_METRICS / RESEARCH_USAGE, HERE/jarvis.py and VOICEPRINT_FILE;
// this is a thin view over it plus the two paths only the dataset needs.

public struct ResearchPaths: Sendable, Equatable {
    public let state: StatePaths

    /// `here` is the repo root (Python's HERE, ~/jarvis in the app, a Sandbox in tests).
    public init(here: URL) {
        self.state = StatePaths(root: here)
    }

    public init(_ state: StatePaths) {
        self.state = state
    }

    public var here: URL { state.root }
    public var dir: URL { state.researchDir }                        // RESEARCH_DIR
    public var metrics: URL { state.researchMetrics }                // RESEARCH_METRICS
    public var usage: URL { state.researchUsage }                    // RESEARCH_USAGE
    public var jarvisPy: URL { state.jarvisPy }                      // code.bytes / code.lines
    public var voiceprint: URL { state.voiceprint }                  // voiceprint_enrolled
    public var nativeSources: URL {                                  // schema-2 code_native
        here.appending(path: "native/Sources", directoryHint: .isDirectory)
    }

    /// Deviation D1: where an unparseable usage.json's original bytes are kept,
    /// `research/usage.json.corrupt-<unix>`.
    public func usageQuarantine(unix: Int) -> URL {
        dir.appending(path: "usage.json.corrupt-\(unix)", directoryHint: .notDirectory)
    }
}
