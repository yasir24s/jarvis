import Darwin
import Foundation

/// Why a socket-layer call failed. None of these carry a token.
public enum MCPSocketError: Error, Equatable, CustomStringConvertible {
    /// The path does not fit `sockaddr_un.sun_path` (104 bytes with its NUL).
    case pathTooLong(String)
    /// Something other than a socket owned by our uid is at the socket path; it is left alone.
    case notOurSocket(String)
    /// The run directory is a symlink, not a directory, or not owned by our uid.
    case unsafeRunDirectory(String)
    /// A system call failed with this errno.
    case system(String, Int32)

    public var description: String {
        switch self {
        case .pathTooLong(let path): "socket path is \(path.utf8.count) bytes, over the sun_path limit: \(path)"
        case .notOurSocket(let path): "not a socket owned by this user, left in place: \(path)"
        case .unsafeRunDirectory(let path): "run directory is not a directory owned by this user: \(path)"
        case .system(let call, let code): "\(call): \(String(cString: strerror(code)))"
        }
    }
}

/// The POSIX side of plan §3.7, shared by the server and the relay. Everything here is
/// synchronous; the server calls it from its private queue, the relay from its own process.
public enum MCPSocket {
    /// `sizeof(sockaddr_un.sun_path)`. A socket path must be shorter, to leave room for the NUL.
    public static let sunPathSize = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// `<runDirectory>/mcp.sock`.
    public static func socketPath(in runDirectory: URL) -> String {
        runDirectory.appending(path: "mcp.sock", directoryHint: .notDirectory).path(percentEncoded: false)
    }

    /// Creates the run directory (with parents) if it is missing, refuses one that is a symlink,
    /// not a directory, or not ours, and sets it to mode 0700.
    public static func prepareRunDirectory(_ url: URL) throws {
        let path = url.path(percentEncoded: false)
        var st = stat()
        if lstat(path, &st) != 0 {
            guard errno == ENOENT else { throw MCPSocketError.system("lstat", errno) }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard lstat(path, &st) == 0 else { throw MCPSocketError.system("lstat", errno) }
        }
        guard st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            throw MCPSocketError.unsafeRunDirectory(path)
        }
        guard chmod(path, 0o700) == 0 else { throw MCPSocketError.system("chmod", errno) }
    }

    /// The stale-socket rule: unlink what is at `path` only if lstat shows a socket owned by our
    /// uid. Nothing there is fine; anything else is refused and left in place.
    public static func removeStaleSocket(at path: String) throws {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            if errno == ENOENT { return }
            throw MCPSocketError.system("lstat", errno)
        }
        guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else {
            throw MCPSocketError.notOurSocket(path)
        }
        guard unlink(path) == 0 || errno == ENOENT else { throw MCPSocketError.system("unlink", errno) }
    }

    /// Binds and listens at `path`: stale-socket rule first, then `bind` and `chmod 0600`.
    /// Returns the listening descriptor (non-blocking, close-on-exec).
    ///
    /// Plan §3.7 also puts `umask(0o177)` around `bind`. That is left out on purpose: umask is
    /// process-wide, so any other thread creating a directory during the window got mode 0600,
    /// with no search bit, and a later create inside it failed with EACCES (seen in the full
    /// test run). The socket is never reachable by another user in that window anyway: it is
    /// created inside the run directory, which `prepareRunDirectory` has already made 0700 and ours.
    public static func listen(at path: String, backlog: Int32 = 8) throws -> Int32 {
        var address = try address(for: path)
        try removeStaleSocket(at: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system("socket", errno) }
        var bound = false
        do {
            try configure(fd)
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
                throw MCPSocketError.system("fcntl", errno)
            }
            let rc = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else { throw MCPSocketError.system("bind", errno) }
            bound = true
            guard chmod(path, 0o600) == 0 else { throw MCPSocketError.system("chmod", errno) }
            guard Darwin.listen(fd, backlog) == 0 else { throw MCPSocketError.system("listen", errno) }
            return fd
        } catch {
            close(fd)
            if bound { unlink(path) }
            throw error
        }
    }

    /// Connects to the socket at `path` (blocking, close-on-exec, no SIGPIPE). The relay uses this.
    public static func connect(to path: String) throws -> Int32 {
        var address = try address(for: path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPSocketError.system("socket", errno) }
        do {
            try configure(fd)
            let rc = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else { throw MCPSocketError.system("connect", errno) }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    /// Accepts one pending connection, or returns nil when none is waiting.
    static func accept(_ listener: Int32) -> Int32? {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            if fd >= 0 {
                if (try? configure(fd)) == nil {
                    close(fd)
                    continue
                }
                return fd
            }
            if errno == EINTR || errno == ECONNABORTED { continue }
            return nil
        }
    }

    /// Close-on-exec, and SO_NOSIGPIPE so a vanished peer gives EPIPE instead of a signal.
    public static func configure(_ fd: Int32) throws {
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw MCPSocketError.system("fcntl", errno) }
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw MCPSocketError.system("setsockopt", errno)
        }
    }

    static func address(for path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard bytes.count < sunPathSize else { throw MCPSocketError.pathTooLong(path) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
}

/// What the handshake learns about the process at the other end of a connection (plan §3.7).
struct MCPPeer: Sendable, Equatable {
    let uid: uid_t?
    let pid: pid_t?
    let executablePath: String?
    let parentPID: pid_t?

    init(uid: uid_t?, pid: pid_t?, executablePath: String?, parentPID: pid_t?) {
        self.uid = uid
        self.pid = pid
        self.executablePath = executablePath
        self.parentPID = parentPID
    }

    /// `getpeereid`, `LOCAL_PEERPID`, then `proc_pidpath` and `pbi_ppid` for that pid.
    init(connection fd: Int32) {
        var uid = uid_t()
        var gid = gid_t()
        let peerUID: uid_t? = getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        var pid = pid_t()
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let peerPID: pid_t? = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 ? pid : nil
        self.init(uid: peerUID, pid: peerPID,
                  executablePath: peerPID.flatMap(Self.executablePath(of:)),
                  parentPID: peerPID.flatMap(Self.parentPID(of:)))
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))   // PROC_PIDPATHINFO_MAXSIZE
        let count = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF8.self)
    }

    static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(bitPattern: info.pbi_ppid)
    }
}
