import Foundation
import JarvisCore

/// A throwaway state root at FileManager.default.temporaryDirectory/jarvis-tests-<UUID>/.
/// Every test that needs files creates its own and removes it in a `defer`.
public final class Sandbox: Sendable {
    public let root: URL
    public let paths: StatePaths

    /// Creates research/, logs/, and an empty jarvis.py marker — the shape `StatePaths.live()`
    /// validates.
    public init() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appending(path: "jarvis-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root.appending(path: "research", directoryHint: .isDirectory),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "logs", directoryHint: .isDirectory),
                               withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "jarvis.py", directoryHint: .notDirectory))
        self.root = root
        self.paths = StatePaths(root: root)
    }

    /// Writes UTF-8 `text` at `relative` (creating parent directories).
    public func write(_ relative: String, _ text: String) throws {
        let url = resolve(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    public func read(_ relative: String) throws -> String {
        try String(contentsOf: resolve(relative), encoding: .utf8)
    }

    public func remove() {
        let tmp = FileManager.default.temporaryDirectory.standardizedFileURL.path(percentEncoded: false)
        let own = root.standardizedFileURL.path(percentEncoded: false)
        precondition(own.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/")
                     && root.lastPathComponent.hasPrefix("jarvis-tests-"),
                     "Sandbox.remove: \(own) is not a sandbox under the temporary directory")
        try? FileManager.default.removeItem(at: root)
    }

    private func resolve(_ relative: String) -> URL {
        precondition(!relative.hasPrefix("/") && !relative.split(separator: "/").contains(".."),
                     "Sandbox path must stay inside the sandbox: \(relative)")
        return root.appending(path: relative, directoryHint: .notDirectory)
    }
}
