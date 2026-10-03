import Foundation
import Testing

/// M15 (plan M00 §3.11): scripts/switch-impl.sh swaps the LaunchAgent between the Python and the
/// native app. It runs here only in a temp HOME, with stand-ins for launchctl and lsregister that
/// record their arguments; the real LaunchAgent and launchctl are never touched.
@Suite("M15 switch-impl.sh", .timeLimit(.minutes(2)))
struct SwitchImplScriptTests {
    static let script = AppShellTests.native.appending(path: "scripts/switch-impl.sh")

    /// A throwaway HOME with a Python-style LaunchAgent, a fake native build and the stand-ins.
    struct FakeHome {
        let root: URL
        var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
        var repo: URL { home.appending(path: "jarvis", directoryHint: .isDirectory) }
        var plist: URL { home.appending(path: "Library/LaunchAgents/com.jarvis.assistant.plist") }
        var backup: URL { repo.appending(path: "native/dist/com.jarvis.assistant.python.plist") }
        /// The paths as the script spells them: from HOME, with no trailing slash.
        var homePath: String { String(home.path(percentEncoded: false).dropLast()) }
        var repoPath: String { homePath + "/jarvis" }
        var nativeExe: String { repoPath + "/native/dist/JARVIS.app/Contents/MacOS/JARVIS" }
        var pythonExe: String { repoPath + "/dist/JARVIS.app/Contents/MacOS/JARVIS" }
        var calls: URL { root.appending(path: "calls") }
        var lock: URL { repo.appending(path: ".jarvis.lock") }

