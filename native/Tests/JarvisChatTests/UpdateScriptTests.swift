import Foundation
import JarvisChat
import JarvisCore
import Testing

/// Live updates (U1): build-app.sh stages its build, and scripts/jarvis-update promotes it with
/// renames only. The script runs here on fake bundles in a temp folder, never on dist/.
@Suite("U1 staged builds and the update script", .timeLimit(.minutes(2)))
struct UpdateScriptTests {
    static let native = AppShellTests.native
    static let script = native.appending(path: "scripts/jarvis-update")

    /// A throwaway folder standing in for native/dist, removed by `remove()`.
    struct FakeDist {
        let root: URL
        var dist: URL { root.appending(path: "dist", directoryHint: .isDirectory) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "jarvis-tests-update-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "dist"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func url(_ relative: String) -> URL { dist.appending(path: relative) }

        /// A fake JARVIS.app at `relative` whose executable is a shell script, labelled `name`
        /// inside the bundle; `version` also writes the version.json beside it, and `bundleID`
        /// (unless nil) an Info.plist with that CFBundleIdentifier.
        func bundle(_ relative: String, name: String, version: Bool = true,
                    bundleID: String? = AppIdentity.bundleID,
                    executable: String = "#!/bin/sh\nexit 0\n") throws {
            let app = url(relative)
            let fm = FileManager.default
            try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
            let exe = app.appending(path: "Contents/MacOS/JARVIS")
            try Data(executable.utf8).write(to: exe)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path(percentEncoded: false))
            try Data(name.utf8).write(to: app.appending(path: "Contents/Resources/name"))
            if let bundleID {
                let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID],
                                                               format: .xml, options: 0)
                try plist.write(to: app.appending(path: "Contents/Info.plist"))
            }
            if version {
                try Data(#"{"commit": "\#(name)", "dirty": false, "built": "2026-10-01T00:00:00Z"}"#.utf8)
                    .write(to: app.deletingLastPathComponent().appending(path: "version.json"))
            }
        }

        /// The label of the fake bundle at `relative`, nil if there is none.
        func name(_ relative: String) -> String? {
            try? String(contentsOf: url(relative).appending(path: "Contents/Resources/name"), encoding: .utf8)
        }

        func commit(_ relative: String) -> String? {
            guard let data = try? Data(contentsOf: url(relative)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["commit"] as? String
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: url(relative).path(percentEncoded: false))
        }

