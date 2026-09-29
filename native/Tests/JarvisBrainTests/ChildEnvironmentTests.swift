import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// A-8 (plan M02-M04 §5) and the child PATH rule, checked against m3_claude_env_path: the
/// REAL `_claude_env()["PATH"]` for six parent PATHs (tools/golden_brain.py). The fixture's
/// `${JARVIS_HOME}` is the Python child's HOME; any absolute path stands in for it here.
/// Drops are logged through an injected closure, so nothing here writes to JarvisLog.
@Suite("M3 Claude child environment (A-8)")
struct ChildEnvironmentTests {
    static let homeToken = "${JARVIS_HOME}"
    static let home = "/private/var/empty/jarvis-home"

    @Test func a8HostileParentGivesAllowlistedKeysAndNoSecret() throws {
        let sentinel = "sentinel-\(UUID().uuidString)"
        let secrets = SecretRegistry()
        secrets.register(sentinel)
        let robinHome = "/private/var/empty/robin"
        let parent: [String: String] = [
            "HOME": robinHome, "USER": "robin", "LOGNAME": "robin", "TMPDIR": "/private/var/folders/zz/T/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_GB.UTF-8", "SHELL": "/bin/zsh",
            "ANTHROPIC_API_KEY": sentinel, "ELEVENLABS_API_KEY": sentinel,
            "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": UUID().uuidString, "CLAUDE_CODE_ENTRYPOINT": "cli",
            "OTHER_TOKEN": sentinel, "SENTINEL_HOLDER": "before \(sentinel) after",
            "HTTPS_PROXY": "http://robin:\(sentinel)@proxy.invalid:8080",
            "https_proxy": "http://proxy.invalid:3128",
        ]
        var logged: [String] = []
        let env = ChildEnvironment.forClaude(parent: parent, config: ClaudeConfig(environment: [:]), secrets: secrets,
                                             assertOnDrop: false, log: { logged.append($0) })

        #expect(Set(env.keys).isSubset(of: ChildEnvironment.allowlist))
        #expect(!env.values.contains { $0.contains(sentinel) })
        for key in ["ANTHROPIC_API_KEY", "ELEVENLABS_API_KEY", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID"] {
            #expect(env[key] == nil, "\(key)")
        }
        // Allowlisted, but its value held the registered secret: dropped, logged by name only.
        #expect(env["HTTPS_PROXY"] == nil)
        #expect(logged == ["child env: dropped HTTPS_PROXY"])
        #expect(env["https_proxy"] == "http://proxy.invalid:3128")
        #expect(env["HOME"] == robinHome && env["USER"] == "robin" && env["LOGNAME"] == "robin")
        #expect(env["TMPDIR"] == "/private/var/folders/zz/T/" && env["LANG"] == "en_GB.UTF-8")
        #expect(env["SHELL"] == "/bin/zsh")
        #expect(env["API_TIMEOUT_MS"] == "45000" && env["CLAUDE_CODE_MAX_RETRIES"] == "1")

        let system = try #require(try Golden.cases("m3_claude_env_path").first(where: { $0.name == "system" }))
        #expect(system.input.string("PATH") == parent["PATH"])
        let expected = try #require(system.expected.string("PATH")).replacingOccurrences(of: Self.homeToken, with: robinHome)
        #expect(env["PATH"] == expected)
    }

    @Test(arguments: try Golden.cases("m3_claude_env_path"))
    func pathMatchesPython(_ c: GoldenCase) throws {
        #expect(Self.check(c).isEmpty, "\(c.name): \(Self.check(c))")
    }

    @Test func allPathCasesAsserted() throws {
        let cases = try Golden.cases("m3_claude_env_path")
        let passed = cases.filter { Self.check($0).isEmpty }.count
        print("m3_claude_env_path: \(passed)/\(cases.count)")
        #expect(passed == cases.count && cases.count == 6)
    }

    static func check(_ c: GoldenCase) -> [String] {
        guard c.input.string("HOME") == homeToken, let raw = c.expected.string("PATH") else { return ["malformed case"] }
        var parent = ["HOME": home]
        if let p = c.input.string("PATH") { parent["PATH"] = p.replacingOccurrences(of: homeToken, with: home) }
        let expected = raw.replacingOccurrences(of: homeToken, with: home)
        let env = ChildEnvironment.forClaude(parent: parent, config: ClaudeConfig(environment: [:]),
                                             secrets: SecretRegistry(), assertOnDrop: false, log: { _ in })
        var out: [String] = []
        if env["PATH"] != expected { out.append("forClaude PATH \(env["PATH"] ?? "nil")") }
        if ChildEnvironment.path(parent: parent["PATH"], home: home) != expected { out.append("path(parent:home:)") }
        return out
    }

    @Test func forbiddenKeyPattern() {
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDECODE", "CLAUDE_CODE_SESSION_ID",
                    "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_MAX_RETRIES_X", "ELEVENLABS_API_KEY", "X_ELEVEN_Y",
                    "AUDD_KEY", "GH_TOKEN", "AWS_SECRET"] {
            #expect(ChildEnvironment.isForbiddenKey(key), "\(key)")
        }
        for key in ["CLAUDE_CODE_MAX_RETRIES", "CLAUDECODE_X", "PATH", "HOME", "KEYCHAIN", "TOKENS"] {
            #expect(!ChildEnvironment.isForbiddenKey(key), "\(key)")
        }
        for key in ChildEnvironment.allowlist {
            #expect(!ChildEnvironment.isForbiddenKey(key), "allowlisted \(key)")
        }
    }

    @Test func cleanParentHasNoDrops() {
        let parent = ["HOME": "/private/var/empty/sam", "USER": "sam", "LOGNAME": "sam", "TMPDIR": "/private/tmp/sam/",
                      "PATH": "/usr/bin:/bin", "LC_ALL": "en_GB.UTF-8"]
        var logged: [String] = []
        let config = ClaudeConfig(environment: ["JARVIS_CLAUDE_TIMEOUT_MS": "30000"])
        let env = ChildEnvironment.forClaude(parent: parent, config: config, secrets: SecretRegistry(),
                                             log: { logged.append($0) })
        #expect(logged.isEmpty)
        #expect(env == ["HOME": "/private/var/empty/sam", "USER": "sam", "LOGNAME": "sam", "TMPDIR": "/private/tmp/sam/",
                        "LANG": ChildEnvironment.defaultLang, "LC_ALL": "en_GB.UTF-8",
                        "PATH": ChildEnvironment.path(parent: "/usr/bin:/bin", home: "/private/var/empty/sam"),
                        "API_TIMEOUT_MS": "30000", "CLAUDE_CODE_MAX_RETRIES": "1"])
    }

    @Test func identityKeysAreSetEvenWhenTheParentLacksThem() {
        let env = ChildEnvironment.forClaude(parent: [:], config: ClaudeConfig(environment: [:]),
                                             secrets: SecretRegistry(), log: { _ in })
        let always = ChildEnvironment.identityKeys + ["LANG", "PATH", "API_TIMEOUT_MS", "CLAUDE_CODE_MAX_RETRIES"]
        #expect(Set(env.keys) == Set(always))
        for key in always { #expect(!(env[key] ?? "").isEmpty, "\(key)") }
    }
}
