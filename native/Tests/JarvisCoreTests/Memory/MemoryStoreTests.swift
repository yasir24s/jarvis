import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// D-51 P2, piece 1: the memory/ folder. Archive line format and append, the facts file and
// its atomic write, the lease refusal, and the .gitignore / pre-commit guards on memory/.

private let epoch: Double = 1790582400                         // 2026-09-28 08:00:00 UTC
private let utc = TimeZone(identifier: "UTC")!

private func rootPath(_ s: Sandbox) -> String {
    var p = s.root.path(percentEncoded: false)
    while p.hasSuffix("/") { p.removeLast() }
    return p
}

private func bytes(_ p: String) -> Data? { FileManager.default.contents(atPath: p) }

private func memory(_ sb: Sandbox, clock: ManualClock = ManualClock(epoch)) throws -> (StateStore, MemoryStore) {
    let store = try StateStore(root: rootPath(sb), lease: nil, clock: clock)
    return (store, MemoryStore(store: store, clock: clock, timeZone: utc))
}

private func fact(_ id: String, _ text: String, by: FactWriter = .local, at t: Double = epoch) -> MemoryFact {
    MemoryFact(id: id, text: text, source: MemoryFact.conversationSource, created: t, updated: t, by: by)
}

/// A lease the test flips by hand.
private final class FlagLease: StateLease, @unchecked Sendable {
    private let lock = NSLock()
    private var held: Bool
    init(_ held: Bool) { self.held = held }
    var isHeld: Bool { lock.withLock { held } }
    func set(_ h: Bool) { lock.withLock { held = h } }
}

/// A temp directory that looks like a real repo root (a non-empty jarvis.py, not named like a
/// Sandbox), so StateStore treats it as real state and demands the lease.
private final class RealLikeRoot {
    static let prefix = "jarvis-reallike-"
    let path: String

    init() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: RealLikeRoot.prefix + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("# stand-in for jarvis.py\n".utf8)
            .write(to: url.appending(path: "jarvis.py", directoryHint: .notDirectory))
        var p = url.path(percentEncoded: false)
        while p.hasSuffix("/") { p.removeLast() }
        path = p
    }

    func acquireLease() throws -> InstanceLockLease {
        let outcome = InstanceLock.tryAcquire(at: URL(fileURLWithPath: path + "/.jarvis.lock"),
                                              repoRoot: URL(fileURLWithPath: path, isDirectory: true))
        guard case .acquired(let lock) = outcome else {
            Issue.record("could not acquire the lock in \(path): \(outcome)")
            throw CancellationError()
        }
        return InstanceLockLease(lock)
    }

    func remove() {
        precondition(URL(fileURLWithPath: path).lastPathComponent.hasPrefix(RealLikeRoot.prefix))
        try? FileManager.default.removeItem(atPath: path)
    }
}

@Suite("Memory storage (D-51 P2)")
struct MemoryStorageTests {
    @Test func pathsLiveInMemoryUnderTheStateRoot() {
        let paths = StatePaths(root: URL(fileURLWithPath: "/nonexistent/jarvis-root", isDirectory: true))
        #expect(paths.memoryDir.path(percentEncoded: false) == "/nonexistent/jarvis-root/memory/")
        #expect(paths.memoryArchive.path(percentEncoded: false) == "/nonexistent/jarvis-root/memory/archive.jsonl")
        #expect(paths.memoryFacts.path(percentEncoded: false) == "/nonexistent/jarvis-root/memory/facts.json")
    }

    /// The bytes Python's `json.dumps(entry, ensure_ascii=False)` gives for the same entry.
    @Test func archiveLineFormat() {
        let e = ArchiveEntry(timestamp: 1790582400.25, date: "2026-09-28", channel: "voice", role: .user,
                             text: "Line one\nLine \"two\" café — ok")
        #expect(e.line == #"{"timestamp": 1790582400.25, "date": "2026-09-28", "channel": "voice", "role": "user", "text": "Line one\nLine \"two\" café — ok"}"#)
        #expect(!e.line.contains("\n"))
        #expect(ArchiveEntry(line: Data(e.line.utf8)) == e)
    }

    @Test func localDateFollowsTheTimeZone() {
        let t = epoch + 17 * 3600                                  // 2026-09-29 01:00 UTC
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(ArchiveEntry(timestamp: t, timeZone: utc, channel: "text", role: .jarvis, text: "x").date == "2026-09-29")
        #expect(ArchiveEntry(timestamp: t, timeZone: la, channel: "text", role: .jarvis, text: "x").date == "2026-09-28")
    }

    @Test func appendWritesOneLinePerMessageInOrder() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let clock = ManualClock(epoch)
        let (store, mem) = try memory(sb, clock: clock)
        #expect(mem.archive("Remind me about the dentist", role: .user, channel: "voice"))
        clock.set(epoch + 1.5)
        #expect(mem.archive("Certainly, sir.", role: .jarvis, channel: "voice"))
        clock.set(epoch + 60)
        #expect(mem.archive("that's all, JARVIS", role: .user, channel: "text"))

