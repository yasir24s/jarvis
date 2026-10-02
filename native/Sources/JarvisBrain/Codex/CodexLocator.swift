import Foundation

/// B2: finds the `codex` CLI. It only looks at the file system and never runs anything.
/// The ChatGPT app bundles the CLI and does not put it on the PATH, so after the override and
/// the PATH, the app's own copy is tried, in /Applications and then in ~/Applications.
public enum CodexLocator {
    /// The driver's error when `find` gives nil; `CodexReason` maps it to "Codex CLI not found".
    public static let notFoundMessage = "enoent: codex"
    /// The CLI inside the ChatGPT app, relative to an Applications folder.
    public static let appRelativePath = "ChatGPT.app/Contents/Resources/codex-cli/bin/codex"

    /// `JARVIS_CODEX_CLI` when it is set (it must then be an absolute path to an executable
    /// file, or nothing is found: an override is never silently replaced by another copy), else
    /// the first `<dir>/codex` on `path`'s absolute fields, else the ChatGPT app's copy.
    public static func find(environment: [String: String], path: String, home: String) -> URL? {
        if let override = environment[CodexConfig.executableKey], !override.isEmpty {
            return override.hasPrefix("/") && isExecutableFile(override) ? URL(fileURLWithPath: override) : nil
        }
        for field in path.split(separator: ":", omittingEmptySubsequences: true) where field.hasPrefix("/") {
            let candidate = String(field) + "/codex"
            if isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        var folders = ["/Applications"]
        if home.hasPrefix("/") {
            folders.append((home.hasSuffix("/") ? String(home.dropLast()) : home) + "/Applications")
        }
        for folder in folders {
            let candidate = folder + "/" + appRelativePath
            if isExecutableFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        return fm.isExecutableFile(atPath: path) && fm.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
