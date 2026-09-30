import Foundation
import JarvisCore

/// A CoreState over a fresh folder in the temporary directory, for the tool bodies that write
/// through one (this target has no JarvisTestSupport). The folder holds no `jarvis.py`, so the
/// StateStore needs no lease and nothing reaches the real `~/jarvis`. Callers `remove()` it.
final class ToolCoreSandbox: Sendable {
    let root: URL
    let store: StateStore
    let core: CoreState

    init(clock: any JarvisClock = ManualClock(0)) throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tools-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try StateStore(root: root.path(percentEncoded: false), lease: nil, clock: clock)
        core = CoreState(store: store, clock: clock, research: NoCounts(), frontApp: NoFrontApp())
    }

    /// Whether personality.json exists (the tools create it on their first write).
    var personalityExists: Bool {
        FileManager.default.fileExists(atPath: store.path(.personality))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct NoCounts: ResearchCounting {
    func bump(_ key: String, by n: Int) {}
}

private struct NoFrontApp: FrontAppProviding {
    func frontmostAppName() async -> String { "" }
}
