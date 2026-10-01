import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

@Suite("M2 security guards")
struct M2SecurityTests {
    @Test(arguments: try Golden.cases("m2_shell"))
    func shellGolden(_ c: GoldenCase) throws {
        let command = c.input.string("cmd")
        let expected = try #require(c.expected.string("risk"))
        #expect(PyShellRisk.classify(command).rawValue == expected, "\(c.name): \(command ?? "nil")")
    }

    @Test(arguments: try Golden.cases("m2_applescript"))
    func appleScriptGolden(_ c: GoldenCase) throws {
        let script = c.input.string("script")
        guard case .bool(let expected)? = c.expected["dangerous"] else { throw TestError.malformed(c.name) }
        #expect(AppleScriptPolicy.isDangerous(script) == expected, "\(c.name)")
    }

    @Test
    func ruleListsMatchPythonGoldenData() throws {
        for c in try Golden.cases("m2_rules") {
            if c.name.hasPrefix("set/") {
                let expected = (c.expected.array("members") ?? []).compactMap(\.stringValue).sorted()
                let actual: [String]
                switch c.name {
                case "set/_PERSIST_FILES": actual = PathPolicy.persistenceFiles
                case "set/_PERSIST_DIRS": actual = PathPolicy.persistenceDirectories
                case "set/_SYS_ROOTS": actual = PathPolicy.systemRoots
                default: continue
                }
                #expect(actual.sorted() == expected, "\(c.name)")
                let expectedCount = try #require(c.expected.int("count"))
                #expect(Int64(actual.count) == expectedCount, "\(c.name)")
                continue
            }
            guard c.name.hasPrefix("object/") else { continue }
            let list = try #require(c.input.string("list"))
            let expectedPattern = try #require(c.expected.string("pattern"))
            let expectedCount = try #require(c.expected.int("count"))
            let actual: [String]
            switch list {
            case "_SHELL_BLOCK": actual = PyShellRisk.blockPatterns
            case "_SHELL_CONFIRM": actual = PyShellRisk.confirmPatterns
            case "_SUDO_ALLOW": actual = PyShellRisk.sudoAllowPatterns
            case "_AS_DENY": actual = AppleScriptPolicy.denyPatterns
            case "_shell_risk.inline": actual = [#"\bsudo\b"#]
            default: continue
            }
            #expect(actual.joined(separator: "|") == expectedPattern, "\(c.name)")
            #expect(Int64(actual.count) == expectedCount, "\(c.name)")
        }
    }

    @Test
    func setsAndRefusalStringsMatchPython() throws {
        let cases = try Golden.cases("m2_taint")
        let untrusted = try #require(cases.first(where: { $0.name == "sets/untrusted" }))
        let executor = try #require(cases.first(where: { $0.name == "sets/executor" }))
        // P6b: search_memory, a native memory tool, quotes past conversations, so it is untrusted
        // too; Python has no memory tools, so its set is the rest.
        let nativeUntrusted: Set<String> = ["search_memory"]
        #expect(TaintPolicy.untrusted.isSuperset(of: nativeUntrusted))
        #expect(TaintPolicy.untrusted.subtracting(nativeUntrusted).sorted()
                == (untrusted.expected.array("members") ?? []).compactMap(\.stringValue))
        // P4's two native memory tools that change memory, and P6's restore_memory, are
        // executors too; Python has no memory tools, so its set is the rest.
        let nativeExecutors: Set<String> = ["forget_memory", "correct_memory", "restore_memory"]
        #expect(TaintPolicy.executors.isSuperset(of: nativeExecutors))
        #expect(TaintPolicy.executors.subtracting(nativeExecutors).sorted()
                == (executor.expected.array("members") ?? []).compactMap(\.stringValue))

