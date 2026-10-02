import Foundation
import JarvisCore

/// B2: the environment `codex` runs under, built from nothing like `forClaude`'s: the same
/// identity keys, PATH, LANG and pass-through keys, and none of Claude's own. Part 6:
/// `CODEX_HOME` is always JARVIS's own home (`CodexHome`), never the parent's and never the
/// user's `~/.codex`. `OPENAI_API_KEY` is never passed, so a turn cannot move from the ChatGPT
/// plan to API billing.
extension ChildEnvironment {
    /// Every key `forCodex` can emit.
    public static let codexAllowlist: Set<String> = Set(identityKeys + passThroughKeys + ["LANG", "PATH", "CODEX_HOME"])

    /// The post-build check's key pattern for a codex child: `CODEX_HOME` is the one CODEX_ key
    /// allowed, and only `forCodex` sets it.
    public static let codexForbiddenKeyPattern = #"^(OPENAI_|CODEX_(?!HOME$)|ANTHROPIC_|CLAUDE)|ELEVEN|_KEY$|_TOKEN$|_SECRET$"#
    private static let codexForbiddenKey: PyRegex = {
        do { return try PyRegex(codexForbiddenKeyPattern) } catch { preconditionFailure("ChildEnvironment: \(error)") }
    }()

    public static func isForbiddenCodexKey(_ key: String) -> Bool {
        codexForbiddenKey.search(key) != nil
    }

    /// The env for one `codex` run, with `codexHome` as its `CODEX_HOME`. After building it, any
    /// key matching `codexForbiddenKeyPattern`, or whose value holds a value registered in
    /// `secrets`, is dropped and `child env: dropped <KEY>` is logged (the key name only), as
    /// `forClaude` does. Callers check `CodexHome.refusal` before running anything with it.
    public static func forCodex(parent: [String: String], codexHome: URL, secrets: SecretRegistry = .shared,
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
        env["CODEX_HOME"] = codexHome.path(percentEncoded: false)
        for key in env.keys.sorted() where isForbiddenCodexKey(key) || secrets.contains(env[key] ?? "") {
            env[key] = nil
            log("child env: dropped \(key)")
            if assertOnDrop { assertionFailure("child env: dropped \(key)") }
        }
        return env
    }
}
