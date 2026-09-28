import Foundation

// Crash-safe state file IO (plan: M01 §3.5 atomic write algorithm; M00 §3.6 appendLine).
// Python truncates in place (`open(path, "w")`); native writes a temp file in the same
// directory and renames it over the target, so a crash never leaves a torn file. Renaming
// replaces the inode, which drops the old file's xattrs (accepted, M01 §8 R3).

public struct AtomicFileError: Error, Sendable, Equatable, CustomStringConvertible {
    public let operation: String
    public let path: String
    public let code: Int32                                          // errno

    public var description: String {
        "AtomicFile \(operation) \(path): \(String(cString: strerror(code))) (errno \(code))"
    }
}

public enum AtomicFile {
    /// The file's bytes; nil if it is missing or unreadable (or a directory).
    public static func read(_ path: String) -> Data? {
        try? Data(contentsOf: URL(fileURLWithPath: path), options: [.uncached])
    }

    /// Writes `data` to `path` atomically:
    /// 1. a symlink at `path` is followed (Python's `open(path, "w")` writes through it);
    /// 2. `mkstemp("<dir>/.<name>.jarvis-tmp.XXXXXXXX")` in the target's own directory;
    /// 3. every byte written (short writes and EINTR retried), then `fsync`;
    /// 4. `fchmod` to the existing target's `st_mode & 0o7777`, else 0o644;
    /// 5. `close`, `rename` over the target. On any failure the temp file is unlinked and
    ///    the target is left exactly as it was.
    public static func write(_ data: Data, to path: String) throws {
        let target = try resolveSymlinks(path)
        let slash = target.lastIndex(of: "/")
        let dir = slash.map { String(target[..<$0]) } ?? "."
        let name = slash.map { String(target[target.index(after: $0)...]) } ?? target
        var template = Array((dir + "/." + name + ".jarvis-tmp.XXXXXXXX").utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkostemp($0.baseAddress!, O_CLOEXEC) }
        guard fd >= 0 else { throw AtomicFileError(operation: "mkstemp", path: target, code: errno) }
        let tmp = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        var open = true
        do {
            try writeAll(fd, data, path: tmp)
            guard fsync(fd) == 0 else { throw AtomicFileError(operation: "fsync", path: tmp, code: errno) }
            var st = stat()
            let mode: mode_t = stat(target, &st) == 0 ? st.st_mode & 0o7777 : 0o644
            guard fchmod(fd, mode) == 0 else {
                throw AtomicFileError(operation: "fchmod", path: tmp, code: errno)
            }
            open = false
            guard close(fd) == 0 else { throw AtomicFileError(operation: "close", path: tmp, code: errno) }
            guard rename(tmp, target) == 0 else {
                throw AtomicFileError(operation: "rename", path: target, code: errno)
            }
        } catch {
            if open { close(fd) }
            unlink(tmp)
            throw error
        }
    }

    /// Deletes leftover `write` temp files (`.<name>.jarvis-tmp.XXXXXXXX`, regular files only,
    /// symlinks and directories are never touched) directly inside `dir` whose mtime is more
    /// than `age` seconds before `now` (M01 §3.5 step 6). Returns the removed names, sorted.
    /// A crash between `mkstemp` and `rename` is the only way one survives.
    @discardableResult
    public static func removeStaleTemps(in dir: String, olderThan age: Double, now: Double) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var removed: [String] = []
        for name in names where name.hasPrefix(".") && name.contains(".jarvis-tmp.") {
            let path = (dir.hasSuffix("/") ? dir : dir + "/") + name
            var st = stat()
            guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
            let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            if now - mtime > age && unlink(path) == 0 {
                removed.append(name)
            }
        }
        return removed.sorted()
    }

    /// Python "a"-mode append of one line (metrics.jsonl, jarvis_notes.txt): opens with
    /// O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC (a new file gets 0o666 & ~umask, like Python),
    /// writes `line + "\n"` as UTF-8 in one write(2) (retried only on a short write), closes.
    public static func appendLine(_ line: String, to path: String) throws {
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw AtomicFileError(operation: "open", path: path, code: errno) }
        defer { close(fd) }
        try writeAll(fd, Data((line + "\n").utf8), path: path)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFileError(operation: "write", path: path, code: errno)
                }
                off += n
            }
        }
    }

    /// Follows a chain of symlinks at `path` (relative targets resolve against the link's
    /// directory). A dangling link resolves to its missing target, which is then created —
    /// as `open(path, "w")` does. Only the final component is followed.
    private static func resolveSymlinks(_ path: String) throws -> String {
        var current = path
        for _ in 0..<32 {
            var st = stat()
            guard lstat(current, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else { return current }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(current, &buf, Int(PATH_MAX))
            guard n >= 0 else { throw AtomicFileError(operation: "readlink", path: current, code: errno) }
            let dest = String(decoding: buf[..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if dest.hasPrefix("/") {
                current = dest
            } else if let slash = current.lastIndex(of: "/") {
                current = String(current[...slash]) + dest
            } else {
                current = dest
            }
        }
        throw AtomicFileError(operation: "readlink", path: path, code: ELOOP)
    }
}
