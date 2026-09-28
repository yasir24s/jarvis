import Foundation
import JarvisCore
import JarvisTestSupport
import Synchronization
import Testing

/// The interpreter Python JARVIS runs under; interop tests are skipped where it is absent.
let frameworkPython = "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3"
let hasFrameworkPython = FileManager.default.isExecutableFile(atPath: frameworkPython)

/// Descriptors of this process whose F_GETPATH is `url` (after realpath) — lets the tests
/// inspect the fds InstanceLock/JarvisLog opened without exposing them in the API.
func openDescriptors(for url: URL) -> [Int32] {
    guard let resolved = realpath(url.path(percentEncoded: false), nil) else { return [] }
    let want = String(cString: resolved)
    free(resolved)
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return (0..<getdtablesize()).filter { fd in
        fcntl(fd, F_GETPATH, &buf) != -1 && buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } == want
    }
}

/// A child Python that mirrors jarvis.acquire_instance_lock() without the wait loop:
/// `hold` locks, rewrites the holder line, prints "locked" and holds until stdin closes;
/// `probe` exits 0 if the lock is free and 11 on BlockingIOError.
private let pythonLockScript = """
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("blocked", flush=True)
    sys.exit(11)
if sys.argv[2] == "probe":
    sys.exit(0)
os.ftruncate(fd, 0)
os.write(fd, f"python {os.getpid()} {int(time.time())}\\n".encode())
print("locked", flush=True)
sys.stdin.read()
"""

private final class Child {
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()

