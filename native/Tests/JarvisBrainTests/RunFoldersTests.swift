import Foundation
import JarvisBrain
import Testing

/// Per-root `run/` and `claude-cwd/` folders (M4 C2 item 4). Paths are only computed here;
/// nothing is created. The SHA-256 prefixes were computed with `shasum -a 256`.
@Suite("M4 per-root run folders (plan 3.6, 3.7)")
struct RunFoldersTests {
    static let support = URL(filePath: "/tmp/support/JARVIS", directoryHint: .isDirectory)
    static let home = URL(filePath: "/tmp/jarvis-home-a", directoryHint: .isDirectory)
    static let other = URL(filePath: "/Volumes/Shared/jarvis-home-b", directoryHint: .isDirectory)

    @Test("the default root keeps today's run/ and claude-cwd/, trailing slash or not")
    func defaultRootKeepsTodaysPaths() {
        for root in [Self.home, URL(filePath: "/tmp/jarvis-home-a/"), URL(filePath: "/tmp/jarvis-home-a")] {
            let folders = RunFolders(stateRoot: root, defaultRoot: Self.home, support: Self.support)
            #expect(folders.run.path(percentEncoded: false) == "/tmp/support/JARVIS/run/")
            #expect(folders.claudeWorkingDirectory.path(percentEncoded: false) == "/tmp/support/JARVIS/claude-cwd/")
            #expect(folders.socketPath == "/tmp/support/JARVIS/run/mcp.sock")
        }
    }

    @Test("any other root gets run-<8 hex of sha256(root path)> and the same suffix on claude-cwd")
    func otherRootsGetASuffix() {
        #expect(RunFolders.suffix(for: Self.home) == "c55d855f")
        #expect(RunFolders.suffix(for: Self.other) == "3d7c6daa")
        #expect(RunFolders.suffix(for: URL(filePath: "/Volumes/Shared/jarvis-home-b/")) == "3d7c6daa")
        let folders = RunFolders(stateRoot: Self.other, defaultRoot: Self.home, support: Self.support)
        #expect(folders.run.path(percentEncoded: false) == "/tmp/support/JARVIS/run-3d7c6daa/")
        #expect(folders.claudeWorkingDirectory.path(percentEncoded: false) == "/tmp/support/JARVIS/claude-cwd-3d7c6daa/")
        // With no default root (the bundle is not inside a JARVIS repo), every root is hashed.
        let noDefault = RunFolders(stateRoot: Self.home, defaultRoot: nil, support: Self.support)
        #expect(noDefault.run.lastPathComponent == "run-c55d855f")
        #expect(noDefault.claudeWorkingDirectory.lastPathComponent == "claude-cwd-c55d855f")
    }

    @Test("B2: codex-cwd sits beside claude-cwd, with the same suffix")
    func codexWorkingDirectory() {
        let plain = RunFolders(stateRoot: Self.home, defaultRoot: Self.home, support: Self.support)
        #expect(plain.codexWorkingDirectory.path(percentEncoded: false) == "/tmp/support/JARVIS/codex-cwd/")
        let other = RunFolders(stateRoot: Self.other, defaultRoot: Self.home, support: Self.support)
        #expect(other.codexWorkingDirectory.path(percentEncoded: false) == "/tmp/support/JARVIS/codex-cwd-3d7c6daa/")
        #expect(other.codexWorkingDirectory != other.claudeWorkingDirectory)
    }

    @Test("two roots never share a socket")
    func rootsDoNotShare() {
        let a = RunFolders(stateRoot: Self.home, defaultRoot: nil, support: Self.support)
        let b = RunFolders(stateRoot: Self.other, defaultRoot: nil, support: Self.support)
        #expect(a.socketPath != b.socketPath)
        #expect(a.claudeWorkingDirectory != b.claudeWorkingDirectory)
    }

    @Test("socket paths stay under sun_path's 104 bytes in the real Application Support, however long the root")
    func socketPathsFit() {
        let support = BrainAssembly.supportDirectory
        let long = URL(filePath: "/tmp/" + String(repeating: "deep/", count: 80) + "jarvis-home", directoryHint: .isDirectory)
        let defaultFolders = RunFolders(stateRoot: Self.home, defaultRoot: Self.home, support: support)
        let shortFolders = RunFolders(stateRoot: Self.home, defaultRoot: nil, support: support)
        let longFolders = RunFolders(stateRoot: long, defaultRoot: nil, support: support)
        #expect(MCPSocket.sunPathSize == 104)
        for folders in [defaultFolders, shortFolders, longFolders] {
            #expect(folders.socketPathFits)
            #expect(folders.socketPath.utf8.count < 104)
        }
        #expect(longFolders.socketPath.utf8.count == shortFolders.socketPath.utf8.count)
        #expect(shortFolders.socketPath.utf8.count == defaultFolders.socketPath.utf8.count + 9)
    }
}
