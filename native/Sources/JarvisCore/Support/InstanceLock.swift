import Foundation

// Single-instance guard shared with Python JARVIS (plan: M00 §3.5). Both implementations hold
// a BSD flock(LOCK_EX | LOCK_NB) on <root>/.jarvis.lock for their whole life; the kernel drops
// it when the holder dies, so there is no stale lock and no PID-reuse bug. The text in the file
// ("<impl> <pid> <epoch>\n") is diagnostic only — correctness comes from the flock.
//
// flock is per open-file-description, so two opens in one process conflict, and closing some
// other fd on the same file (readHolder) does not drop the lock — unlike POSIX fcntl locks.

/// Who the lock file says holds the lock. `unknown` carries the text when it does not parse.
public enum LockHolder: Sendable, Equatable {
    case python(pid: Int32)
    case native(pid: Int32)
    case unknown(String)
}

/// A held lock. Immutable: the fd is locked for as long as this object is alive and closed
/// (which releases the flock) in `deinit`. The app keeps it until process exit.
public final class InstanceLock: Sendable {
    public let url: URL
    private let fd: Int32

    public enum Outcome: Sendable {
        case acquired(InstanceLock)
        case held(by: LockHolder?)
        case foreignProcess(pids: [Int32])
    }

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit {
        close(fd)
    }

    /// One non-blocking attempt. On success the file is truncated and rewritten as
    /// "<impl> <pid> <epoch>\n". If the flock is free but `foreignJarvisProcesses(repoRoot:)`
    /// finds a pre-patch Python JARVIS, the lock is released again and `.foreignProcess` is
    /// returned — refused exactly as if the lock were held. A file that cannot be opened or
    /// locked is reported as `.held(by: .unknown(<reason>))`: never run without the lock.
    public static func tryAcquire(at url: URL, repoRoot: URL, impl: String = "native") -> Outcome {
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            return .held(by: .unknown("cannot open \(path): \(String(cString: strerror(errno))) (errno \(errno))"))
        }
        var rc: Int32
        repeat { rc = flock(fd, LOCK_EX | LOCK_NB) } while rc != 0 && errno == EINTR
        guard rc == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return .held(by: readHolder(at: url)) }
            return .held(by: .unknown("cannot flock \(path): \(String(cString: strerror(code))) (errno \(code))"))
        }
        let foreign = foreignJarvisProcesses(repoRoot: repoRoot)
        guard foreign.isEmpty else {
            close(fd)
            return .foreignProcess(pids: foreign)
        }
        let line = Array("\(impl) \(getpid()) \(time(nil))\n".utf8)
        _ = ftruncate(fd, 0)
        _ = line.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress!, $0.count, 0) }
        return .acquired(InstanceLock(url: url, fd: fd))
    }

    /// Polls `tryAcquire` every `poll` until it succeeds (launchd mode: no KeepAlive thrash).
    /// `onFirstWait` runs once, before the first sleep, with the holder (a foreign pre-patch
    /// process is reported as `.python(pid:)` of its first pid). Not cancellable: it only
    /// ever returns a held lock.
    public static func acquireWaiting(at url: URL, repoRoot: URL, poll: Duration = .seconds(5),
                                      onFirstWait: @Sendable (LockHolder?) -> Void) async -> InstanceLock {
        var warned = false
        while true {
            let holder: LockHolder?
            switch tryAcquire(at: url, repoRoot: repoRoot) {
            case .acquired(let lock): return lock
            case .held(let by): holder = by
            case .foreignProcess(let pids): holder = .python(pid: pids[0])
            }
            if !warned {
                onFirstWait(holder)
                warned = true
            }
            await sleepIgnoringCancellation(poll)
        }
    }

    /// Parses "<impl> <pid> <epoch>" (impl ∈ {python, native}, surrounding whitespace ignored).
    /// nil if the file is missing, unreadable or empty (a holder between truncate and write).
    public static func readHolder(at url: URL) -> LockHolder? {
        guard let data = try? Data(contentsOf: url, options: [.uncached]) else { return nil }
        let text = String(decoding: data.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[1].allSatisfy(\.isASCII), parts[2].allSatisfy(\.isASCII),
              let pid = Int32(parts[1]), pid > 0, Int64(parts[2]) != nil else {
            return .unknown(text)
        }
        switch parts[0] {
        case "python": return .python(pid: pid)
        case "native": return .native(pid: pid)
        default: return .unknown(text)
        }
    }

    /// Belt and braces against a pre-patch Python that never takes the lock: pids (other than
    /// this one) whose executable is <root>/dist/JARVIS.app/Contents/MacOS/JARVIS (the py2app
    /// bundle) or whose argv has an element equal to <root>/jarvis.py. Processes whose path or
    /// arguments cannot be read (other users') are skipped.
    public static func foreignJarvisProcesses(repoRoot: URL) -> [Int32] {
        let roots = rootSpellings(repoRoot)
        let bundles = Set(roots.map { $0 + "/dist/JARVIS.app/Contents/MacOS/JARVIS" })
        let scripts = Set(roots.map { $0 + "/jarvis.py" })
        let me = getpid()
        var argBuffer = [UInt8](repeating: 0, count: argMax())
        var hits: [Int32] = []
        for pid in allPids() where pid > 0 && pid != me {
            if let exe = executablePath(pid), bundles.contains(exe) {
                hits.append(pid)
            } else if let argv = arguments(pid, &argBuffer), argv.contains(where: scripts.contains) {
                hits.append(pid)
            }
        }
        return hits.sorted()
    }

    // MARK: - Private

    /// The root as given and as realpath(3) resolves it (proc_pidpath reports resolved paths,
    /// e.g. /private/var/… for /var/…; argv keeps whatever the launcher typed).
    private static func rootSpellings(_ root: URL) -> [String] {
        var given = root.standardizedFileURL.path(percentEncoded: false)
        while given.count > 1 && given.hasSuffix("/") { given.removeLast() }
        var out = [given]
        if let resolved = realpath(given, nil) {
            let r = String(cString: resolved)
            free(resolved)
            if r != given { out.append(r) }
        }
        return out
    }

    private static func allPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(decoding: buf.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func argMax() -> Int {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return 1 << 20 }
        return Int(argmax)
    }

    /// argv from sysctl(KERN_PROCARGS2): int32 argc, exec path, NUL padding, argv[0..<argc], env.
    /// `buf` (KERN_ARGMAX bytes) is reused across pids.
    private static func arguments(_ pid: Int32, _ buf: inout [UInt8]) -> [String]? {
        var size = buf.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && buf[i] != 0 { i += 1 }             // exec path
        while i < size && buf[i] == 0 { i += 1 }             // padding
        var argv: [String] = []
        while argv.count < Int(argc) && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            argv.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return argv
    }

    private static func sleepIgnoringCancellation(_ duration: Duration) async {
        let (s, atto) = duration.components
        let nanos = max(0, s) * 1_000_000_000 + max(0, atto) / 1_000_000_000
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) { c.resume() }
        }
    }
}
