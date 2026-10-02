import Foundation
import JarvisCore

/// B2: the environment `codex` runs under, built from nothing like `forClaude`'s: the same
/// identity keys, PATH, LANG and pass-through keys, and none of Claude's own. `CODEX_HOME` is
/// never passed, so the CLI finds the user's own sign-in in `~/.codex`; `OPENAI_API_KEY` is
/// never passed, so a turn cannot move from the ChatGPT plan to API billing.
extension ChildEnvironment {
    /// Every key `forCodex` can emit.
    public static let codexAllowlist: Set<String> = Set(identityKeys + passThroughKeys + ["LANG", "PATH"])

    /// The post-build check's key pattern for a codex child.
    public static let codexForbiddenKeyPattern = #"^(OPENAI_|CODEX_|ANTHROPIC_|CLAUDE)|ELEVEN|_KEY$|_TOKEN$|_SECRET$"#
    private static let codexForbiddenKey: PyRegex = {
        do { return try PyRegex(codexForbiddenKeyPattern) } catch { preconditionFailure("ChildEnvironment: \(error)") }
    }()

    public static func isForbiddenCodexKey(_ key: String) -> Bool {
        codexForbiddenKey.search(key) != nil
    }

    /// The env for one `codex` run. After building it, any key matching
    /// `codexForbiddenKeyPattern`, or whose value holds a value registered in `secrets`, is
    /// dropped and `child env: dropped <KEY>` is logged (the key name only), as `forClaude` does.
    public static func forCodex(parent: [String: String], secrets: SecretRegistry = .shared,
                                assertOnDrop: Bool = true,
                                log: (String) -> Void = { JarvisLog.log($0, category: .brain) }) -> [String: String] {
        var env: [String: String] = [:]
        let account = Account.current
        env["HOME"] = parent["HOME"] ?? account.home
        env["USER"] = parent["USER"] ?? account.name
        env["LOGNAME"] = parent["LOGNAME"] ?? account.name
        env["TMPDIR"] = parent["TMPDIR"] ?? NSTemporaryDirectory()
        env["LANG"] = parent["LANG"] ?? defaultLang
        env["PATH"] = path(parent: parent["PATH"], home: parent["HOME"] ?? account.home)
        for key in passThroughKeys {
            if let value = parent[key] { env[key] = value }
        }
        for key in env.keys.sorted() where isForbiddenCodexKey(key) || secrets.contains(env[key] ?? "") {
            env[key] = nil
            log("child env: dropped \(key)")
            if assertOnDrop { assertionFailure("child env: dropped \(key)") }
        }
        return env
    }
}