        init(nativeBuild: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "jarvis-tests-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
            let fm = FileManager.default
            for dir in ["home/Library/LaunchAgents", "home/jarvis/native/dist/JARVIS.app/Contents/MacOS",
                        "home/jarvis/dist/JARVIS.app/Contents/MacOS", "home/jarvis/logs"] {
                try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
            if nativeBuild { try Self.executable(URL(filePath: nativeExe), "#!/bin/sh\nexit 0\n") }
            let callsPath = calls.path(percentEncoded: false)
            try Self.executable(root.appending(path: "launchctl"), """
                #!/bin/sh
                echo "launchctl $*" >> "\(callsPath)"
                if [ "$1" = print ]; then
                  printf '\\tstate = running\\n\\tprogram = %s\\n\\tpid = 4242\\n' "$(cat "\(root.path(percentEncoded: false))/program" 2>/dev/null)"
                fi
                exit 0

                """)
            try Self.executable(root.appending(path: "lsregister"), "#!/bin/sh\necho \"lsregister $*\" >> \"\(callsPath)\"\n")
            let python = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                  <key>Label</key><string>com.jarvis.assistant</string>
                  <key>ProgramArguments</key><array><string>\(pythonExe)</string></array>
                  <key>EnvironmentVariables</key><dict>
                    <key>JARVIS_STT</key><string>whisper</string>
                    <key>JARVIS_WHISPER</key><string>small.en</string>
                    <key>LANG</key><string>en_US.UTF-8</string>
                    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
                    <key>PYTHONUNBUFFERED</key><string>1</string>
                  </dict>
                  <key>RunAtLoad</key><true/>
                  <key>KeepAlive</key><true/>
                  <key>ThrottleInterval</key><integer>10</integer>
                  <key>StandardOutPath</key><string>\(repo.path(percentEncoded: false))logs/jarvis.boot.log</string>
                </dict>
                </plist>

                """
            try Data(python.utf8).write(to: plist)
        }

        static func executable(_ url: URL, _ text: String) throws {
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        var environment: [String: String] {
            ["HOME": homePath,
             "SWITCH_IMPL_LAUNCHCTL": root.appending(path: "launchctl").path(percentEncoded: false),
             "SWITCH_IMPL_LSREGISTER": root.appending(path: "lsregister").path(percentEncoded: false),
             "SWITCH_IMPL_LOCK_WAIT": "1"]
        }

        func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
            try SwitchImplScriptTests.run(arguments, environment: environment, in: root)
        }

        var recorded: [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func dictionary(_ url: URL) throws -> [String: Any] {
            let data = try Data(contentsOf: url)
            return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        }
    }

    /// Runs the script with `environment` laid over a copy of this process's, in which the two
    /// JARVIS path variables are removed so the temp HOME decides every path.
    static func run(_ arguments: [String], environment: [String: String], in folder: URL,
                    script: URL = SwitchImplScriptTests.script) throws -> (status: Int32, output: String) {
        let log = folder.appending(path: "run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = script
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["JARVIS_REPO"] = nil
        env["JARVIS_HOME"] = nil
        process.environment = env.merging(environment) { $1 }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        exited.wait()
        return (process.terminationStatus, (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    @Test func aDryRunPrintsTheDiffAndCommandsAndChangesNothing() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let before = try Data(contentsOf: fake.plist)
        let (status, output) = try fake.run(["native", "--dry-run"])
        #expect(status == 0, "\(output)")
        #expect(try Data(contentsOf: fake.plist) == before)
        #expect(!FileManager.default.fileExists(atPath: fake.backup.path(percentEncoded: false)))
        #expect(fake.recorded.isEmpty, "no launchctl or lsregister under --dry-run")
        #expect(output.contains("--- plist diff"))
        #expect(output.contains("+\t\t<string>\(fake.nativeExe)</string>"))
        #expect(output.contains("-    <key>PYTHONUNBUFFERED</key><string>1</string>"))
        #expect(output.contains("bootout") && output.contains("bootstrap") && output.contains("lsregister"))
        #expect(output.contains("dry run: nothing was changed"))
    }

    @Test func nativeKeepsThePythonKeysAndPythonRestoresItByteForByte() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let python = try Data(contentsOf: fake.plist)
        let (status, output) = try fake.run(["native"])
        #expect(status == 0, "\(output)")
        #expect(try Data(contentsOf: fake.backup) == python)
        let native = try fake.dictionary(fake.plist)
        #expect(native["ProgramArguments"] as? [String] == [fake.nativeExe])
        #expect(native["Label"] as? String == "com.jarvis.assistant")
        #expect(native["RunAtLoad"] as? Bool == true && native["KeepAlive"] as? Bool == true)
        #expect(native["ThrottleInterval"] as? Int == 10)
        #expect((native["StandardOutPath"] as? String)?.hasSuffix("logs/jarvis.boot.log") == true)
        let env = try #require(native["EnvironmentVariables"] as? [String: String])
        #expect(env["JARVIS_STT"] == "whisper" && env["JARVIS_WHISPER"] == "small.en" && env["LANG"] == "en_US.UTF-8")
        #expect(env["PYTHONUNBUFFERED"] == nil)
        #expect(env["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(env["JARVIS_HOME"] == fake.repoPath)
        let uid = getuid()
        #expect(Array(fake.recorded.prefix(3)) == [
            "launchctl bootout gui/\(uid)/com.jarvis.assistant",
            "lsregister -f \(fake.repoPath)/native/dist/JARVIS.app",
            "launchctl bootstrap gui/\(uid) \(fake.homePath)/Library/LaunchAgents/com.jarvis.assistant.plist",
        ])

        // Switching to native again rebuilds from the backup and never backs up a native plist.
        #expect(try fake.run(["native"]).status == 0)
        #expect(try Data(contentsOf: fake.backup) == python)

        let back = try fake.run(["python"])
        #expect(back.status == 0, "\(back.output)")
        #expect(try Data(contentsOf: fake.plist) == python)
        #expect(fake.recorded.contains("lsregister -f \(fake.repoPath)/dist/JARVIS.app"))
    }

    @Test func aLockStillHeldLeavesThePlistAsItWas() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let before = try Data(contentsOf: fake.plist)
        FileManager.default.createFile(atPath: fake.lock.path(percentEncoded: false), contents: nil)
        // A stand-in JARVIS: holds the lock until it is killed.
        let holder = Process()
        holder.executableURL = URL(filePath: "/usr/bin/perl")
        holder.arguments = ["-MFcntl=:flock", "-e",
                            #"open(my $f, "<", $ARGV[0]) or die; flock($f, LOCK_EX) or die; print "held\n"; $|=1; sleep 60"#,
                            fake.lock.path(percentEncoded: false)]
        let pipe = Pipe()
        holder.standardOutput = pipe
        try holder.run()
        defer { holder.terminate() }
        _ = pipe.fileHandleForReading.availableData      // "held": the lock is taken
        let (status, output) = try fake.run(["native"])
        #expect(status == 1, "\(output)")
        #expect(output.contains("still holds"))
        #expect(try Data(contentsOf: fake.plist) == before)
        #expect(fake.recorded.first?.hasPrefix("launchctl bootout") == true)
        #expect(fake.recorded.last?.hasPrefix("launchctl bootstrap") == true, "the old agent is loaded again")
    }

    @Test func withoutANativeBuildOrABackupNothingIsSwitched() throws {
        let fake = try FakeHome(nativeBuild: false)
        defer { fake.remove() }
        let before = try Data(contentsOf: fake.plist)
        let native = try fake.run(["native"])
        #expect(native.status == 1 && native.output.contains("no native build"))
        let python = try fake.run(["python"])
        #expect(python.status == 1 && python.output.contains("nothing to restore"))
        #expect(try Data(contentsOf: fake.plist) == before)
        #expect(fake.recorded.isEmpty)
    }

    @Test func statusSaysWhatRunsAndWhoHoldsTheLock() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        try Data(fake.pythonExe.utf8).write(to: fake.root.appending(path: "program"))
        try Data("python 1234\n".utf8).write(to: fake.lock)
        try Data("first\nJARVIS ready\n".utf8).write(to: fake.repo.appending(path: "logs/jarvis.log"))
        let (status, output) = try fake.run(["status"])
        #expect(status == 0, "\(output)")
        #expect(output.contains("plist: python"))
        #expect(output.contains("loaded: yes"))
        #expect(output.contains("launchd program = \(fake.pythonExe)"))
        #expect(output.contains("launchd pid = 4242"))
        #expect(output.contains("launchd state = running"))
        #expect(output.contains("lock: python 1234"))
        #expect(output.contains("last log line: JARVIS ready"))
    }

    @Test func theScriptNamesNoHomeFolder() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        #expect(!text.contains(NSHomeDirectory()))
        // Any home folder, spelt without the literal: a slash, "Users" (as a class), a slash, a name.
        #expect(text.range(of: #"/[U]sers/[A-Za-z0-9._-]+/"#, options: .regularExpression) == nil)
        #expect(text.contains(#"REPO="${JARVIS_REPO:-$HOME/jarvis}""#))
    }
}
