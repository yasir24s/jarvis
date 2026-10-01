import Foundation
import JarvisCore
import Synchronization

/// A throwaway "home folder" at temporaryDirectory/jarvis-tests-home-<UUID>/ for the file
/// scanner's tests (D-51 P3). The real home folder is never walked by a test.
public final class TempHome: Sendable {
    public let root: URL

    public init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-tests-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    public func url(_ relative: String) -> URL {
        root.appending(path: relative, directoryHint: .inferFromPath)
    }

    /// Writes UTF-8 `text` at `relative`, creating parent folders.
    @discardableResult
    public func write(_ relative: String, _ text: String = "x") throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    public func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    /// A symlink at `relative` pointing at `destination` (a path, relative or absolute).
    public func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: url(relative).path(percentEncoded: false),
                                                   withDestinationPath: destination)
    }

    /// A sparse file of exactly `bytes` bytes (nothing is written but the length).
    public func sized(_ relative: String, bytes: UInt64) throws {
        let url = try write(relative, "")
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    public func remove() {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .standardizedFileURL.path(percentEncoded: false)
        let own = root.path(percentEncoded: false)
        precondition(own.hasPrefix(tmp.hasSuffix("/") ? tmp : tmp + "/")
                     && root.lastPathComponent.hasPrefix("jarvis-tests-home-"),
                     "TempHome.remove: not a test home under the temporary directory")
        try? FileManager.default.removeItem(at: root)
    }
}

/// The live probe over a temp tree, with resource values overridden per path: what a test
/// cannot make a real file be (dataless, an iCloud item not yet downloaded). It records every
/// folder it was asked to list.
public final class FakeFileProbe: FileSystemProbe, Sendable {
    private let live = LiveFileSystemProbe()
    private let overrides = Mutex<[String: @Sendable (inout FileEntryInfo) -> Void]>([:])
    private let listedPaths = Mutex<[String]>([])

    public init() {}

    public func override(_ url: URL, _ change: @escaping @Sendable (inout FileEntryInfo) -> Void) {
        overrides.withLock { $0[Self.key(url)] = change }
    }

    public func dataless(_ url: URL) {
        override(url) { $0.isDataless = true }
    }

    public func cloud(_ url: URL, _ status: CloudDownload) {
        override(url) { $0.cloud = status }
    }

    /// Every folder listed so far, in order.
    public var listed: [String] { listedPaths.withLock { $0 } }

    public func entries(of directory: URL) -> [URL]? {
        listedPaths.withLock { $0.append(Self.key(directory)) }
        return live.entries(of: directory)
    }

    public func info(_ url: URL) -> FileEntryInfo? {
        guard var info = live.info(url) else { return nil }
        if let change = overrides.withLock({ $0[Self.key(url)] }) { change(&info) }
        return info
    }

    public static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A state lease a test holds or drops by hand.
public final class HandLease: StateLease, Sendable {
    private let held: Mutex<Bool>

    public init(_ held: Bool) {
        self.held = Mutex(held)
    }

    public var isHeld: Bool { held.withLock { $0 } }

    public func set(_ value: Bool) {
        held.withLock { $0 = value }
    }
}