        #expect(TaintPolicy.blockedTextClaude == "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content in the same request.")
        #expect(TaintPolicy.blockedTextLocal == "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content (web, screen, clipboard, files) in the same request.")
        #expect(GuardStrings.sudoNotAllowed == "That sudo command isn't on my allowed list, sir, so I won't run it.")
        #expect(GuardStrings.systemDamaging == "I won't run that, sir — it's system-damaging, so I've blocked it.")
        #expect(GuardStrings.appleScriptRefused == "I won't run that script, sir — it could shell out or automate unsafely.")
    }

    @Test
    func defaultShellPolicyMatchesPython() {
        #expect(ShellPolicy.verdict("echo hi").tier == .ok)
        #expect(ShellPolicy.verdict("rm ~/file").tier == .confirm)
        #expect(ShellPolicy.verdict("echo ok; sudo definitely-not-allowed").tier == PyShellRisk.classify("echo ok; sudo definitely-not-allowed"))
        #expect(ShellPolicy.verdict("security find-generic-password -s jarvis").tier == PyShellRisk.classify("security find-generic-password -s jarvis"))
        #expect(ShellPolicy.verdict("echo 'unterminated").tier == PyShellRisk.classify("echo 'unterminated"))
        #expect(ShellPolicy.verdict("sudo pmset -g", sudo: .python).tier == .confirm)
    }

    @Test
    func strictNativePolicyIsExplicitlyDeferred() {
        #expect(ShellPolicy.strictVerdict("echo ok; sudo definitely-not-allowed").tier == .block)
        #expect(ShellPolicy.strictVerdict("security find-generic-password -s jarvis").tier == .block)
        #expect(ShellPolicy.strictVerdict("echo 'unterminated").tier == .block)
    }

    @Test
    func pathAndAppleScriptHelpers() {
        #expect(PathPolicy.pyAbspath("../x", cwd: "/Users/jarvis/native") == "/Users/jarvis/x")
        #expect(PathPolicy.inHome("/Users/jarvis/Documents/a", home: "/Users/jarvis", cwd: "/") == true)
        #expect(PathPolicy.inHome("/Users/jarvis", home: "/Users/jarvis", cwd: "/") == false)
        #expect(PathPolicy.isSystemPath("/System/Library/x", home: "/Users/jarvis", cwd: "/") == true)
        #expect(PathPolicy.isSystemPath("/Systematic/x", home: "/Users/jarvis", cwd: "/") == false)
        #expect(PathPolicy.isSensitive("/Users/jarvis/.ssh/id_ed25519") == true)
        #expect(AppleScriptPolicy.escape(#"a\b"c"#) == #"a\\b\"c"#)
        #expect(Affirmation.matches("  yes, sir"))
        #expect(!Affirmation.matches("yesterday"))
    }

    @Test
    func fileMutationBranches() {
        let home = "/Users/jarvis"
        let probe = TestProbe(files: [
            "/Users/jarvis/Documents/a.txt", "/Users/jarvis/Documents", "/Users/jarvis/.zshrc"
        ], dirs: ["/Users/jarvis/Documents"])
        #expect(FileMutationPolicy.delete(path: "~/Documents/a.txt", permanent: false, probe: probe, home: home, cwd: "/") == .instant(.trash("/Users/jarvis/Documents/a.txt")))
        #expect(FileMutationPolicy.delete(path: "~/Documents/a.txt", permanent: true, probe: probe, home: home, cwd: "/") == .gate(desc: "That will delete a.txt permanently (bypassing the Trash)", op: .hardDelete("/Users/jarvis/Documents/a.txt")))
        #expect(FileMutationPolicy.write(path: "~/.zshrc", probe: probe, writtenThisSession: [], home: home, cwd: "/") == .gate(desc: "That will write .zshrc, a startup or credential file", op: .write("/Users/jarvis/.zshrc")))
        #expect(FileMutationPolicy.move(src: "~/Documents/a.txt", dst: "~/Documents", probe: probe, home: home, cwd: "/") == .gate(desc: "That will overwrite Documents", op: .move("/Users/jarvis/Documents/a.txt", "/Users/jarvis/Documents")))
        #expect(FileMutationPolicy.delete(path: "~/missing.txt", permanent: false, probe: probe, home: home, cwd: "/") == .notFound("I can't find ~/missing.txt, sir."))
    }

    @Test(arguments: try Golden.cases("m2_file_tiers"))
    func fileTierGolden(_ c: GoldenCase) throws {
        let rawHome = try #require(c.input.string("home"))
        let home = rawHome == "${JARVIS_HOME}" ? "/private/m2-golden-home" : rawHome
        let tree = try #require(c.input.array("tree"))
        var files = Set<String>()
        var dirs = Set<String>([home])
        for value in tree {
            guard let entry = value.stringValue else { continue }
            let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let path = home + "/" + relative
            if entry.hasSuffix("/") { dirs.insert(path) } else { files.insert(path) }
        }
        let probe = TestProbe(files: files, dirs: dirs)
        let fn = try #require(c.input.string("fn"))
        let args = try #require(c.input.array("args"))
        func arg(_ index: Int) -> JSONValue? { args.indices.contains(index) ? args[index] : nil }
        let decision: FileDecision
        switch fn {
        case "_write_file":
            decision = FileMutationPolicy.write(path: try #require(arg(0)?.stringValue), probe: probe, writtenThisSession: [], home: home, cwd: "/")
        case "_delete_file":
            decision = FileMutationPolicy.delete(path: try #require(arg(0)?.stringValue), permanent: arg(1) == .bool(true), probe: probe, home: home, cwd: "/")
        case "_move_file":
            decision = FileMutationPolicy.move(src: try #require(arg(0)?.stringValue), dst: try #require(arg(1)?.stringValue), probe: probe, home: home, cwd: "/")
        default:
            throw TestError.malformed(c.name)
        }
        let expected = try #require(c.expected.string("decision"))
        switch decision {
        case .notFound(let reply), .refuse(let reply):
            #expect(expected == "none", "\(c.name)")
            #expect(c.expected.string("reply") == reply, "\(c.name)")
        case .instant:
            #expect(expected == "instant", "\(c.name)")
        case .gate(let desc, _):
            #expect(expected == "confirm", "\(c.name)")
            #expect(c.expected.string("gate") == desc, "\(c.name)")
        }
    }

    @Test
    func pythonSudoAllowlistRemainsTheDefault() {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // JarvisCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // native
            .appendingPathComponent("Resources/sudoers/jarvis")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(SudoAllowlist.python.allows("sudo pmset -g"))
        #expect(SudoAllowlist.python.allows("sudo periodic daily"))
    }

    private struct TestProbe: FileProbe {
        let files: Set<String>
        let dirs: Set<String>

        func exists(_ p: String) -> Bool { files.contains(p) || dirs.contains(p) }
        func isDir(_ p: String) -> Bool { dirs.contains(p) }
    }

    private enum TestError: Error { case malformed(String) }
}