        let text = String(decoding: try #require(bytes(store.path(.archive))), as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 4 && lines.last == "")               // three lines, each ending "\n"
        #expect(lines[1] == #"{"timestamp": 1790582401.5, "date": "2026-09-28", "channel": "voice", "role": "jarvis", "text": "Certainly, sir."}"#)

        let all = mem.archive(after: 0)
        #expect(all.entries.map(\.text) == ["Remind me about the dentist", "Certainly, sir.", "that's all, JARVIS"])
        #expect(all.entries.map(\.role) == [.user, .jarvis, .user])
        #expect(all.entries.map(\.channel) == ["voice", "voice", "text"])
        #expect(all.end == text.utf8.count)

        #expect(mem.archive("Good evening", role: .user, channel: "voice"))
        let next = mem.archive(after: all.end)
        #expect(next.entries.map(\.text) == ["Good evening"])
        #expect(mem.archive(after: next.end).entries.isEmpty)
    }

    @Test func aTornFinalLineIsLeftForNextTime() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (_, mem) = try memory(sb)
        #expect(mem.archive("one", role: .user, channel: "voice"))
        let whole = mem.archive(after: 0).end
        try sb.write("memory/archive.jsonl", try sb.read("memory/archive.jsonl") + #"{"timestamp": 1, "da"#)
        let got = mem.archive(after: 0)
        #expect(got.entries.map(\.text) == ["one"])
        #expect(got.end == whole)
    }

    @Test func anOffsetPastTheEndStartsOverAndForeignLinesAreSkipped() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (_, mem) = try memory(sb)
        try sb.write("memory/archive.jsonl", "not json\n{\"role\": \"user\"}\n")
        #expect(mem.archive("kept", role: .user, channel: "text"))
        let got = mem.archive(after: 1_000_000)
        #expect(got.entries.map(\.text) == ["kept"])
        #expect(mem.archive(after: 0).entries.map(\.text) == ["kept"])

