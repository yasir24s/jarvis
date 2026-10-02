import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// B2 part 2: the env `codex` runs under (an allowlist, as `forClaude`'s) and where the CLI is
/// found (`JARVIS_CODEX_CLI`, the PATH, then the ChatGPT app's own copy).
@Suite("B2 Codex child environment and locator")
struct CodexEnvironmentTests {
    @Test func aHostileParentGivesAllowlistedKeysAndNoSecret() {
        let sentinel = "sentinel-\(UUID().uuidString)"
        let secrets = SecretRegistry()
        secrets.register(sentinel)
        let home = "/private/var/empty/robin"
        let parent: [String: String] = [
            "HOME": home, "USER": "robin", "LOGNAME": "robin", "TMPDIR": "/private/var/folders/zz/T/",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_GB.UTF-8", "SHELL": "/bin/zsh",
            "OPENAI_API_KEY": sentinel, "OPENAI_BASE_URL": "http://elsewhere.invalid", "CODEX_HOME": "/tmp/other-home",
            "CODEX_SANDBOX": "seatbelt", "ANTHROPIC_API_KEY": sentinel, "CLAUDE_CODE_OAUTH_TOKEN": sentinel,
            "JARVIS_CODEX_CLI": "/opt/codex", "RUST_LOG": "trace", "OTHER_TOKEN": sentinel,
            "HTTPS_PROXY": "http://robin:\(sentinel)@proxy.invalid:8080", "https_proxy": "http://proxy.invalid:3128",
        ]
        var logged: [String] = []
        let jarvisHome = URL(fileURLWithPath: "/private/var/empty/support/JARVIS/codex-home", isDirectory: true)
        let env = ChildEnvironment.forCodex(parent: parent, codexHome: jarvisHome, secrets: secrets, assertOnDrop: false,
                                            log: { logged.append($0) })
        #expect(Set(env.keys).isSubset(of: ChildEnvironment.codexAllowlist))
        #expect(!env.values.contains { $0.contains(sentinel) })
        // Part 6: CODEX_HOME is JARVIS's own home, never the parent's and never ~/.codex.
        #expect(env["CODEX_HOME"] == "/private/var/empty/support/JARVIS/codex-home/")
        #expect(env["CODEX_HOME"] != parent["CODEX_HOME"] && env["CODEX_HOME"]?.hasPrefix(home + "/.codex") == false)
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_SANDBOX", "ANTHROPIC_API_KEY",
                    "CLAUDE_CODE_OAUTH_TOKEN", "JARVIS_CODEX_CLI", "RUST_LOG", "API_TIMEOUT_MS", "CLAUDE_CODE_MAX_RETRIES"] {
            #expect(env[key] == nil, "\(key)")
        }
        #expect(env["HTTPS_PROXY"] == nil)
        #expect(logged == ["child env: dropped HTTPS_PROXY"])
        #expect(env["https_proxy"] == "http://proxy.invalid:3128")
        #expect(env["HOME"] == home && env["USER"] == "robin" && env["LOGNAME"] == "robin")
        #expect(env["LANG"] == "en_GB.UTF-8" && env["SHELL"] == "/bin/zsh")
        #expect(env["PATH"] == ChildEnvironment.path(parent: parent["PATH"], home: home))
        #expect(ChildEnvironment.isForbiddenCodexKey("OPENAI_API_KEY") && ChildEnvironment.isForbiddenCodexKey("CODEX_SANDBOX"))
        #expect(!ChildEnvironment.isForbiddenCodexKey("CODEX_HOME") && ChildEnvironment.isForbiddenCodexKey("CODEX_HOME_X"))
        #expect(!ChildEnvironment.isForbiddenCodexKey("HOME") && !ChildEnvironment.isForbiddenCodexKey("PATH"))
    }

    /// Part 6: JARVIS's Codex home is under Application Support, and the user's own ~/.codex is
    /// refused however it is written, or reached through a link.
    @Test func codexHomeIsJarvissOwnAndNeverTheUsers() throws {
        #expect(CodexHome.directory.path(percentEncoded: false).hasSuffix("/Application Support/JARVIS/codex-home/"))
        let box = try Sandbox()
        defer { box.remove() }
        let userHome = box.root.path(percentEncoded: false)
        let users = box.root.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: users, withIntermediateDirectories: true)
        let link = box.root.appending(path: "looks-like-jarvis", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: users)
        #expect(CodexHome.refusal(users, userHome: userHome) == "the user's own ~/.codex")
        #expect(CodexHome.refusal(URL(fileURLWithPath: userHome + "/./.codex/"), userHome: userHome) == "the user's own ~/.codex")
        #expect(CodexHome.refusal(link, userHome: userHome) == "the user's own ~/.codex")
        let relative = try #require(URL(string: "relative/codex-home"))
        #expect(CodexHome.refusal(relative, userHome: userHome) == "not an absolute path")
        let own = box.root.appending(path: "support/JARVIS/codex-home", directoryHint: .isDirectory)
        #expect(CodexHome.refusal(own, userHome: userHome) == nil)

        // prepare: created 0700, and 0700 put back.
        try CodexHome.prepare(own)
        func mode() throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: own.path(percentEncoded: false))[.posixPermissions] as? Int
        }
        #expect(try mode() == 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: own.path(percentEncoded: false))
        try CodexHome.prepare(own)
        #expect(try mode() == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: own.path(percentEncoded: false)).isEmpty)
    }

    @Test func locatorOrder() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let root = box.root.path(percentEncoded: false)
        func executable(_ relative: String) throws -> String {
            let url = box.root.appending(path: relative, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
            return url.path(percentEncoded: false)
        }
        let onPath = try executable("bin/codex")
        let inApp = try executable("home/Applications/" + CodexLocator.appRelativePath)
        let override = try executable("custom/codex")
        let home = root + "home"

        #expect(CodexLocator.find(environment: [:], path: "relative:" + root + "bin", home: home)?.path == onPath)
        #expect(CodexLocator.find(environment: [CodexConfig.executableKey: override], path: root + "bin", home: home)?.path
                == override)
        // A set override that is not an absolute executable finds nothing, rather than another copy.
        #expect(CodexLocator.find(environment: [CodexConfig.executableKey: root + "missing"], path: root + "bin",
                                  home: home) == nil)
        #expect(CodexLocator.find(environment: [CodexConfig.executableKey: "codex"], path: root + "bin", home: home) == nil)
        // Not on the PATH: the ChatGPT app's copy, here in ~/Applications.
        let found = CodexLocator.find(environment: [:], path: root + "nothing-here", home: home)?.path
        let system = "/Applications/" + CodexLocator.appRelativePath
        #expect(found == (FileManager.default.isExecutableFile(atPath: system) ? system : inApp))
        #expect(CodexLocator.notFoundMessage == "enoent: codex")
    }
}
