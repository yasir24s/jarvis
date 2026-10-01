import Darwin
import Foundation
import JarvisCore

protocol FileMutating: FileProbe {
    func trash(_ path: String) -> Bool
    func hardDelete(_ path: String) throws
    func write(_ path: String, content: String) throws
    func move(_ source: String, _ destination: String) throws
}

struct FileMutationError: Error, CustomStringConvertible {
    let description: String
    static func posix(_ code: Int32, path: String) -> Self {
        Self(description: "[Errno \(code)] \(String(cString: strerror(code))): \(PyRepr.string(path))")
    }
    /// An OSError with two filenames, as os.rename and os.symlink raise it.
    static func posix(_ code: Int32, path: String, to other: String) -> Self {
        Self(description: "[Errno \(code)] \(String(cString: strerror(code))): \(PyRepr.string(path)) -> \(PyRepr.string(other))")
    }
}

struct LiveFileMutations: FileMutating {
    /// rename(2); tests replace it to take the cross-device path on one volume.
    var rename: @Sendable (String, String) -> Int32 = { Darwin.rename($0, $1) }

    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func isDir(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    func trash(_ path: String) -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return true
        } catch { return false }
    }
    func hardDelete(_ path: String) throws {
        // Python 3.14's rmtree refuses a symlink with OSError(None, None, path).
        if isDir(path), isLink(path) {
            throw FileMutationError(description: "[Errno None] None: \(PyRepr.string(path))")
        }
        do { try FileManager.default.removeItem(atPath: path) }
        catch let error as NSError {
            let code = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EIO)
            throw FileMutationError.posix(Int32(code), path: path)
        }
    }
    func write(_ path: String, content: String) throws {
        if path.utf8.contains(0) { throw FileMutationError(description: "embedded null byte") }
        let parent = (path as NSString).deletingLastPathComponent
        do { try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true) }
        catch let error as NSError {
            let code = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EIO)
            throw FileMutationError.posix(Int32(code), path: parent)
        }
        // O_TRUNC retains the inode and mode of an existing file, as Python open("w").
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw FileMutationError.posix(errno, path: path) }
        defer { close(fd) }
        let data = Data(content.utf8)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw FileMutationError.posix(errno, path: path) }
                offset += count
            }
        }
    }
}

/// `shutil.move` (plan: M05-M06 §3.5 PyShutil.move). Into an existing directory it moves to
/// `dst/basename(src)` and refuses a name already there; otherwise rename(2), which replaces a
/// file as os.rename does. When the rename fails for any reason (EXDEV in practice) Python
/// copies and then deletes, so its errors are the copy's: a link is re-created, a directory
/// copied as copytree(symlinks=True) then removed, a file copied as copy2 then unlinked.
extension LiveFileMutations {
    func move(_ source: String, _ destination: String) throws {
        var target = destination
        if isDir(destination) {
            if sameFile(source, destination), !isLink(source) {
                guard rename(source, destination) == 0 else {
                    throw FileMutationError.posix(errno, path: source, to: destination)
                }
                return
            }
            target = destination + "/" + Self.basename(source)
            if exists(target) { throw FileMutationError(description: "Destination path '\(target)' already exists") }
        }
        if rename(source, target) == 0 { return }
        if isLink(source) {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(source, &buffer, buffer.count - 1)
            guard count >= 0 else { throw FileMutationError.posix(errno, path: source) }
            let link = String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard symlink(link, target) == 0 else { throw FileMutationError.posix(errno, path: link, to: target) }
            guard unlink(source) == 0 else { throw FileMutationError.posix(errno, path: source) }
        } else if isDir(source) {
            if Self.destinationInSource(source, destination) {
                throw FileMutationError(description: "Cannot move a directory '\(source)' into itself '\(destination)'.")
            }
            if immutable(source) || (access(source, W_OK) != 0 && !((try? FileManager.default.contentsOfDirectory(atPath: source)) ?? []).isEmpty) {
                throw FileMutationError(description: "Cannot move the non-empty directory '\(source)': Lacking write permission to '\(source)'.")
            }
            try copyTree(source, target)
            try hardDelete(source)
        } else {
            try copyFile(source, isDir(target) ? target + "/" + Self.basename(source) : target)
            guard unlink(source) == 0 else { throw FileMutationError.posix(errno, path: source) }
        }
    }

    func isLink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    /// os.path.samefile, False when either stat fails (shutil._samefile).
    private func sameFile(_ a: String, _ b: String) -> Bool {
        var x = stat(), y = stat()
        return stat(a, &x) == 0 && stat(b, &y) == 0 && x.st_dev == y.st_dev && x.st_ino == y.st_ino
    }

