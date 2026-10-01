import Foundation

// D-51 P3, piece 1: what the file walk may learn about an entry without opening it. Nothing
// here follows a symlink, reads file content, or asks iCloud for a download.

/// Where an iCloud item's content is.
public enum CloudDownload: Sendable, Equatable {
    case current         // the latest version is on this Mac
    case downloaded      // a local copy exists, but a newer one is in iCloud
    case notDownloaded   // the content is only in iCloud
}

/// One directory entry, as `lstat` and the ubiquitous-item resource values describe it.
public struct FileEntryInfo: Sendable, Equatable {
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    public var isRegularFile: Bool
    public var size: Int              // bytes; 0 for a directory
    public var modified: Double       // epoch seconds
    public var isDataless: Bool       // SF_DATALESS: the content has been evicted to the cloud
    public var cloud: CloudDownload?  // nil when the entry is not an iCloud item

    public init(isDirectory: Bool = false, isSymbolicLink: Bool = false, isRegularFile: Bool = true,
                size: Int = 0, modified: Double = 0, isDataless: Bool = false,
                cloud: CloudDownload? = nil) {
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isRegularFile = isRegularFile
        self.size = size
        self.modified = modified
        self.isDataless = isDataless
        self.cloud = cloud
    }
}

/// The file system as the walk sees it. Tests wrap the live probe over a temp tree and
/// override resource values (a dataless file, an iCloud item not downloaded).
public protocol FileSystemProbe: Sendable {
    /// The entries of `directory`, or nil when it cannot be listed. Never downloads.
    func entries(of directory: URL) -> [URL]?
    /// The entry itself (a symlink is described, not followed), or nil when it is gone.
    func info(_ url: URL) -> FileEntryInfo?
}

public struct LiveFileSystemProbe: FileSystemProbe {
    private static let keys: Set<URLResourceKey> = [.isUbiquitousItemKey,
                                                    .ubiquitousItemDownloadingStatusKey]

    public init() {}

    public func entries(of directory: URL) -> [URL]? {
        NoDownloads.run {
            try? FileManager.default.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: Array(Self.keys),
                                                         options: [])
        }
    }

    public func info(_ url: URL) -> FileEntryInfo? {
        var st = stat()
        guard lstat(url.path(percentEncoded: false), &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        var info = FileEntryInfo(isDirectory: type == S_IFDIR, isSymbolicLink: type == S_IFLNK,
                                 isRegularFile: type == S_IFREG,
                                 size: type == S_IFREG ? Int(st.st_size) : 0, modified: modified,
                                 isDataless: st.st_flags & UInt32(SF_DATALESS) != 0)
        if type != S_IFLNK, let values = try? url.resourceValues(forKeys: Self.keys),
           values.isUbiquitousItem == true {
            switch values.ubiquitousItemDownloadingStatus {
            case .current?: info.cloud = .current
            case .downloaded?: info.cloud = .downloaded
            default: info.cloud = .notDownloaded
            }
        }
        return info
    }
}

/// Runs a synchronous body with this thread's materialisation of dataless files turned off,
/// so touching content that lives only in iCloud fails (EDEADLK) instead of downloading it.
/// It backs up the dataless and download-status checks against a file evicted between the
/// check and the read. The policy is per thread, so `body` must not suspend.
public enum NoDownloads {
    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                           IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer {
            if previous >= 0 {
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD,
                                   previous)
            }
        }
        return try body()
    }
}
