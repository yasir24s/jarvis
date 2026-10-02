import Foundation

/// B2 part 6: JARVIS's own Codex home, `<Application Support>/JARVIS/codex-home/`, the
/// `CODEX_HOME` of every `codex` JARVIS runs. Its sign-in is JARVIS's own ("Sign in to
/// ChatGPT…"), and Codex's logs and state from JARVIS's turns stay in it. Nothing is placed in
/// it: no config.toml and no AGENTS.md, so JARVIS's system prompt is the only instruction. The
/// user's `~/.codex` is never used, read or written.
public enum CodexHome {
    /// `<Application Support>/JARVIS/codex-home/`.
    public static var directory: URL {
        BrainAssembly.supportDirectory.appending(path: "codex-home", directoryHint: .isDirectory)
    }

    /// Why `codexHome` may not be JARVIS's `CODEX_HOME`, or nil: it is not absolute, or it is the
    /// user's own `<userHome>/.codex`, as written or once symbolic links are resolved.
    public static func refusal(_ codexHome: URL, userHome: String) -> String? {
        let path = codexHome.path(percentEncoded: false)
        guard path.hasPrefix("/") else { return "not an absolute path" }
        guard userHome.hasPrefix("/") else { return nil }
        let users = URL(fileURLWithPath: userHome, isDirectory: true).appending(path: ".codex", directoryHint: .isDirectory)
        if key(codexHome) == key(users) { return "the user's own ~/.codex" }
        if let a = resolved(codexHome), let b = resolved(users), a == b { return "the user's own ~/.codex" }
        return nil
    }

    /// Creates `codexHome` with mode 0700 if it is missing, and puts 0700 back if it has
    /// another mode.
    public static func prepare(_ codexHome: URL) throws {
        let fm = FileManager.default
        let path = codexHome.path(percentEncoded: false)
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let mode = (try fm.attributesOfItem(atPath: path)[.posixPermissions] as? Int) ?? 0
        if mode != 0o700 {
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
    }

    /// The path, standardized, with no trailing slash.
    private static func key(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The path with every link resolved, or nil if it does not exist.
    private static func resolved(_ url: URL) -> String? {
        guard let p = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }
}