        func inode(_ relative: String) throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: url(relative).path(percentEncoded: false))
            return try #require(attributes[.systemFileNumber] as? UInt64)
        }

        func entries() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: dist.path(percentEncoded: false)).sorted()
        }
    }

    /// Runs `executable` and waits for it. Output goes to a file, not a pipe, so a detached
    /// grandchild that inherits it cannot keep the test waiting; and the wait is a termination
    /// handler, not `waitUntilExit()` (see InstanceLockTests).
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    in folder: URL) throws -> (status: Int32, output: String) {
        let log = folder.appending(path: "run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        exited.wait()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output)
    }

    @Test("build-app.sh signs into staged/, writes version.json last, and promotes only when the lock is free")
    func buildScriptStages() throws {
        let text = try String(contentsOf: Self.native.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        #expect(text.contains(#"STAGED="$NATIVE/dist/staged""#))
        #expect(!text.contains(#"rm -rf "$APP""#), "the app that may be running is never deleted in place")
        // The bundle's own version.json is sealed by the signature: written before the app is signed.
        let sealed = try #require(text.range(of: #"> "$STAGE/Contents/Resources/version.json""#))
        let signed = try #require(text.range(of: #""$NATIVE/scripts/sign-app.sh" "#))
        #expect(sealed.lowerBound < signed.lowerBound)
        // Staged only after the verified signature (sign-app.sh verifies, and `set -e` stops the
        // build if it fails); the version.json beside it goes last.
        #expect(text.contains("set -euo pipefail"))
        let verified = signed
        let moved = try #require(text.range(of: #"mv "$STAGE" "$STAGED/JARVIS.app""#))
        let marker = try #require(text.range(of: #"mv "$STAGED/.version.json.tmp" "$STAGED/version.json""#))
        #expect(verified.lowerBound < moved.lowerBound && moved.lowerBound < marker.lowerBound)
        let cleared = try #require(text.range(of: #"rm -f "$STAGED/version.json"; rm -rf "$STAGED/JARVIS.app""#))
        #expect(cleared.lowerBound < moved.lowerBound, "an old marker never vouches for a new, unfinished stage")
        // The decision: the lock .jarvis.lock, the state root StatePaths.live() uses.
        let probe = try #require(text.range(of: #"if "$NATIVE/scripts/jarvis-update" lock-free "${JARVIS_HOME:-$REPO}/.jarvis.lock"; then"#))
        let promote = try #require(text.range(of: #""$NATIVE/scripts/jarvis-update" promote "$NATIVE/dist""#))
        #expect(marker.lowerBound < probe.lowerBound && probe.lowerBound < promote.lowerBound)
        #expect(text.contains("Built and staged: $STAGED/JARVIS.app$LABEL"))
    }

    @Test("build-app.sh puts the update helper in Contents/Helpers and signs it before the app")
    func buildScriptEmbedsHelper() throws {
        let text = try String(contentsOf: Self.native.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        let copied = try #require(text.range(of: #"cp "$NATIVE/scripts/jarvis-update" "$STAGE/Contents/Helpers/jarvis-update""#))
        let signing = try #require(text.range(of: #""$NATIVE/scripts/sign-app.sh" "#))
        #expect(copied.lowerBound < signing.lowerBound)
        let signer = try String(contentsOf: Self.native.appending(path: "scripts/sign-app.sh"), encoding: .utf8)
        let signed = try #require(signer.range(of: #"sign "$STAGE/Contents/Helpers/jarvis-update""#))
        let verified = try #require(signer.range(of: #"verify "$STAGE/Contents/Helpers/jarvis-update""#))
        let app = try #require(signer.range(of: #"sign --entitlements "$ENTITLEMENTS" "$STAGE""#))
        #expect(signed.lowerBound < verified.lowerBound)
        #expect(verified.lowerBound < app.lowerBound, "nested code is signed before the app")
        #expect(text.contains(#"chmod 755 "$STAGE/Contents/Helpers/jarvis-update""#))
        #expect(UpdateFolders.helperPath == "Contents/Helpers/jarvis-update")
        // The helper never names a home folder; it works from its arguments and $HOME.
        let helper = try String(contentsOf: Self.script, encoding: .utf8)
        #expect(!helper.contains(NSHomeDirectory()))
        // Any home folder, spelt without the literal: a slash, "Users" (as a class), a slash, a name.
        #expect(helper.range(of: #"/[U]sers/[A-Za-z0-9._-]+/"#, options: .regularExpression) == nil)
    }

    @Test("promote: JARVIS.app moves to previous/ and the staged build takes its place, by rename")
    func promoteRenames() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "current")
        try fake.bundle("previous/JARVIS.app", name: "older")
        try fake.bundle("staged/JARVIS.app", name: "new")
        let current = try fake.inode("JARVIS.app"), staged = try fake.inode("staged/JARVIS.app")

        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 0, "\(result.output)")
        #expect(fake.name("JARVIS.app") == "new")
        #expect(fake.commit("version.json") == "new")
        #expect(fake.name("previous/JARVIS.app") == "current")
        #expect(fake.commit("previous/version.json") == "current")
        #expect(!fake.exists("staged/JARVIS.app") && !fake.exists("staged/version.json"))
        // Renames only: the same directories, not copies. The build before last is gone.
        #expect(try fake.inode("JARVIS.app") == staged)
        #expect(try fake.inode("previous/JARVIS.app") == current)
        #expect(try fake.entries() == ["JARVIS.app", "previous", "staged", "version.json"])
    }

    @Test("promote with no current build (the first one) moves the staged build in and makes no previous/")
    func promoteFirstBuild() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("staged/JARVIS.app", name: "first")
        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 0, "\(result.output)")
        #expect(fake.name("JARVIS.app") == "first")
        #expect(fake.commit("version.json") == "first")
        #expect(!fake.exists("previous"))
    }

    @Test("promote refuses a stage without its version.json, and moves nothing")
    func promoteRefusesUnfinishedStage() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "current")
        try fake.bundle("staged/JARVIS.app", name: "half", version: false)
        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 3)
        #expect(result.output.contains("nothing staged"))
        #expect(fake.name("JARVIS.app") == "current")
        #expect(fake.name("staged/JARVIS.app") == "half")
        #expect(!fake.exists("previous"))
    }

    @Test("lock-free: 0 for a missing or free .jarvis.lock, 1 while a JARVIS holds it")
    func lockFree() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        let lockFile = fake.root.appending(path: ".jarvis.lock")
        let path = lockFile.path(percentEncoded: false)
        #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 0)
        #expect(!FileManager.default.fileExists(atPath: path), "the probe never creates the lock file")
        do {
            guard case .acquired(let held) = InstanceLock.tryAcquire(at: lockFile, repoRoot: fake.root) else {
                Issue.record("could not take the test lock")
                return
            }
            #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 1)
            withExtendedLifetime(held) {}
        }
        // Released when the InstanceLock is dropped; the file is still there.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 0)
    }

    @Test("jarvis-update without a known command is a usage error")
    func usage() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        #expect(try Self.run(Self.script, [], in: fake.root).status == 64)
        #expect(try Self.run(Self.script, ["promote"], in: fake.root).status == 64)
        #expect(try Self.run(Self.script, ["unknown", "x"], in: fake.root).status == 64)
    }

    @Test("rollback: the failed build moves to failed/ and previous/ is current again, by rename")
    func rollbackRenames() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "broken")
        try fake.bundle("previous/JARVIS.app", name: "good")
        try fake.bundle("failed/JARVIS.app", name: "older failure")
        let good = try fake.inode("previous/JARVIS.app"), broken = try fake.inode("JARVIS.app")
        let result = try Self.run(Self.script, ["rollback", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 0, "\(result.output)")
        #expect(fake.name("JARVIS.app") == "good" && fake.commit("version.json") == "good")
        #expect(fake.name("failed/JARVIS.app") == "broken" && fake.commit("failed/version.json") == "broken")
        #expect(try fake.inode("JARVIS.app") == good && fake.inode("failed/JARVIS.app") == broken)
        #expect(try fake.entries() == ["JARVIS.app", "failed", "version.json"])
        // With no previous build there is nothing to roll back to.
        #expect(try Self.run(Self.script, ["rollback", fake.dist.path(percentEncoded: false)], in: fake.root).status == 3)
    }

    // MARK: - The swap (part 4), on fake bundles

    /// A fake JARVIS: records its launch (its pid, the --resume path and what the file held,
    /// whether the old pid was still alive), then behaves as `Contents/Resources/behavior` says.
    /// healthy: takes the lock as InstanceLock does, deletes resume.json as the real build does,
    /// writes update-health.json and exits 3 s later. crash: exits at once. die: takes the
    /// lock and exits after 1 s. hang: takes the lock and never reports.
    static let fakeExecutable = #"""
    #!/bin/bash
    app="$(cd "$(dirname "$0")/../.." && pwd)"
    name="$(cat "$app/Contents/Resources/name")"
    behavior="$(cat "$app/Contents/Resources/behavior" 2>/dev/null || echo healthy)"
    resume=""
    if [[ "${1:-}" == "--resume" ]]; then resume="${2:-}"; fi
    found=none
    if [[ -n "$resume" && -f "$resume" ]]; then found="$(cat "$resume")"; fi
    old=gone
    if [[ -n "${FAKE_OLD_PID:-}" ]] && kill -0 "$FAKE_OLD_PID" 2>/dev/null; then old=running; fi
    echo "launched $name pid=$$ found=$found old=$old home=${JARVIS_HOME:-none} hooks=${JARVIS_UPDATE_POLL:-none} resume=$resume" >> "$FAKE_RECORD"
    if [[ "$behavior" == crash ]]; then exit 1; fi
    exec /usr/bin/perl -MFcntl=:flock -e '
        my ($lock, $resume, $behavior) = @ARGV;
        open(my $fh, ">>", $lock) or die; flock($fh, LOCK_EX) or die;
        open(my $w, ">", $lock) or die; print $w "native $$ " . time() . "\n"; close $w;
        unlink $resume if $resume ne "";
        if ($behavior eq "healthy") {
            select(undef, undef, undef, 0.5);
            (my $dir = $resume) =~ s{/[^/]*$}{};
            open(my $h, ">", "$dir/update-health.json") or die; print $h "{}\n"; close $h;
            sleep 3; exit 0;
        }
        if ($behavior eq "die") { sleep 1; exit 1; }
        sleep 60;
    ' "$FAKE_LOCK" "$resume" "$behavior"
    """#

    /// Stands in for /usr/bin/open (`-n -g [--env K=V]... <app> --args <args>`) and opens a fake
    /// bundle as LaunchServices would: detached, in the background, and with a fresh environment
    /// that has only what --env passes (and what the fake needs to report).
    static let fakeOpener = #"""
    #!/bin/bash
    envs=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -n|-g) shift ;;
            --env) envs+=("$2"); shift 2 ;;
            --args) shift; break ;;
            *) app="$1"; shift ;;
        esac
    done
    nohup /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin FAKE_RECORD="$FAKE_RECORD" FAKE_LOCK="$FAKE_LOCK"         FAKE_OLD_PID="${FAKE_OLD_PID:-}" ${envs[@]+"${envs[@]}"} "$app/Contents/MacOS/JARVIS" "$@" > /dev/null 2>&1 &
    """#

    /// A fake dist for the swap: the current build, the staged one, a run folder with a
    /// resume.json, the lock file's place, and the opener.
    struct SwapRig {
        let fake: FakeDist
        var run: URL { fake.root.appending(path: "run", directoryHint: .isDirectory) }
        var resume: URL { run.appending(path: "resume.json") }
        var lock: URL { fake.root.appending(path: ".jarvis.lock") }
        var record: URL { fake.root.appending(path: "record.txt") }
        var log: URL { fake.root.appending(path: "jarvis.log") }
        var opener: URL { fake.root.appending(path: "open-fake") }

        init(current: String, staged: String?) throws {
            fake = try FakeDist()
            try app("JARVIS.app", name: "old", behavior: current)
            if let staged { try app("staged/JARVIS.app", name: "new", behavior: staged) }
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            try Data("R1".utf8).write(to: resume)
            try Data(UpdateScriptTests.fakeOpener.utf8).write(to: opener)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path(percentEncoded: false))
        }

        func app(_ relative: String, name: String, behavior: String) throws {
            try fake.bundle(relative, name: name, executable: UpdateScriptTests.fakeExecutable)
            try Data(behavior.utf8).write(to: fake.url(relative).appending(path: "Contents/Resources/behavior"))
        }

        /// The launches the fake apps recorded, in order.
        var launches: [String] {
            ((try? String(contentsOf: record, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        var logText: String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }

        /// Runs `swap` for the old process `oldPID`, with short waits. `environment` is added to
        /// the helper's, as the old process's own environment would be.
        func swap(oldPID: Int32, environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
            try UpdateScriptTests.run(UpdateScriptTests.script, [
                "swap", "--pid", "\(oldPID)", "--dist", fake.dist.path(percentEncoded: false),
                "--resume", resume.path(percentEncoded: false), "--lock", lock.path(percentEncoded: false),
                "--log", log.path(percentEncoded: false),
            ], environment: [
                "JARVIS_UPDATE_OPEN": opener.path(percentEncoded: false),
                "JARVIS_UPDATE_HEALTH_TIMEOUT": "6", "JARVIS_UPDATE_LOCK_GRACE": "3",
                "JARVIS_UPDATE_EXIT_TIMEOUT": "3", "JARVIS_UPDATE_POLL": "0.2",
                "FAKE_RECORD": record.path(percentEncoded: false), "FAKE_LOCK": lock.path(percentEncoded: false),
                "FAKE_OLD_PID": "\(oldPID)",
            ].merging(environment) { $1 }, in: fake.root)
        }

        /// Stops every fake app still running, then removes the folder.
        func remove() {
            for line in launches {
                if let field = line.split(separator: " ").first(where: { $0.hasPrefix("pid=") }),
                   let pid = Int32(field.dropFirst(4)) { kill(pid, SIGKILL) }
            }
            fake.remove()
        }

        func pid(ofLaunch index: Int) -> Int32? {
            guard index < launches.count,
                  let field = launches[index].split(separator: " ").first(where: { $0.hasPrefix("pid=") }) else { return nil }
            return Int32(field.dropFirst(4))
        }
    }

    /// A process standing in for the old JARVIS: alive for `seconds`, then gone (reaped by
    /// Foundation's own watch on it).
    static func oldProcess(seconds: Int) throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["\(seconds)"]
        try process.run()
        return process
    }

    /// The pid of an old JARVIS that has already exited and been reaped.
    static func exitedPID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        exited.wait()
        return process.processIdentifier
    }

    @Test("a healthy new build: promoted after the old pid exits, opened with --resume, and kept")
    func swapHealthy() throws {
        let rig = try SwapRig(current: "healthy", staged: "healthy")
        defer { rig.remove() }
        let old = try Self.oldProcess(seconds: 1)
        let result = try rig.swap(oldPID: old.processIdentifier)
        #expect(result.status == 0, "\(result.output)")
        #expect(rig.launches.count == 1)
        let launch = try #require(rig.launches.first)
        #expect(launch.hasPrefix("launched new ") && launch.contains("found=R1") && launch.contains("old=gone"))
        #expect(launch.hasSuffix("resume=\(rig.resume.path(percentEncoded: false))"))
        #expect(rig.fake.name("JARVIS.app") == "new" && rig.fake.name("previous/JARVIS.app") == "old")
        #expect(!rig.fake.exists("failed"))
        // Nothing of the hand-over is left: the build deleted resume.json, the helper its copy
        // and the health report.
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.run.path(percentEncoded: false)).isEmpty)
        let log = rig.logText
        #expect(log.contains("[JARVIS] update: helper started: from old 2026-10-01T00:00:00Z to new 2026-10-01T00:00:00Z"))
        #expect(log.contains("[JARVIS] update: promoted new 2026-10-01T00:00:00Z; opening it"))
        #expect(log.contains("[JARVIS] update: new 2026-10-01T00:00:00Z is healthy; the update is done"))
    }

    @Test("JARVIS's own settings reach the new build through open --env; the helper's test hooks do not")
    func swapPassesTheEnvironment() throws {
        let rig = try SwapRig(current: "healthy", staged: "healthy")
        defer { rig.remove() }
        let home = rig.fake.root.appending(path: "state root").path(percentEncoded: false)
        let result = try rig.swap(oldPID: try Self.exitedPID(), environment: ["JARVIS_HOME": home])
        #expect(result.status == 0, "\(result.output)")
        let launch = try #require(rig.launches.first)
        #expect(launch.contains("home=\(home) "), "\(launch)")
        #expect(launch.contains(" hooks=none "), "JARVIS_UPDATE_POLL stays with the helper: \(launch)")
    }

    @Test("a build that crashes at once is rolled back, and the previous one gets the same --resume")
    func swapCrashRollsBack() throws {
        let rig = try SwapRig(current: "healthy", staged: "crash")
        defer { rig.remove() }
        let result = try rig.swap(oldPID: try Self.exitedPID())
        #expect(result.status == 2, "\(result.output)")
        #expect(rig.launches.count == 2)
        #expect(rig.launches.first?.hasPrefix("launched new ") == true)
        // The previous build was opened with the same --resume, and found the hand-over in it.
        let again = try #require(rig.launches.last)
        #expect(again.hasPrefix("launched old ") && again.contains("found=R1"))
        #expect(again.hasSuffix("resume=\(rig.resume.path(percentEncoded: false))"))
        #expect(rig.fake.name("JARVIS.app") == "old" && rig.fake.name("failed/JARVIS.app") == "new")
        #expect(!rig.fake.exists("previous"))
        let log = rig.logText
        #expect(log.contains("the new build did not take the lock within 3 s"))
        #expect(log.contains("rolled back from new 2026-10-01T00:00:00Z to old 2026-10-01T00:00:00Z"))
        #expect(log.contains("old 2026-10-01T00:00:00Z is running again after the rollback"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.run.path(percentEncoded: false)).isEmpty)
    }

    @Test("a build that dies after taking the lock is rolled back as soon as its process is gone")
    func swapDieRollsBack() throws {
        let rig = try SwapRig(current: "healthy", staged: "die")
        defer { rig.remove() }
        let result = try rig.swap(oldPID: try Self.exitedPID())
        #expect(result.status == 2, "\(result.output)")
        #expect(rig.logText.contains("exited before it was healthy"))
        #expect(rig.fake.name("JARVIS.app") == "old" && rig.fake.name("failed/JARVIS.app") == "new")
        #expect(rig.launches.last?.hasPrefix("launched old ") == true)
    }

    @Test("a build that runs but never reports healthy is stopped, then rolled back")
    func swapHangIsStopped() throws {
        let rig = try SwapRig(current: "healthy", staged: "hang")
        defer { rig.remove() }
        let result = try rig.swap(oldPID: try Self.exitedPID())
        #expect(result.status == 2, "\(result.output)")
        let hung = try #require(rig.pid(ofLaunch: 0))
        #expect(kill(hung, 0) != 0, "the hung build was stopped")
        let log = rig.logText
        #expect(log.contains("no update-health.json within 6 s"))
        #expect(log.contains("stopping the unhealthy process \(hung)"))
        #expect(rig.fake.name("JARVIS.app") == "old" && rig.fake.name("failed/JARVIS.app") == "new")
        #expect(rig.launches.last?.hasPrefix("launched old ") == true)
    }

    @Test("while another JARVIS holds the lock, nothing is promoted and nothing is opened")
    func swapLockHeld() throws {
        let rig = try SwapRig(current: "healthy", staged: "healthy")
        defer { rig.remove() }
        guard case .acquired(let held) = InstanceLock.tryAcquire(at: rig.lock, repoRoot: rig.fake.root) else {
            Issue.record("could not take the test lock")
            return
        }
        let result = try rig.swap(oldPID: try Self.exitedPID())
        withExtendedLifetime(held) {}
        #expect(result.status == 1, "\(result.output)")
        #expect(rig.logText.contains("another JARVIS holds .jarvis.lock; the update is abandoned and the build stays staged"))
        #expect(rig.launches.isEmpty)
        #expect(rig.fake.name("JARVIS.app") == "old" && rig.fake.name("staged/JARVIS.app") == "new")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.run.path(percentEncoded: false)).isEmpty,
                "the chat in resume.json is not left behind")
    }

    @Test("an old pid that never exits, and is not a JARVIS, is left alone and nothing is promoted")
    func swapOldNeverExits() throws {
        let rig = try SwapRig(current: "healthy", staged: "healthy")
        defer { rig.remove() }
        let old = try Self.oldProcess(seconds: 30)
        defer { old.terminate() }
        let result = try rig.swap(oldPID: old.processIdentifier)
        #expect(result.status == 1, "\(result.output)")
        #expect(old.isRunning, "a process that is not JARVIS is never stopped")
        #expect(rig.logText.contains("pid \(old.processIdentifier) is still running; the update is abandoned"))
        #expect(rig.launches.isEmpty)
        #expect(rig.fake.name("JARVIS.app") == "old" && rig.fake.name("staged/JARVIS.app") == "new")
    }

    @Test("with nothing staged the current build is opened again with the hand-over")
    func swapNothingStaged() throws {
        let rig = try SwapRig(current: "healthy", staged: nil)
        defer { rig.remove() }
        let result = try rig.swap(oldPID: try Self.exitedPID())
        #expect(result.status == 1, "\(result.output)")
        #expect(rig.logText.contains("nothing staged to promote; reopening old"))
        #expect(eventuallySync { rig.launches.first?.hasPrefix("launched old ") == true })
        #expect(rig.launches.first?.contains("found=R1") == true)
    }

    @Test("swap without its arguments is a usage error")
    func swapUsage() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        #expect(try Self.run(Self.script, ["swap"], in: fake.root).status == 64)
        #expect(try Self.run(Self.script, ["swap", "--pid", "x", "--dist", "d", "--resume", "r", "--lock", "l"],
                             in: fake.root).status == 64)
    }
}

/// Polls `condition` every 10 ms for up to 5 s, synchronously.
func eventuallySync(_ condition: () -> Bool) -> Bool {
    for _ in 0..<500 {
        if condition() { return true }
        usleep(10_000)
    }
    return condition()
}
