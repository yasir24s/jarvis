import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

@Suite("AtomicFile")
struct AtomicFileTests {
    private func path(_ s: Sandbox, _ rel: String) -> String {
        s.root.appending(path: rel, directoryHint: .notDirectory).path(percentEncoded: false)
    }

    private func mode(_ p: String) throws -> mode_t {
        var st = stat()
        try #require(lstat(p, &st) == 0)
        return st.st_mode & 0o7777
    }

    private func entries(_ dir: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    }

    @Test func writeCreatesFileWith0644AndLeavesNoTemp() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let target = path(s, "state/emotions.json")
        try FileManager.default.createDirectory(atPath: path(s, "state"), withIntermediateDirectories: true)
        try AtomicFile.write(Data("{}".utf8), to: target)
        #expect(AtomicFile.read(target) == Data("{}".utf8))
        #expect(try mode(target) == 0o644)
        #expect(try entries(path(s, "state")) == ["emotions.json"])
    }

    @Test(arguments: [0o600, 0o640, 0o604] as [mode_t])
    func writePreservesExistingMode(_ m: mode_t) throws {
        let s = try Sandbox()
        defer { s.remove() }
        let target = path(s, "knowledge.json")
        try s.write("knowledge.json", "old")
        try #require(chmod(target, m) == 0)
        try AtomicFile.write(Data("new".utf8), to: target)
        #expect(try s.read("knowledge.json") == "new")
        #expect(try mode(target) == m)
    }

    @Test func writeIntoReadOnlyDirectoryThrowsAndLeavesTargetUnchanged() throws {
        let s = try Sandbox()
        defer {
            chmod(path(s, "ro"), 0o755)
            s.remove()
        }
        try s.write("ro/history.json", "[1]")
        let dir = path(s, "ro"), target = path(s, "ro/history.json")
        var before = stat()
        try #require(stat(target, &before) == 0)
        try #require(chmod(dir, 0o555) == 0)
        #expect(throws: AtomicFileError.self) {
            try AtomicFile.write(Data("[2]".utf8), to: target)
        }
        var after = stat()
        try #require(stat(target, &after) == 0)
        #expect(AtomicFile.read(target) == Data("[1]".utf8))
        #expect(after.st_ino == before.st_ino)
        #expect(try entries(dir) == ["history.json"])            // no temp file left behind
    }

    @Test func writeIntoMissingDirectoryThrows() throws {
        let s = try Sandbox()
        defer { s.remove() }
        #expect(throws: AtomicFileError.self) {
            try AtomicFile.write(Data("x".utf8), to: path(s, "missing/dir/file.json"))
        }
    }

    @Test func writeReplacesInodeAndOverwritesLongerContent() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let target = path(s, "profile.json")
        try s.write("profile.json", String(repeating: "x", count: 4096))
        var before = stat()
        try #require(stat(target, &before) == 0)
        try AtomicFile.write(Data("{}".utf8), to: target)
        var after = stat()
        try #require(stat(target, &after) == 0)
        #expect(try s.read("profile.json") == "{}")              // no stale tail
        #expect(after.st_ino != before.st_ino)                   // renamed, not truncated
        #expect(try entries(s.root.path(percentEncoded: false)).filter { $0.contains("jarvis-tmp") }.isEmpty)
    }

    @Test func writeFollowsSymlinkAndKeepsIt() throws {
        let s = try Sandbox()
        defer { s.remove() }
        try s.write("real/personality.json", "old")
        try #require(chmod(path(s, "real/personality.json"), 0o600) == 0)
        let link = path(s, "personality.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real/personality.json")
        try AtomicFile.write(Data("new".utf8), to: link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "real/personality.json")
        #expect(try s.read("real/personality.json") == "new")
        #expect(try mode(path(s, "real/personality.json")) == 0o600)
        #expect(try entries(path(s, "real")) == ["personality.json"])
    }

    @Test func writeThroughDanglingSymlinkCreatesTarget() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let link = path(s, "alarms.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "alarms.real.json")
        try AtomicFile.write(Data("[]".utf8), to: link)
        #expect(try s.read("alarms.real.json") == "[]")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "alarms.real.json")
    }

    @Test func readReturnsNilForMissingOrDirectory() throws {
        let s = try Sandbox()
        defer { s.remove() }
        #expect(AtomicFile.read(path(s, "nope.json")) == nil)
        #expect(AtomicFile.read(path(s, "research")) == nil)
    }

    @Test func appendLineCreatesAndAppends() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let target = path(s, "research/metrics.jsonl")
        try AtomicFile.appendLine("{\"a\": 1}", to: target)
        try AtomicFile.appendLine("{\"b\": \"\\u00e9 é\"}", to: target)
        #expect(try s.read("research/metrics.jsonl") == "{\"a\": 1}\n{\"b\": \"\\u00e9 é\"}\n")
        // Same mode as a file Python's open(path, "a") creates: 0o666 & ~umask. Measured
        // with a reference file rather than by calling umask() (process-global, racy).
        let ref = path(s, "research/reference")
        let fd = open(ref, O_WRONLY | O_CREAT | O_EXCL, 0o666)
        try #require(fd >= 0)
        close(fd)
        #expect(try mode(target) == mode(ref))
    }

    @Test func appendLineKeepsExistingContentAndMode() throws {
        let s = try Sandbox()
        defer { s.remove() }
        try s.write("jarvis_notes.txt", "[2026-09-27 10:00] first\n")
        let target = path(s, "jarvis_notes.txt")
        try #require(chmod(target, 0o600) == 0)
        try AtomicFile.appendLine("[2026-09-28 09:00] second", to: target)
        #expect(try s.read("jarvis_notes.txt") == "[2026-09-27 10:00] first\n[2026-09-28 09:00] second\n")
        #expect(try mode(target) == 0o600)
    }

    @Test func appendLineIntoReadOnlyDirectoryThrows() throws {
        let s = try Sandbox()
        defer {
            chmod(path(s, "ro"), 0o755)
            s.remove()
        }
        try FileManager.default.createDirectory(atPath: path(s, "ro"), withIntermediateDirectories: true)
        try #require(chmod(path(s, "ro"), 0o555) == 0)
        #expect(throws: AtomicFileError.self) { try AtomicFile.appendLine("x", to: path(s, "ro/new.jsonl")) }
        #expect(try entries(path(s, "ro")).isEmpty)
    }
}
