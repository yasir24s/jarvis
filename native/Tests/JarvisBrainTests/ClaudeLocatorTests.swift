import Foundation
import JarvisBrain
import JarvisTestSupport
import Testing

/// ClaudeLocator only inspects files; the stand-in `claude` files here are never run.
@Suite("M3 Claude CLI locator")
struct ClaudeLocatorTests {
    @Test func findsTheFirstExecutableFileOnPath() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let fm = FileManager.default
        var root = s.root.path(percentEncoded: false)
        if root.hasSuffix("/") { root.removeLast() }
        try s.write("a/claude", "not executable\n")                                  // 0644
        try fm.createDirectory(atPath: "\(root)/b/claude", withIntermediateDirectories: true)  // a directory
        for dir in ["c", "d"] {
            try s.write("\(dir)/claude", "stand-in, never run\n")
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(root)/\(dir)/claude")
        }
        let path = ["", "relative/c", "\(root)/a", "\(root)/b", "\(root)/missing", "\(root)/c", "\(root)/d"]
            .joined(separator: ":")
        #expect(ClaudeLocator.find(path: path)?.path(percentEncoded: false) == "\(root)/c/claude")
        #expect(ClaudeLocator.find(path: "\(root)/a:\(root)/b:\(root)/missing") == nil)
        #expect(ClaudeLocator.find(path: "") == nil)
    }

    @Test func notFoundMessageMapsToTheSpokenReason() {
        #expect(ClaudeReason.reason(ClaudeLocator.notFoundMessage) == "Claude Code CLI not found")
    }
}
