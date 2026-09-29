import Foundation
import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// A-8 (plan M02-M04 §5) and the child PATH rule, checked against m3_claude_env_path: the
/// REAL `_claude_env()["PATH"]` for fourteen parent PATHs (tools/golden_brain.py), except the
/// eleven cases with a missing PATH or an empty or relative field, which follow their `native`
/// block (DEV-M3-01, DEV-M3-02, DEV-M3-03). The fixture's
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

    /// Native must match the case's `native` block when it has one (DEV-M3-01: a missing or
    /// empty parent PATH starts from `ChildEnvironment.fallbackPATH`; DEV-M3-02 and DEV-M3-03:
    /// empty and relative fields are dropped), and Python otherwise.
    /// Python's value for a deviating case stays recorded as a known issue.
    @Test(arguments: try Golden.cases("m3_claude_env_path"))
    func pathMatchesPythonOrRegisteredDeviation(_ c: GoldenCase) throws {
        let r = Self.check(c)
        #expect(r.native.isEmpty, "\(c.name): \(r.native)")
        if let d = r.divergence {
            withKnownIssue(Comment(rawValue: d)) {
                for m in r.python { Issue.record(Comment(rawValue: "\(c.name): \(m)")) }
            }
        }
    }

    @Test func allPathCasesAsserted() throws {
        let results = try Golden.cases("m3_claude_env_path").map(Self.check)
        let passed = results.filter { $0.native.isEmpty }.count
        let deviations = results.compactMap(\.divergence)
        let count = { (id: String) in deviations.filter { $0 == id }.count }
        print("m3_claude_env_path: \(passed)/\(results.count); DEV-M3-01 \(count("DEV-M3-01")), "
              + "DEV-M3-02 \(count("DEV-M3-02")), DEV-M3-03 \(count("DEV-M3-03"))")
        #expect(passed == results.count && results.count == 14)
        #expect(count("DEV-M3-01") == 2 && count("DEV-M3-02") == 4 && count("DEV-M3-03") == 5 && deviations.count == 11)
    }

    /// DEV-M3-02 and DEV-M3-03: whatever the parent PATH and HOME, every field of the child PATH
    /// is absolute, so command lookup never searches from the working directory.
    @Test func childPathHasOnlyAbsoluteFields() {
        let parents: [String?] = [nil, "", ":", "::", "/usr/bin:", ":/usr/bin", "/usr/bin::/bin", ".", "..",
                                  ".:bin", "./bin:/usr/bin", "~/bin:/usr/bin", "/usr/bin:bin:/bin", "/usr/bin:/bin"]
        for home in [Self.home, "relative/home", ""] {
            for parent in parents {
                let fields = ChildEnvironment.path(parent: parent, home: home)
                    .split(separator: ":", omittingEmptySubsequences: false)
                #expect(fields.allSatisfy { $0.hasPrefix("/") }, "home \(home), parent \(String(describing: parent))")
            }
        }
        for parent in [nil, "", ":", "::", ".", ".:bin"] as [String?] {
            #expect(ChildEnvironment.path(parent: parent, home: Self.home).hasSuffix(":" + ChildEnvironment.fallbackPATH),
                    "\(String(describing: parent))")
        }
        #expect(!ChildEnvironment.path(parent: "/usr/bin", home: "relative/home").contains("relative/home"))
    }

    struct PathCheck { var native: [String]; var python: [String]; var divergence: String? }

    static func check(_ c: GoldenCase) -> PathCheck {
        guard c.input.string("HOME") == homeToken, let pythonRaw = c.expected.string("PATH") else {
            return PathCheck(native: ["malformed case"], python: [], divergence: nil)
        }
        var parent = ["HOME": home]
        if let p = c.input.string("PATH") { parent["PATH"] = p.replacingOccurrences(of: homeToken, with: home) }
        let env = ChildEnvironment.forClaude(parent: parent, config: ClaudeConfig(environment: [:]),
                                             secrets: SecretRegistry(), assertOnDrop: false, log: { _ in })
        let direct = ChildEnvironment.path(parent: parent["PATH"], home: home)
        func mismatches(_ raw: String) -> [String] {
            let expected = raw.replacingOccurrences(of: homeToken, with: home)
            var out: [String] = []
            if env["PATH"] != expected { out.append("forClaude PATH \(env["PATH"] ?? "nil") != \(expected)") }
            if direct != expected { out.append("path(parent:home:) \(direct) != \(expected)") }
            return out
        }
        guard let native = c.expected.object("native") else {
            return PathCheck(native: mismatches(pythonRaw), python: [], divergence: nil)
        }
        let divergence = native.string("divergence") ?? "unnamed divergence"
        guard let nativeRaw = native.string("PATH") else {
            return PathCheck(native: ["native block without PATH"], python: mismatches(pythonRaw), divergence: divergence)
        }
        return PathCheck(native: mismatches(nativeRaw), python: mismatches(pythonRaw), divergence: divergence)
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
