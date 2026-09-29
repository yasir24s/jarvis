import Foundation

/// Finds the `claude` CLI on the PATH built for the child (plan: M02-M04 §3.6). It only looks
/// at the file system and never runs anything.
public enum ClaudeLocator {
    /// The driver's error when `find` gives nil; `ClaudeReason` maps it to
    /// "Claude Code CLI not found".
    public static let notFoundMessage = "enoent: claude"

    /// The first `<dir>/claude` that is an executable file and not a directory, over the
    /// `:`-separated fields of `path` in order. Empty and relative fields are skipped: they
    /// would resolve against the working directory.
    public static func find(path: String) -> URL? {
        let fm = FileManager.default
        for field in path.split(separator: ":", omittingEmptySubsequences: true) where field.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(field), isDirectory: true)
                .appending(path: "claude", directoryHint: .notDirectory)
            let p = candidate.path(percentEncoded: false)
            var isDirectory: ObjCBool = false
            if fm.isExecutableFile(atPath: p), fm.fileExists(atPath: p, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }
}
