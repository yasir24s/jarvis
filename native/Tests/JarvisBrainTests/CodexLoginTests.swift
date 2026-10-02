import Foundation
@testable import JarvisBrain
import JarvisCore
import JarvisTestSupport
import Testing

/// B2 part 6: `codex login` and `codex login status` under JARVIS's own Codex home, against a
/// fake `codex` (a /bin/sh script). The fake records its argv, env and working directory;
/// `login status` reports a state file, and `login` sets it, fails or hangs as the test says.
@Suite("B2 ChatGPT sign-in: codex login under JARVIS's Codex home", .timeLimit(.minutes(1)))
struct CodexLoginTests {
    enum LoginEnding: String {
        case signIn = "touch \"$D/signedin\"; exit 0"
        case fail = "exit 1"
        case hang = "exec /bin/sleep 30"
    }

    struct Fake {
        let box: Sandbox
        var root: URL { box.root }
        var script: URL { root.appending(path: "fake-codex", directoryHint: .notDirectory) }
        var codexHome: URL { root.appending(path: "support/JARVIS/codex-home", directoryHint: .isDirectory) }
        var parent: [String: String] {
            ["HOME": root.path(percentEncoded: false), "USER": "robin", "LOGNAME": "robin", "PATH": "/usr/bin:/bin",
             "CODEX_HOME": root.appending(path: ".codex").path(percentEncoded: false), "OPENAI_API_KEY": "sk-test"]
        }

        init(login: LoginEnding, signedIn: Bool = false, statusText: String? = nil) throws {
            box = try Sandbox()
            let d = box.root.path(percentEncoded: false)
            precondition(!d.contains("'"))
            let status = statusText.map { "printf '%s\\n' '\($0)'; exit 0" }
                ?? #"if [ -f "$D/signedin" ]; then echo "Logged in using ChatGPT"; exit 0; else echo "Not logged in" >&2; exit 1; fi"#
            let text = """
                #!/bin/sh
                D='\(d)'
                n=$(/bin/ls "$D" | /usr/bin/grep -c '^argv' )
                for a in "$@"; do printf '%s\\0' "$a"; done > "$D/argv$n"
                /usr/bin/env > "$D/env$n"
                /bin/pwd -P > "$D/cwd$n"
                if [ "$1" = login ] && [ "$2" = status ]; then
                  \(status)
                fi
                if [ "$1" = login ]; then
                  echo "Starting local login server; open https://auth.example.invalid/authorize?state=not-a-secret"
                  \(login.rawValue)
                fi
                exit 9

                """
            try box.write("fake-codex", text)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
            if signedIn { try box.write("signedin", "") }
        }

        func login(timeout: Duration = CodexLogin.signInTimeout) -> CodexLogin {
            CodexLogin(executable: script, codexHome: codexHome, parentEnvironment: parent, signInTimeout: timeout)
        }

        func argv(_ n: Int) -> [String]? {
            guard let data = try? Data(contentsOf: root.appending(path: "argv\(n)")) else { return nil }
            var parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            if parts.last == "" { parts.removeLast() }
            return parts
        }

        func env(_ n: Int) -> [String: String] {
            var env: [String: String] = [:]
            for line in ((try? box.read("env\(n)")) ?? "").components(separatedBy: "\n") where !line.isEmpty {
                let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                env[String(pair[0])] = pair.count > 1 ? String(pair[1]) : ""
            }
            return env
        }
    }

