import Foundation

// D-51 P3, piece 1: the walk over the user's home folder and every rule that keeps a file
// out of it. The walk reads names and metadata only; it never opens a file, follows a
// symlink, or triggers an iCloud download. Callers log the counts, never a path.

/// Why the walk passed an entry over. A skipped folder counts once; its contents are never listed.
public enum FileSkip: String, Sendable, CaseIterable {
    case hidden          // a name starting with "."
    case library         // ~/Library (iCloud Drive inside it is walked as its own root)
    case stateRoot       // JARVIS's own state, memory, research, logs and voices
    case buildOutput     // .build, node_modules, DerivedData, Pods, build, dist
    case bundle          // .app, .framework, .xcframework, .bundle
    case byType          // media, archives, disk images, binaries
    case credential      // keys, certificates, credential names, .env
    case tooLarge        // over FileExclusions.maxBytes
    case notDownloaded   // dataless, or an iCloud item whose latest version is not on the Mac
    case symlink         // never followed
    case notADocument    // source code and everything else outside the document types
    case unreadable      // gone, or a folder that cannot be listed
}

/// How a document's text is extracted.
public enum DocumentKind: String, Sendable, CaseIterable {
    case plainText, markdown, csv, rtf, rtfd, docx, pdf
}

/// A document the walk found: one file (or an .rtfd package) to read.
public struct FileCandidate: Sendable, Equatable {
    public let url: URL
    public let kind: DocumentKind
    public let size: Int          // bytes (an .rtfd: the files inside it)
    public let modified: Double   // epoch seconds (an .rtfd: the newest file inside it)

    public init(url: URL, kind: DocumentKind, size: Int, modified: Double) {
        self.url = url
        self.kind = kind
        self.size = size
        self.modified = modified
    }
}

/// The name rules, for a file or a folder. Every comparison ignores case, as APFS does.
public enum FileExclusions {
    public static let maxBytes = 20 * 1024 * 1024
    public static let iCloudDrive = "Library/Mobile Documents/com~apple~CloudDocs"

    public static let buildOutput: Set<String> = [".build", "node_modules", "deriveddata", "pods",
                                                   "build", "dist"]
    public static let bundleExtensions: Set<String> = ["app", "framework", "xcframework", "bundle"]
    public static let credentialExtensions: Set<String> = ["pem", "key", "p12", "pfx", "cer", "crt"]
    public static let credentialWords = ["credential", "secret", "token", "password"]

    /// Media, archives, disk images and binaries, by extension (JarvisCore has no UTType).
    public static let skippedTypes: Set<String> = [
        // images
        "jpg", "jpeg", "png", "gif", "heic", "heif", "tif", "tiff", "bmp", "webp", "ico", "icns",
        "psd", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "svg", "avif",
        // audio and video
        "mp3", "m4a", "m4b", "m4p", "aac", "wav", "aif", "aiff", "flac", "ogg", "oga", "opus",
        "wma", "mid", "midi", "caf", "mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv",
        "mpg", "mpeg", "3gp", "mts", "m2ts", "vob",
        // media libraries
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "logicx", "band",
        // archives and installers
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "7z", "rar", "zst", "lz", "lz4",
        "lzma", "z", "cpio", "xar", "pkg", "mpkg", "jar", "war", "ear", "apk", "aab", "ipa",
        "deb", "rpm", "cab", "msi", "xip",
        // disk images and virtual machines
        "dmg", "iso", "img", "sparseimage", "sparsebundle", "toast", "cdr", "vmdk", "vdi",
        "qcow2", "vhd", "vhdx", "utm", "vmwarevm", "pvm",
        // binaries and compiled objects
        "exe", "dll", "so", "dylib", "a", "o", "obj", "lib", "bin", "dat", "class", "pyc", "pyo",
        "wasm", "elf", "dSYM", "ko", "sys", "rlib", "swiftmodule", "swiftdoc", "car", "nib",
        "sqlite", "sqlite3", "db", "realm",
    ].reduce(into: Set<String>()) { $0.insert($1.lowercased()) }