        let empty = try Sandbox()
        defer { empty.remove() }
        let none = MemoryStore(store: try StateStore(root: rootPath(empty), lease: nil)).archive(after: 0)
        #expect(none.entries.isEmpty && none.end == 0)              // no archive at all
    }

    @Test func memoryFolderIsOwnerOnly() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (store, mem) = try memory(sb)
        #expect(mem.archive("x", role: .user, channel: "voice"))
        var st = stat()
        try #require(lstat(rootPath(sb) + "/memory", &st) == 0)
        #expect(st.st_mode & 0o7777 == 0o700)
        #expect(FileManager.default.fileExists(atPath: store.path(.archive)))
    }

    @Test func factsRoundTripInTheirOnDiskFormat() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (store, mem) = try memory(sb)
        #expect(mem.loadFacts() == FactsFile())                    // none yet: empty, not nil
        let file = FactsFile(compiledThrough: 42, facts: [fact("f1", "The user's sister is called Amira.", by: .both)])
        #expect(mem.updateFacts { $0 = file; return true })
        #expect(mem.loadFacts() == file)
        let text = String(decoding: try #require(bytes(store.path(.facts))), as: UTF8.self)
        #expect(text == """
        {
         "compiled_through": 42,
         "facts": [
          {
           "id": "f1",
           "text": "The user's sister is called Amira.",
           "source": "conversation",
           "created": 1790582400.0,
           "updated": 1790582400.0,
           "by": "both"
          }
         ]
        }
        """)
    }

    @Test func declinedUpdateWritesNothing() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (store, mem) = try memory(sb)
        #expect(!mem.updateFacts { $0.facts.append(fact("f1", "x")); return false })
        #expect(!FileManager.default.fileExists(atPath: store.path(.facts)))
    }

    /// The write is temp file + rename: the old file is replaced whole (a new inode), no temp is
    /// left behind, and a failed write leaves the old bytes exactly as they were.
    @Test func factsWriteIsAtomic() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (store, mem) = try memory(sb)
        #expect(mem.updateFacts { $0.facts = [fact("f1", "one")]; return true })
        var before = stat()
        try #require(lstat(store.path(.facts), &before) == 0)
        #expect(mem.updateFacts { $0.facts.append(fact("f2", "two")); return true })
        var after = stat()
        try #require(lstat(store.path(.facts), &after) == 0)
        #expect(before.st_ino != after.st_ino)
        let dir = rootPath(sb) + "/memory"
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["facts.json"])

        let good = try #require(bytes(store.path(.facts)))
        try #require(chmod(dir, 0o500) == 0)                     // mkstemp in memory/ now fails
        defer { chmod(dir, 0o700) }
        #expect(!mem.updateFacts { $0.facts.append(fact("f3", "three")); return true })
        #expect(bytes(store.path(.facts)) == good)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["facts.json"])
    }

    @Test func anUnreadableFactsFileIsNeverOverwritten() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let (store, mem) = try memory(sb)
        try sb.write("memory/facts.json", "{\"facts\": [tor")
        #expect(mem.loadFacts() == nil)
        #expect(!mem.updateFacts { $0.facts = [fact("f1", "x")]; return true })
        #expect(bytes(store.path(.facts)) == Data("{\"facts\": [tor".utf8))
    }

    /// Nothing is written without the lease: a real-like root refuses once the lease is gone,
    /// and a given lease that is not held refuses before memory/ even exists.
    @Test func writesAreRefusedWithoutTheLease() throws {
        let r = try RealLikeRoot()
        defer { r.remove() }
        let lease = try r.acquireLease()
        let store = try StateStore(root: r.path, lease: lease, clock: ManualClock(epoch))
        let mem = MemoryStore(store: store, clock: ManualClock(epoch), timeZone: utc)
        #expect(mem.archive("held", role: .user, channel: "voice"))
        #expect(mem.updateFacts { $0.facts = [fact("f1", "one")]; return true })
        let archive = bytes(store.path(.archive)), facts = bytes(store.path(.facts))

        lease.release()
        #expect(!lease.isHeld)
        #expect(!mem.archive("released", role: .user, channel: "voice"))
        #expect(!mem.updateFacts { $0.facts = []; return true })
        #expect(!store.appendLine("raw", to: .archive))
        #expect(!store.write(Data("{}".utf8), to: .facts))
        #expect(bytes(store.path(.archive)) == archive)
        #expect(bytes(store.path(.facts)) == facts)

        let sb = try Sandbox()
        defer { sb.remove() }
        let flag = FlagLease(false)
        let given = try StateStore(root: rootPath(sb), lease: flag)
        let refused = MemoryStore(store: given, clock: ManualClock(epoch), timeZone: utc)
        #expect(!refused.archive("x", role: .user, channel: "voice"))
        #expect(!refused.updateFacts { $0.facts = [fact("f1", "x")]; return true })
        #expect(!FileManager.default.fileExists(atPath: rootPath(sb) + "/memory"))
        flag.set(true)
        #expect(refused.archive("x", role: .user, channel: "voice"))
    }
}

// MARK: - memory/ is never committed

/// The repo's own .gitignore and .githooks/pre-commit, run against a throwaway git repo.
@Suite("memory/ is never committed (D-51 P2)")
struct MemoryNeverCommittedTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Memory
        .deletingLastPathComponent()   // JarvisCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // native
        .deletingLastPathComponent()   // repo

    private static func run(_ args: [String], in dir: URL, home: URL) throws -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = args
        p.currentDirectoryURL = dir
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": home.path(percentEncoded: false),
                         "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    /// A fresh repo holding copies of the real .gitignore and hook, with ignorecase on (as the
    /// real checkout has it), plus a memory/ file and a native source file under .../Memory/.
    private static func scratchRepo(_ sb: Sandbox) throws -> URL {
        let repo = sb.root.appending(path: "repo", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        #expect(try run(["git", "-c", "init.defaultBranch=main", "init", "-q"], in: repo, home: sb.root).status == 0)
        #expect(try run(["git", "config", "core.ignorecase", "true"], in: repo, home: sb.root).status == 0)
        let hooks = repo.appending(path: ".githooks", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: repoRoot.appending(path: ".githooks/pre-commit"),
                                         to: hooks.appending(path: "pre-commit"))
        try FileManager.default.copyItem(at: repoRoot.appending(path: ".gitignore"),
                                         to: repo.appending(path: ".gitignore"))
        for relative in ["memory/facts.json", "memory/archive.jsonl",
                         "native/Sources/JarvisCore/Memory/MemoryStore.swift"] {
            let url = repo.appending(path: relative, directoryHint: .notDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: url)
        }
        return repo
    }

    @Test func gitignoreHidesMemoryButNotTheMemorySources() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let repo = try Self.scratchRepo(sb)
        let ignored = try Self.run(["git", "check-ignore", "memory/facts.json", "memory/archive.jsonl"],
                                   in: repo, home: sb.root)
        #expect(ignored.status == 0)
        #expect(ignored.out == "memory/facts.json\nmemory/archive.jsonl\n")
        let source = try Self.run(["git", "check-ignore", "native/Sources/JarvisCore/Memory/MemoryStore.swift"],
                                  in: repo, home: sb.root)
        #expect(source.status == 1)                                 // not ignored
    }

    @Test func preCommitBlocksAStagedMemoryFile() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let repo = try Self.scratchRepo(sb)
        #expect(try Self.run(["git", "add", "-f", "memory/facts.json"], in: repo, home: sb.root).status == 0)
        let blocked = try Self.run(["bash", ".githooks/pre-commit"], in: repo, home: sb.root)
        #expect(blocked.status == 1)
        #expect(blocked.out.contains("BLOCK  sensitive path staged: memory/facts.json"))

        #expect(try Self.run(["git", "rm", "-q", "--cached", "memory/facts.json"], in: repo, home: sb.root).status == 0)
        #expect(try Self.run(["git", "add", "native/Sources/JarvisCore/Memory/MemoryStore.swift"],
                             in: repo, home: sb.root).status == 0)
        let clean = try Self.run(["bash", ".githooks/pre-commit"], in: repo, home: sb.root)
        #expect(clean.status == 0, "\(clean.out)")
    }
}