    static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path(percentEncoded: false), nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    @Test func theArgv() {
        #expect(CodexLogin.statusArguments
                == ["login", "status", "-c", #"cli_auth_credentials_store="file""#, "-c", #"forced_login_method="chatgpt""#])
        #expect(CodexLogin.signInArguments
                == ["login", "-c", #"cli_auth_credentials_store="file""#, "-c", #"forced_login_method="chatgpt""#])
        for a in [CodexLogin.statusArguments, CodexLogin.signInArguments] {
            #expect(!a.contains { $0.contains("api-key") || $0.contains("access-token") || $0 == "--device-auth" })
        }
    }

    @Test func statusParsing() {
        #expect(CodexLogin.parseStatus(exit: 0, output: "Logged in using ChatGPT\n") == .signedIn)
        #expect(CodexLogin.parseStatus(exit: 1, output: "Not logged in\n") == .signedOut)
        // An API key or an access token is not a ChatGPT sign-in, and a non-zero exit never is.
        #expect(CodexLogin.parseStatus(exit: 0, output: "Logged in using an API key - sk-proj-***ABCD\n") == .signedOut)
        #expect(CodexLogin.parseStatus(exit: 0, output: "Logged in using access token\n") == .signedOut)
        #expect(CodexLogin.parseStatus(exit: 1, output: "Logged in using ChatGPT\n") == .signedOut)
    }

    /// The status runs under JARVIS's home, in it, with forCodex's env: never the parent's
    /// CODEX_HOME or key.
    @Test func statusRunsUnderJarvissHome() async throws {
        let fake = try Fake(login: .fail, signedIn: true)
        defer { fake.box.remove() }
        #expect(await fake.login().status() == .signedIn)
        #expect(fake.argv(0) == CodexLogin.statusArguments)
        let env = fake.env(0)
        #expect(env["CODEX_HOME"] == fake.codexHome.path(percentEncoded: false))
        #expect(env["OPENAI_API_KEY"] == nil)
        #expect(Set(env.keys).subtracting(["PWD", "SHLVL", "_", "OLDPWD"]).isSubset(of: ChildEnvironment.codexAllowlist))
        #expect((try? fake.box.read("cwd0"))?.trimmingCharacters(in: .newlines) == Self.realPath(fake.codexHome))
        let mode = try FileManager.default.attributesOfItem(atPath: fake.codexHome.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func statusSignedOutAndNoCodex() async throws {
        let fake = try Fake(login: .fail)
        defer { fake.box.remove() }
        #expect(await fake.login().status() == .signedOut)
        let none = CodexLogin(executable: nil, codexHome: fake.codexHome, parentEnvironment: fake.parent)
        #expect(await none.status() == .unavailable("Codex CLI not found"))
        let missing = CodexLogin(executable: fake.root.appending(path: "no-such-codex"), codexHome: fake.codexHome,
                                 parentEnvironment: fake.parent)
        #expect(await missing.status() == .unavailable("Codex CLI not found"))
    }

    @Test func theUsersCodexHomeIsRefused() async throws {
        let fake = try Fake(login: .signIn)
        defer { fake.box.remove() }
        let users = CodexLogin(executable: fake.script, codexHome: fake.root.appending(path: ".codex", directoryHint: .isDirectory),
                               parentEnvironment: fake.parent)
        #expect(await users.status() == .unavailable("codex home: the user's own ~/.codex"))
        #expect(await users.signIn() == .failed("codex home: the user's own ~/.codex"))
        #expect(fake.argv(0) == nil)
    }

    @Test func aSignInThatWorksIsCheckedWithStatus() async throws {
        let fake = try Fake(login: .signIn)
        defer { fake.box.remove() }
        #expect(await fake.login().signIn() == .signedIn)
        #expect(fake.argv(0) == CodexLogin.signInArguments)
        #expect(fake.argv(1) == CodexLogin.statusArguments)
        #expect(fake.env(0)["CODEX_HOME"] == fake.codexHome.path(percentEncoded: false))
    }

    @Test func aFailedSignIn() async throws {
        let fake = try Fake(login: .fail)
        defer { fake.box.remove() }
        #expect(await fake.login().signIn() == .failed("codex login exited 1"))
    }

    @Test func aSignInStopsOnCancelAndOnItsTimeout() async throws {
        let fake = try Fake(login: .hang)
        defer { fake.box.remove() }
        let login = fake.login()
        let task = Task { await login.signIn() }
        let end = SuspendingClock.now + .seconds(20)
        while fake.argv(0) == nil && SuspendingClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
        task.cancel()
        #expect(await task.value == .cancelled)

        let timed = try Fake(login: .hang)
        defer { timed.box.remove() }
        #expect(await timed.login(timeout: .seconds(1)).signIn()
                == .failed("the browser sign-in did not finish within 1 s"))
    }
}