    static let documentExtensions: [String: DocumentKind] = [
        "txt": .plainText, "text": .plainText, "md": .markdown, "markdown": .markdown,
        "csv": .csv, "rtf": .rtf, "rtfd": .rtfd, "docx": .docx, "pdf": .pdf,
    ]
    static let readmeExtensions: [String: DocumentKind] = [
        "": .plainText, "txt": .plainText, "text": .plainText, "rst": .plainText,
        "md": .markdown, "markdown": .markdown,
    ]

    /// The rule `name` breaks for a folder or file, before anything about it is read.
    public static func skip(name: String, isDirectory: Bool) -> FileSkip? {
        if name.hasPrefix(".") { return .hidden }
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if isCredential(lower, ext: ext) { return .credential }
        if isDirectory {
            if buildOutput.contains(lower) { return .buildOutput }
            if bundleExtensions.contains(ext) { return .bundle }
        }
        if skippedTypes.contains(ext) { return .byType }
        return nil
    }

    /// The kind `name` reads as: inside a repository only its README files, elsewhere the
    /// document types and README files. Nil for source code and everything else.
    public static func documentKind(name: String, inRepository: Bool) -> DocumentKind? {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        let stem = (lower as NSString).deletingPathExtension
        if stem == "readme", let kind = readmeExtensions[ext] { return kind }
        return inRepository ? nil : documentExtensions[ext]
    }

    /// Keys, certificates and credentials: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.cer`, `*.crt`,
    /// `id_rsa*`, `*.keychain*`, a name containing credential, secret, token or password, and
    /// `.env` however it is spelt (`.env`, `.ENV`, `.env.local`, `prod.env`, `env.txt`).
    static func isCredential(_ lower: String, ext: String) -> Bool {
        if credentialExtensions.contains(ext) || lower.hasPrefix("id_rsa")
            || lower.contains(".keychain") { return true }
        if credentialWords.contains(where: { lower.contains($0) }) { return true }
        return lower.split(separator: ".", omittingEmptySubsequences: true).contains("env")
    }
}

/// A lazy walk of the home folder, then of iCloud Drive, one document at a time. Each call to
/// `next()` lists at most the folders it needs, so a pass can pause between files. Folders are
/// listed in name order; a folder's documents come before its subfolders'.
public struct FileWalk: Sequence, IteratorProtocol {
    public private(set) var skipped: [FileSkip: Int] = [:]
    public private(set) var directoriesListed = 0

    private let probe: any FileSystemProbe
    private let library: String
    private let stateRoot: String
    private var pending: [(url: URL, inRepository: Bool, isRoot: Bool)] = []
    private var ready: [FileCandidate] = []          // the current folder's documents, last first

    /// `home` and `stateRoot` are resolved through any symlinks first, so the state root is
    /// recognised however it was named. Roots that do not exist are passed over quietly.
    public init(home: URL, stateRoot: URL, probe: any FileSystemProbe = LiveFileSystemProbe()) {
        let home = Self.resolved(home)
        self.probe = probe
        self.library = Self.key(home.appending(path: "Library", directoryHint: .isDirectory))
        self.stateRoot = Self.key(Self.resolved(stateRoot))
        let roots = [home.appending(path: FileExclusions.iCloudDrive, directoryHint: .isDirectory),
                     home]   // popped from the end: the home folder first
        for root in roots {
            let path = Self.key(root)
            if path == self.stateRoot || path.hasPrefix(self.stateRoot + "/") { continue }
            if let info = probe.info(root), info.isDirectory, !info.isDataless {
                pending.append((root, false, true))
            }
        }
    }

    /// The total number of entries passed over, across every reason.
    public var skippedCount: Int { skipped.values.reduce(0, +) }