    init(_ executable: String, _ arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    /// Blocks until the child prints a full line (or closes stdout).
    func readLine() -> String {
        var data = Data()
        while !data.contains(0x0A) {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func finish() -> Int32 {
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func kill() {
        if process.isRunning { Darwin.kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}

private func pythonProbe(_ lock: URL) throws -> Int32 {
    let child = try Child(frameworkPython, ["-c", pythonLockScript, lock.path(percentEncoded: false), "probe"])
    return child.finish()
}

private func acquired(_ outcome: InstanceLock.Outcome) -> InstanceLock? {
    if case .acquired(let lock) = outcome { return lock }
    return nil
}

/// Checks that follow a release poll for up to 2 s. Measured (standalone, 6000 re-acquires):
/// while another thread is in posix_spawn, the child's copy of the fd table briefly references
/// even an O_CLOEXEC fd until its exec closes it, so a just-closed flock can stay held for
/// milliseconds — 0 misses without concurrent spawns, 7 with. Parallel tests here spawn
/// constantly. A real leak (a child keeping the fd) lasts far longer than the window.
private func acquiredSoon(_ url: URL, _ root: URL) -> InstanceLock? {
    let deadline = Date().addingTimeInterval(2)
    while true {
        if let lock = acquired(InstanceLock.tryAcquire(at: url, repoRoot: root)) { return lock }
        if Date() >= deadline { return nil }
        usleep(20_000)
    }
}

private func pythonProbeSoon(_ lock: URL) throws -> Int32 {
    let deadline = Date().addingTimeInterval(2)
    while true {
        let rc = try pythonProbe(lock)
        if rc != 11 || Date() >= deadline { return rc }
        usleep(20_000)
    }
}

private final class Calls: Sendable {
    let holders = Mutex<[LockHolder?]>([])
}

@Suite("InstanceLock", .timeLimit(.minutes(1)))
struct InstanceLockTests {
    @Test func twoOpensInOneProcessConflict() throws {
        let s = try Sandbox()
        defer { s.remove() }
        var first = acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root))
        try #require(first != nil)
        guard case .held(let holder) = InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root) else {
            Issue.record("second open in the same process acquired the lock")
            return
        }
        #expect(holder == .native(pid: getpid()))
        withExtendedLifetime(first) {}
        first = nil                                                   // deinit closes the fd
        #expect(acquiredSoon(s.paths.lockFile, s.root) != nil)
    }

    @Test func holderLineIsNativePidEpochAndFileIs0600() throws {
        let s = try Sandbox()
        defer { s.remove() }
        try s.write(".jarvis.lock", "python 1 2\nstale second line that must be truncated\n")
        let before = time(nil)
        let lock = try #require(acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root)))
        let after = time(nil)
        let text = try s.read(".jarvis.lock")
        let parts = text.dropLast().split(separator: " ")
        #expect(text.hasSuffix("\n") && parts.count == 3)
        #expect(parts[0] == "native" && parts[1] == "\(getpid())")
        let epoch = try #require(Int(parts[2]))
        #expect(epoch >= before && epoch <= after)
        #expect(InstanceLock.readHolder(at: lock.url) == .native(pid: getpid()))

        let fresh = try Sandbox()
        defer { fresh.remove() }
        let created = try #require(acquired(InstanceLock.tryAcquire(at: fresh.paths.lockFile, repoRoot: fresh.root)))
        var st = stat()
        try #require(stat(created.url.path(percentEncoded: false), &st) == 0)
        #expect(st.st_mode & 0o7777 == 0o600)
        withExtendedLifetime(lock) {}
    }

    @Test func lockDescriptorIsCloseOnExec() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let lock = try #require(acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root)))
        let fds = openDescriptors(for: lock.url)
        try #require(fds.count == 1)
        #expect(fcntl(fds[0], F_GETFD) & FD_CLOEXEC == FD_CLOEXEC)
        #expect(fcntl(fds[0], F_GETFL) & O_ACCMODE == O_RDWR)
        withExtendedLifetime(lock) {}
    }

    /// posix_spawn without POSIX_SPAWN_CLOEXEC_DEFAULT inherits every fd lacking FD_CLOEXEC,
    /// so a surviving child would keep the lock if O_CLOEXEC were missing.
    @Test func spawnedChildDoesNotInheritTheLock() throws {
        let s = try Sandbox()
        defer { s.remove() }
        var lock = acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root))
        try #require(lock != nil)
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
        defer { argv.forEach { free($0) } }
        try #require(posix_spawn(&pid, "/bin/sleep", nil, nil, argv, environ) == 0)
        defer { kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0) }
        withExtendedLifetime(lock) {}
        lock = nil
        #expect(acquiredSoon(s.paths.lockFile, s.root) != nil,
                "the child (alive for 30 s) still holds the lock: its fd was inherited")
    }

    @Test(arguments: [
        ("python 4242 1727500000\n", LockHolder.python(pid: 4242)),
        ("native 99999 1727500000\n", .native(pid: 99999)),
        ("  native 7 0  \n", .native(pid: 7)),
        ("ruby 12 1727500000\n", .unknown("ruby 12 1727500000")),
        ("python abc 1727500000\n", .unknown("python abc 1727500000")),
        ("python 0 1727500000\n", .unknown("python 0 1727500000")),
        ("python 12 34 extra\n", .unknown("python 12 34 extra")),
        ("python 12\n", .unknown("python 12")),
        ("python  12 34\n", .unknown("python  12 34")),
        ("python 12 3.5\n", .unknown("python 12 3.5")),
    ])
    func readHolderParses(text: String, expected: LockHolder) throws {
        let s = try Sandbox()
        defer { s.remove() }
        try s.write(".jarvis.lock", text)
        #expect(InstanceLock.readHolder(at: s.paths.lockFile) == expected)
    }

    @Test func readHolderIsNilForMissingOrEmptyFile() throws {
        let s = try Sandbox()
        defer { s.remove() }
        #expect(InstanceLock.readHolder(at: s.paths.lockFile) == nil)
        try s.write(".jarvis.lock", "\n")
        #expect(InstanceLock.readHolder(at: s.paths.lockFile) == nil)
    }

    /// flock, not POSIX fcntl locks: closing another fd on the file must not drop the lock.
    @Test func readingTheHolderDoesNotDropTheLock() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let lock = try #require(acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root)))
        #expect(InstanceLock.readHolder(at: lock.url) == .native(pid: getpid()))
        guard case .held = InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root) else {
            Issue.record("lock was lost after readHolder closed its fd")
            return
        }
        withExtendedLifetime(lock) {}
    }

    @Test func unopenableLockFileIsReportedHeldWithReason() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-\(UUID().uuidString)/no-such-dir/.jarvis.lock")
        guard case .held(.unknown(let reason)?) = InstanceLock.tryAcquire(at: missing, repoRoot: missing) else {
            Issue.record("expected .held(by: .unknown(...))")
            return
        }
        #expect(reason.hasPrefix("cannot open ") && reason.contains("errno \(ENOENT)"))
    }

    @Test(.enabled(if: hasFrameworkPython))
    func pythonSeesTheSwiftLockAndGetsItAfterRelease() throws {
        let s = try Sandbox()
        defer { s.remove() }
        var lock = acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root))
        try #require(lock != nil)
        #expect(try pythonProbe(s.paths.lockFile) == 11, "Python flock must raise BlockingIOError")
        withExtendedLifetime(lock) {}
        lock = nil
        #expect(try pythonProbeSoon(s.paths.lockFile) == 0, "Python must acquire once Swift released")
    }

    @Test(.enabled(if: hasFrameworkPython))
    func swiftReportsThePythonHolderThenWaitsForIt() async throws {
        let s = try Sandbox()
        defer { s.remove() }
        let python = try Child(frameworkPython, ["-c", pythonLockScript, s.paths.lockFile.path(percentEncoded: false), "hold"])
        defer { python.kill() }
        try #require(python.readLine() == "locked")

        guard case .held(let holder) = InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root) else {
            Issue.record("Swift acquired a lock Python holds")
            return
        }
        #expect(holder == .python(pid: python.pid))

        let calls = Calls()
        let url = s.paths.lockFile, root = s.root
        let waiter = Task {
            await InstanceLock.acquireWaiting(at: url, repoRoot: root, poll: .milliseconds(50)) { holder in
                calls.holders.withLock { $0.append(holder) }
            }
        }
        while calls.holders.withLock({ $0.isEmpty }) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))                   // several polls while held
        #expect(python.finish() == 0)                                    // Python exits → kernel releases
        let lock = await waiter.value
        #expect(calls.holders.withLock { $0 } == [.python(pid: python.pid)], "onFirstWait runs exactly once")
        #expect(InstanceLock.readHolder(at: lock.url) == .native(pid: getpid()))
    }

    @Test(.enabled(if: hasFrameworkPython))
    func kernelReleasesTheLockWhenTheHolderIsKilled() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let python = try Child(frameworkPython, ["-c", pythonLockScript, s.paths.lockFile.path(percentEncoded: false), "hold"])
        defer { python.kill() }
        try #require(python.readLine() == "locked")
        guard case .held = InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root) else {
            Issue.record("Swift acquired a lock Python holds")
            return
        }
        python.kill()                                                    // SIGKILL: no cleanup runs
        #expect(python.process.terminationReason == .uncaughtSignal)
        #expect(acquired(InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root)) != nil)
    }

    @Test(.enabled(if: hasFrameworkPython))
    func prePatchPythonWithJarvisPyInArgvIsRefusedAndLockLeftFree() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let script = s.paths.jarvisPy.path(percentEncoded: false)
        let python = try Child(frameworkPython, ["-c", "import sys; print('up', flush=True); sys.stdin.read()", script])
        defer { python.kill() }
        try #require(python.readLine() == "up")
        #expect(InstanceLock.foreignJarvisProcesses(repoRoot: s.root) == [python.pid])
        guard case .foreignProcess(let pids) = InstanceLock.tryAcquire(at: s.paths.lockFile, repoRoot: s.root) else {
            Issue.record("expected .foreignProcess")
            return
        }
        #expect(pids == [python.pid])
        #expect(try pythonProbeSoon(s.paths.lockFile) == 0, "refusal must not leave the flock held")
    }

    // The py2app-bundle rule is tested on strings only. Never execute anything under a *.app
    // directory in a test: an unsigned or mismatched bundle executable makes Gatekeeper show
    // "“JARVIS.app” is damaged" on the user's screen. Real process enumeration is covered by
    // the spawned-Python tests above, which run nothing from inside a bundle.
    private static let classifyRoot = "/opt/jarvis-classify-root"         // need not exist

    @Test(arguments: [
        ("<root>/dist/JARVIS.app/Contents/MacOS/JARVIS", true),
        ("<root>/dist//JARVIS.app/Contents//MacOS/JARVIS", true),
        ("<root>//dist/./JARVIS.app/Contents/MacOS/JARVIS", true),
        ("<root>/native/../dist/JARVIS.app/Contents/MacOS/JARVIS", true),
        ("<root>/native/dist/JARVIS.app/../../../dist/JARVIS.app/Contents/MacOS/JARVIS", true),
        ("<root>/../jarvis-classify-root/dist/JARVIS.app/Contents/MacOS/JARVIS", true),
        ("<root>/native/dist/JARVIS.app/Contents/MacOS/JARVIS", false),   // the native app itself
        ("<root>/dist/JARVIS.app.bak/Contents/MacOS/JARVIS", false),
        ("<root>/dist/JARVIS.app/Contents/MacOS/JARVIS.bak", false),
        ("<root>/dist/JARVIS.app/Contents/MacOS/Python", false),
        ("<root>/dist/JARVIS.app/Contents/MacOS", false),
        ("<root>/dist/JARVIS.app/Contents/MacOS/JARVIS/..", false),
        ("<root>/build/JARVIS.app/Contents/MacOS/JARVIS", false),
        ("<root>2/dist/JARVIS.app/Contents/MacOS/JARVIS", false),          // sibling root, shared prefix
        ("/opt/other-jarvis/dist/JARVIS.app/Contents/MacOS/JARVIS", false),
        ("dist/JARVIS.app/Contents/MacOS/JARVIS", false),                  // relative: never
        ("", false),
    ])
    func pythonBundleExecutableClassification(path: String, expected: Bool) {
        let resolved = path.replacingOccurrences(of: "<root>", with: Self.classifyRoot)
        #expect(InstanceLock.isPythonBundleExecutable(path: resolved, repoRoot: URL(fileURLWithPath: Self.classifyRoot))
                == expected)
    }

    @Test func pythonBundleExecutableNormalisesTheRepoRootSpelling() {
        let exe = Self.classifyRoot + "/dist/JARVIS.app/Contents/MacOS/JARVIS"
        for root in ["/opt/jarvis-classify-root/", "/opt//jarvis-classify-root",
                     "/opt/x/../jarvis-classify-root", "/opt/./jarvis-classify-root/."] {
            #expect(InstanceLock.isPythonBundleExecutable(path: exe, repoRoot: URL(fileURLWithPath: root)), "\(root)")
        }
    }

    /// proc_pidpath reports resolved paths, so a root reached through a symlink (and the
    /// temporary directory's /var → /private/var) must match in both spellings. Only a
    /// directory and a symlink are created; nothing is executed.
    @Test func pythonBundleExecutableMatchesASymlinkedRootBothWays() throws {
        let s = try Sandbox()
        defer { s.remove() }
        try FileManager.default.createDirectory(at: s.root.appending(path: "real", directoryHint: .isDirectory),
                                                withIntermediateDirectories: true)
        let linkPath = s.root.appending(path: "link", directoryHint: .notDirectory).path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "real")
        let link = URL(fileURLWithPath: linkPath)
        let resolvedSandbox = try #require(realpath(s.root.path(percentEncoded: false), nil))
        defer { free(resolvedSandbox) }
        let tail = "/dist/JARVIS.app/Contents/MacOS/JARVIS"
        let viaRealPath = String(cString: resolvedSandbox) + "/real" + tail
        let viaLink = linkPath + tail
        #expect(viaRealPath != viaLink)
        #expect(InstanceLock.isPythonBundleExecutable(path: viaRealPath, repoRoot: link))
        #expect(InstanceLock.isPythonBundleExecutable(path: viaLink, repoRoot: link))
        #expect(!InstanceLock.isPythonBundleExecutable(path: String(cString: resolvedSandbox) + "/link2" + tail,
                                                       repoRoot: link))
    }

    @Test func freshSandboxHasNoForeignProcesses() throws {
        let s = try Sandbox()
        defer { s.remove() }
        #expect(InstanceLock.foreignJarvisProcesses(repoRoot: s.root) == [])
    }
}