    /// shutil._is_immutable: st_flags equal to one immutable flag.
    private func immutable(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_flags == UInt32(UF_IMMUTABLE) || info.st_flags == UInt32(SF_IMMUTABLE))
    }

    /// shutil._basename: the basename after trailing separators are dropped.
    static func basename(_ path: String) -> String {
        SpotlightQuery.basename(Py.rstrip(path, "/"))
    }

    /// shutil._destinsrc on absolute paths.
    static func destinationInSource(_ source: String, _ destination: String) -> Bool {
        let s = source.hasSuffix("/") ? source : source + "/"
        let d = destination.hasSuffix("/") ? destination : destination + "/"
        return Py.startsWith(d, s)
    }

    /// copy2's copyfile then copystat: data through open(2), metadata best effort.
    private func copyFile(_ source: String, _ target: String) throws {
        let input = open(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { throw FileMutationError.posix(errno, path: source) }
        defer { close(input) }
        let output = open(target, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o666)
        guard output >= 0 else {
            let code = errno
            if code == EISDIR, !exists(target) {
                throw FileMutationError(description: "Directory does not exist: \(target)")
            }
            throw FileMutationError.posix(code, path: target)
        }
        defer { close(output) }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw FileMutationError.posix(errno, path: source, to: target)
        }
        _ = copyfile(source, target, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    /// copytree(symlinks=True): makedirs(target) (parents too, the target itself must not
    /// exist), then each entry copied with links kept as links.
    private func copyTree(_ source: String, _ target: String) throws {
        let entries: [String]
        do { entries = try FileManager.default.contentsOfDirectory(atPath: source) }
        catch let error as NSError { throw FileMutationError.posix(Self.posixCode(error), path: source) }
        if exists(target) || isLink(target) { throw FileMutationError.posix(EEXIST, path: target) }
        do { try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true) }
        catch let error as NSError { throw FileMutationError.posix(Self.posixCode(error), path: target) }
        for entry in entries {
            let from = source + "/" + entry, to = target + "/" + entry
            do { try FileManager.default.copyItem(atPath: from, toPath: to) }
            catch let error as NSError { throw FileMutationError.posix(Self.posixCode(error), path: from, to: to) }
        }
        _ = copyfile(source, target, nil, copyfile_flags_t(COPYFILE_METADATA))
    }

    static func posixCode(_ error: NSError) -> Int32 {
        Int32((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? Int(EIO))
    }
}

/// Shared by the live process; tests supply a separate session and a temporary home.
actor FileMutationSession {
    static let live = FileMutationSession(files: LiveFileMutations(),
        home: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        cwd: FileManager.default.currentDirectoryPath)
    let files: any FileMutating
    let home: String
    let cwd: String
    private var written: Set<String> = []

    init(files: any FileMutating, home: String, cwd: String) {
        self.files = files; self.home = home; self.cwd = cwd
    }

    func delete(path: String, permanent: Bool) -> ToolOutcome {
        outcome(FileMutationPolicy.delete(path: path, permanent: permanent, probe: files, home: home, cwd: cwd))
    }
    func write(path: String, content: String) -> ToolOutcome {
        outcome(FileMutationPolicy.write(path: path, probe: files, writtenThisSession: written,
                                          home: home, cwd: cwd), content: content)
    }
    func move(src: String, dst: String) -> ToolOutcome {
        outcome(FileMutationPolicy.move(src: src, dst: dst, probe: files, home: home, cwd: cwd))
    }
    private func outcome(_ decision: FileDecision, content: String = "") -> ToolOutcome {
        switch decision {
        case .notFound(let text), .refuse(let text): return .text(text)
        case .instant(let op): return .text(perform(op, content: content))
        case .gate(let desc, let op):
            return .needsConfirmation(desc: desc) { await self.perform(op, content: content) }
        }
    }
    private func perform(_ op: FileOp, content: String) -> String {
        switch op {
        case .trash(let path):
            let name = (path as NSString).lastPathComponent
            return files.trash(path) ? "Moved \(name) to the Trash, sir." : "I couldn't move \(name) to the Trash, sir."
        case .hardDelete(let path):
            do {
                try files.hardDelete(path)
                return "Permanently deleted \((path as NSString).lastPathComponent), sir."
            } catch { return "Delete failed, sir: \(error)" }
        case .write(let path):
            do {
                try files.write(path, content: content)
                written.insert(path)
                return "Wrote \((path as NSString).lastPathComponent), sir."
            } catch { return "Write failed, sir: \(error)" }
        case .move(let source, let destination):
            // The guard hands over absolute paths, so the names are theirs: a trailing "/"
            // still names the folder, where Python's basename gives "" (DEV-M5-04, proposed).
            do {
                try files.move(source, destination)
                return "Moved \((source as NSString).lastPathComponent) to \((destination as NSString).lastPathComponent), sir."
            } catch { return "Move failed, sir: \(error)" }
        }
    }
}

struct WriteFile: ToolImpl {
    static let name = "write_file"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let session: FileMutationSession
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        await session.write(path: args["path"]?.stringValue ?? "", content: args["content"]?.stringValue ?? "")
    }
}

struct MoveFile: ToolImpl {
    static let name = "move_file"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let session: FileMutationSession
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        await session.move(src: args["src"]?.stringValue ?? "", dst: args["dst"]?.stringValue ?? "")
    }
}

struct DeleteFile: ToolImpl {
    static let name = "delete_file"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let session: FileMutationSession
    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        await session.delete(path: args["path"]?.stringValue ?? "", permanent: args["permanent"]?.pyTruthy ?? false)
    }
}