    public mutating func next() -> FileCandidate? {
        while ready.isEmpty, let folder = pending.popLast() {
            list(folder.url, inRepository: folder.inRepository, isRoot: folder.isRoot)
        }
        return ready.popLast()
    }

    /// A folder holding `.git` is a repository, and so is everything below it; a `.git` in
    /// the home folder itself (dotfiles kept in git) does not make the whole home one.
    private mutating func list(_ folder: URL, inRepository: Bool, isRoot: Bool) {
        guard let entries = probe.entries(of: folder) else { return count(.unreadable) }
        directoriesListed += 1
        let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let inRepository = inRepository
            || (!isRoot && sorted.contains { $0.lastPathComponent == ".git" })
        var subfolders: [URL] = []
        for url in sorted {
            let name = url.lastPathComponent
            if name.hasPrefix(".") { count(.hidden); continue }     // before anything is read
            guard let info = probe.info(url) else { count(.unreadable); continue }
            if info.isSymbolicLink { count(.symlink); continue }
            if info.isDirectory {
                if let folder = admitFolder(url, name: name, info: info, inRepository: inRepository) {
                    subfolders.append(folder)
                }
            } else if info.isRegularFile {
                admitFile(url, name: name, info: info, inRepository: inRepository)
            } else {
                count(.notADocument)                                  // sockets, pipes, devices
            }
        }
        ready.reverse()
        for folder in subfolders.reversed() { pending.append((folder, inRepository, false)) }
    }

    /// The folder to descend into, or nil when it is skipped or is itself a document (.rtfd).
    private mutating func admitFolder(_ url: URL, name: String, info: FileEntryInfo,
                                      inRepository: Bool) -> URL? {
        let path = Self.key(url)
        if path == library { count(.library); return nil }
        if path == stateRoot { count(.stateRoot); return nil }
        if let rule = FileExclusions.skip(name: name, isDirectory: true) { count(rule); return nil }
        if info.isDataless { count(.notDownloaded); return nil }    // listing it would download it
        guard FileExclusions.documentKind(name: name, inRepository: inRepository) == .rtfd else {
            return url
        }
        admitPackage(url)
        return nil
    }

    private mutating func admitFile(_ url: URL, name: String, info: FileEntryInfo,
                                    inRepository: Bool) {
        if let rule = FileExclusions.skip(name: name, isDirectory: false) { return count(rule) }
        guard let kind = FileExclusions.documentKind(name: name, inRepository: inRepository),
              kind != .rtfd else { return count(.notADocument) }
        if info.size > FileExclusions.maxBytes { return count(.tooLarge) }
        if !Self.isLocal(info) { return count(.notDownloaded) }
        ready.append(FileCandidate(url: url, kind: kind, size: info.size, modified: info.modified))
    }

    /// An .rtfd package is one document: its size is the sum of the files inside it, its time
    /// the newest of them, and it is local only when every one of them is.
    private mutating func admitPackage(_ url: URL) {
        guard let entries = probe.entries(of: url) else { return count(.unreadable) }
        var size = 0
        var modified = probe.info(url)?.modified ?? 0
        for entry in entries {
            guard let info = probe.info(entry) else { return count(.unreadable) }
            if info.isSymbolicLink { return count(.symlink) }
            if info.isDirectory || !Self.isLocal(info) {
                return count(info.isDirectory ? .notADocument : .notDownloaded)
            }
            size += info.size
            modified = Swift.max(modified, info.modified)
        }
        if size > FileExclusions.maxBytes { return count(.tooLarge) }
        ready.append(FileCandidate(url: url, kind: .rtfd, size: size, modified: modified))
    }

    private static func isLocal(_ info: FileEntryInfo) -> Bool {
        !info.isDataless && (info.cloud == nil || info.cloud == .current)
    }

    private mutating func count(_ rule: FileSkip) {
        skipped[rule, default: 0] += 1
    }

    private static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
