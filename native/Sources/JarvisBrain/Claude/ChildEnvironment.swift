import Foundation
import JarvisCore

/// The environment `claude` runs under (plan: M02-M04 §3.6 "Child env"). It is an allowlist
/// built from nothing, never the app's environment minus a denylist.
public enum ChildEnvironment {
    /// Always set, from the parent; when the parent lacks one, from the process's own
    /// account (the passwd entry, like Python's expanduser) and NSTemporaryDirectory().
    public static let identityKeys = ["HOME", "USER", "LOGNAME", "TMPDIR"]
    /// Copied only when the parent has them.
    public static let passThroughKeys = ["LC_ALL", "SHELL",
                                         "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
                                         "https_proxy", "http_proxy", "no_proxy", "all_proxy"]
    /// Every key `forClaude` can emit.
    public static let allowlist: Set<String> = Set(identityKeys + passThroughKeys
                                                   + ["LANG", "PATH", "API_TIMEOUT_MS", "CLAUDE_CODE_MAX_RETRIES"])
    public static let defaultLang = "en_US.UTF-8"

    /// The post-build check's key pattern, as written in the plan.
    public static let forbiddenKeyPattern = #"^(ANTHROPIC_|CLAUDECODE$|CLAUDE_CODE_(?!MAX_RETRIES$))|ELEVEN|_KEY$|_TOKEN$|_SECRET$"#
    private static let forbiddenKey: PyRegex = {
        do { return try PyRegex(forbiddenKeyPattern) } catch { preconditionFailure("ChildEnvironment: \(error)") }
    }()

    public static func isForbiddenKey(_ key: String) -> Bool {
        forbiddenKey.search(key) != nil
    }

    /// The env for one `claude` run. After building it, any key matching
    /// `forbiddenKeyPattern`, or whose value holds a value registered in `secrets`, is dropped
    /// and `child env: dropped <KEY>` is logged (the key name only). With `assertOnDrop`
    /// (the default) a drop is also an `assertionFailure` in DEBUG; tests of the drop path
    /// pass false.
    public static func forClaude(parent: [String: String], config: ClaudeConfig,
                                 secrets: SecretRegistry = .shared, assertOnDrop: Bool = true,
                                 log: (String) -> Void = { JarvisLog.log($0, category: .brain) })
        -> [String: String] {
        var env: [String: String] = [:]
        let account = Account.current
        env["HOME"] = parent["HOME"] ?? account.home
        env["USER"] = parent["USER"] ?? account.name
        env["LOGNAME"] = parent["LOGNAME"] ?? account.name
        env["TMPDIR"] = parent["TMPDIR"] ?? NSTemporaryDirectory()
        env["LANG"] = parent["LANG"] ?? defaultLang
        env["PATH"] = path(parent: parent["PATH"], home: parent["HOME"] ?? account.home)
        env["API_TIMEOUT_MS"] = config.timeoutMS
        env["CLAUDE_CODE_MAX_RETRIES"] = "1"
        for key in passThroughKeys {
            if let value = parent[key] { env[key] = value }
        }
        for key in env.keys.sorted() where isForbiddenKey(key) || secrets.contains(env[key] ?? "") {
            env[key] = nil
            log("child env: dropped \(key)")
            if assertOnDrop { assertionFailure("child env: dropped \(key)") }
        }
        return env
    }

    /// The base PATH when the parent has none (plan §3.6, DEV-M3-01).
    public static let fallbackPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// `_claude_env()["PATH"]`, with three registered differences. An empty or relative
    /// `:`-separated field (`.`, `bin`, `~/bin`; lookup never expands `~`) makes command lookup
    /// search from the working directory, so the parent's PATH keeps only its absolute fields
    /// (DEV-M3-02 for empty, DEV-M3-03 for relative), and when nothing is left, because the PATH
    /// is unset, empty or has no absolute field, it starts from `fallbackPATH` (DEV-M3-01). Python
    /// keeps every field and starts an unset PATH from "", which also leaves the system
    /// directories out. Then `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin` are each
    /// prepended, in that order, when they are not already one of its fields; `~/.local/bin` is
    /// skipped when a relative `home` would make it relative (DEV-M3-03). Golden suite
    /// m3_claude_env_path. `home` is `$HOME`, as `os.path.expanduser` reads it.
    public static func path(parent: String?, home: String) -> String {
        var path = fields(parent ?? "").filter { Py.startsWith($0, "/") }.joined(separator: ":")  // DEV-M3-02, -03
        if path.isEmpty { path = fallbackPATH }                                                    // DEV-M3-01
        let localBin = Py.rstrip(home, "/") + "/.local/bin"      // expanduser("~/.local/bin")
        for dir in [localBin, "/opt/homebrew/bin", "/usr/local/bin"] where Py.startsWith(dir, "/") {  // DEV-M3-03
            if !fields(path).contains(where: { Py.eq($0, dir) }) {
                path = dir + ":" + path
            }
        }
        return path
    }

    /// Python's `s.split(":")`: empty fields kept, split on the code point only.
    static func fields(_ s: String) -> [String] {
        var out: [String] = []
        var field = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u == ":" {
                out.append(String(field))
                field = String.UnicodeScalarView()
            } else {
                field.append(u)
            }
        }
        out.append(String(field))
        return out
    }

    struct Account {
        let home: String
        let name: String

        /// The passwd entry via getpwuid_r (getpwuid's static buffer is not thread-safe).
        static var current: Account {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 4096)
            let found: Account? = buffer.withUnsafeMutableBufferPointer { buf in
                guard getpwuid_r(getuid(), &entry, buf.baseAddress!, buf.count, &result) == 0, result != nil,
                      let dir = entry.pw_dir, let name = entry.pw_name else { return nil }
                return Account(home: String(cString: dir), name: String(cString: name))
            }
            return found ?? Account(home: NSHomeDirectory(), name: NSUserName())
        }
    }
}
