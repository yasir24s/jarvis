import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

// M01 §6 T3: StateStore, core protocols and the state lease. The per-file bytes come from
// m1_state_styles.golden.json, which tools/golden_m1_state.py produces by running Python's
// REAL writers (kb_save, _history_save, …) on synthetic values.

private let epoch: Double = 1790582400

private func rootPath(_ s: Sandbox) -> String {
    var p = s.root.path(percentEncoded: false)
    while p.hasSuffix("/") { p.removeLast() }
    return p
}

private func mode(_ p: String) throws -> mode_t {
    var st = stat()
    try #require(lstat(p, &st) == 0)
    return st.st_mode & 0o7777
}

private func entries(_ dir: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
}

private func text(_ p: String) -> String? {
    FileManager.default.contents(atPath: p).map { String(decoding: $0, as: UTF8.self) }
}

private func setMTime(_ p: String, _ t: Double) throws {
    var times = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
    try #require(lutimes(p, &times) == 0)
}

private func stateFile(_ c: GoldenCase) throws -> StateFile {
    let name = try #require(c.input.string("file"))
    return try #require(StateFile(rawValue: name), "no StateFile for \(name)")
}

/// A temp directory that looks like a real repo root: it has a non-empty jarvis.py and is
/// NOT named like a Sandbox, so StateStore treats it as real state.
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

// MARK: - Per-file write style and round trip, against Python's own writer bytes

@Suite("StateStore bytes vs Python writers (m1_state_styles)")
struct StateStoreGoldenTests {
    static let styleCases: [GoldenCase] = ((try? Golden.cases("m1_state_styles")) ?? [])
        .filter { $0.input.has("value") }

    @Test func fixtureCoversEveryStateFileWithADefiniteStyle() throws {
        let cases = try Golden.cases("m1_state_styles")
        #expect(cases.count == 11)
        var definite: [StateFile: String] = [:]
        for c in Self.styleCases {
            let style = try #require(c.expected.string("style"))
            if style != "either" { definite[try stateFile(c)] = style }
        }
        #expect(Set(definite.keys) == Set(StateFile.allCases))
    }

    /// StateFile.indent is the style Python's writer used for that file.
    @Test(arguments: styleCases)
    func indentMatchesPythonWriter(_ c: GoldenCase) throws {
        let f = try stateFile(c)
        switch try #require(c.expected.string("style")) {
        case "indent1": #expect(f.indent == 1)
        case "compact": #expect(f.indent == nil)
        case "either": break                                  // [] renders the same both ways
        case let other: Issue.record("unknown style \(other)")
        }
    }

    /// save(value) writes exactly the bytes Python's writer wrote for the same value.
    @Test(arguments: styleCases)
    func saveWritesPythonBytes(_ c: GoldenCase) throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let f = try stateFile(c)
        let value = try #require(c.input["value"])
        let expected = try #require(c.expected.string("text"))
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: ManualClock(epoch))
        #expect(store.save(f, value))
        #expect(text(store.path(f)) == expected)
        #expect(PyJSON.dumps(value, indent: f.indent) == expected)
    }

    /// Loading Python's file and saving the unchanged value reproduces it byte for byte.
    @Test(arguments: styleCases)
    func loadThenSaveUnchangedIsByteIdentical(_ c: GoldenCase) throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let f = try stateFile(c)
        let original = Data(try #require(c.expected.string("text")).utf8)
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: ManualClock(epoch))
        try original.write(to: URL(fileURLWithPath: store.path(f)))
        let loaded = try #require(store.load(f))
        #expect(loaded == c.input["value"])
        #expect(store.save(f, loaded))
        #expect(FileManager.default.contents(atPath: store.path(f)) == original)
    }

    /// Unknown keys (consolidated_at, unknown_future_key) keep their place through a
    /// load → append a learned note → save, exactly as personality_load/personality_save do.
    @Test func personalityAppendKeepsUnknownKeys() throws {
        let c = try #require(try Golden.cases("m1_state_styles")
            .first { $0.name == "personality_append_keeps_unknown_keys" })
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: ManualClock(epoch))
        try sb.write("personality.json", try #require(c.input.string("before_text")))
        var p = try #require(store.load(.personality)?.objectValue)
        var learned = try #require(p["learned"]?.arrayValue)
        learned.append(try #require(c.input["append_learned"]))
        p["learned"] = .array(learned)
        #expect(store.save(.personality, .object(p)))
        #expect(try sb.read("personality.json") == c.expected.string("text"))
        #expect(p.keys == ["core", "learned", "consolidated_at", "unknown_future_key"])
    }
}

// MARK: - Store behaviour

@Suite("StateStore (M01 §3.5)")
struct StateStoreTests {
    private static let sample: JSONValue = .object(JSONObject([
        .init(key: "core", value: .array([.string("Synthetic trait.")])),
        .init(key: "learned", value: .array([])),
    ]))

    @Test func pathIsOsPathJoin() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let root = rootPath(sb)
        let plain = try StateStore(root: root, lease: nil)
        let slashed = try StateStore(root: root + "/", lease: nil)
        for f in StateFile.allCases {
            #expect(plain.path(f) == root + "/" + f.rawValue)
            #expect(slashed.path(f) == root + "/" + f.rawValue)
        }
        #expect(slashed.root == root + "/")                    // kept verbatim
    }

    @Test func loadIsJsonLoadOrNil() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil)
        #expect(store.load(.profile) == nil)                                    // missing
        try sb.write("profile.json", "")
        #expect(store.load(.profile) == nil)                                    // empty
        try sb.write("profile.json", "{\"facts\": {}")
        #expect(store.load(.profile) == nil)                                    // torn
        try Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8)).write(to: sb.paths.profile)
        #expect(store.load(.profile) == nil)                                    // BOM
        try Data([0x22, 0xFF, 0x22]).write(to: sb.paths.profile)
        #expect(store.load(.profile) == nil)                                    // not UTF-8
        try sb.write("profile.json", "{\"facts\": {}}")
        #expect(store.load(.profile) == .object(JSONObject([.init(key: "facts", value: .object(JSONObject()))])))
    }

    @Test(arguments: [0o600, 0o640, 0o604] as [mode_t])
    func saveKeepsExistingMode(_ m: mode_t) throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil)
        try sb.write("emotions.json", "{}")
        try #require(chmod(store.path(.emotions), m) == 0)
        #expect(store.save(.emotions, Self.sample))
        #expect(try mode(store.path(.emotions)) == m)
    }

    @Test func saveCreatesNewFileAs0644() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil)
        #expect(store.save(.knowledge, Self.sample))
        #expect(try mode(store.path(.knowledge)) == 0o644)
    }

    @Test func saveWritesThroughSymlink() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil)
        try sb.write("elsewhere/real-personality.json", "old")
        let target = rootPath(sb) + "/elsewhere/real-personality.json"
        try #require(symlink("elsewhere/real-personality.json", store.path(.personality)) == 0)
        #expect(store.save(.personality, Self.sample))
        var st = stat()
        try #require(lstat(store.path(.personality), &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFLNK)                                  // still a link
        #expect(text(target) == PyJSON.dumps(Self.sample, indent: 1))
        #expect(store.load(.personality) == Self.sample)
        #expect(entries(rootPath(sb) + "/elsewhere") == ["real-personality.json"])
    }

    @Test func failedSaveReturnsFalseAndLeavesNoTemp() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil)
        try FileManager.default.createDirectory(atPath: store.path(.alarms),
                                                withIntermediateDirectories: false)
        #expect(store.save(.alarms, .array([])) == false)                        // rename over a dir
        #expect(entries(rootPath(sb)).filter { $0.contains(".jarvis-tmp.") } == [])
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.path(.alarms), isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func initRemovesOnlyStaleTempFilesInRoot() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let root = rootPath(sb)
        let old = ".personality.json.jarvis-tmp.AbCdEfGh"
        let fresh = ".emotions.json.jarvis-tmp.ZyXwVuTs"
        let oldDir = ".knowledge.json.jarvis-tmp.DIRDIRDI"
        let oldLink = ".history.json.jarvis-tmp.LINKLINK"
        let unrelated = ".hidden-old-file"
        for name in [old, fresh, unrelated] { try sb.write(name, "x") }
        try sb.write("research/.usage.json.jarvis-tmp.SUBDIRXX", "x")
        try FileManager.default.createDirectory(atPath: root + "/" + oldDir, withIntermediateDirectories: false)
        try #require(symlink("jarvis.py", root + "/" + oldLink) == 0)
        for name in [old, oldDir, oldLink, unrelated, "research/.usage.json.jarvis-tmp.SUBDIRXX"] {
            try setMTime(root + "/" + name, epoch - 2 * 3600)
        }
        try setMTime(root + "/" + fresh, epoch - 60)

        _ = try StateStore(root: root, lease: nil, clock: ManualClock(epoch))

        let left = entries(root)
        #expect(!left.contains(old))
        #expect(left.contains(fresh))
        #expect(left.contains(oldDir))
        #expect(left.contains(oldLink))
        #expect(left.contains(unrelated))
        #expect(entries(root + "/research") == [".usage.json.jarvis-tmp.SUBDIRXX"])
        // Exactly one hour old is not "older than 1 hour".
        try setMTime(root + "/" + fresh, epoch - 3600)
        #expect(AtomicFile.removeStaleTemps(in: root, olderThan: 3600, now: epoch) == [])
        #expect(AtomicFile.removeStaleTemps(in: root, olderThan: 3600, now: epoch + 1) == [fresh])
    }

    // MARK: Real-state interlock

    @Test func realRepoRootWithoutLeaseThrows() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // M1/
            .deletingLastPathComponent()      // JarvisCoreTests/
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // native/
            .deletingLastPathComponent()      // the repo (this worktree)
            .path(percentEncoded: false)
        try #require(FileManager.default.fileExists(atPath: repo + "jarvis.py"))
        #expect(throws: StateStoreError.realStateNeedsLease) {
            _ = try StateStore(root: repo, lease: nil)
        }
        let released = try { () throws -> InstanceLockLease in
            let r = try RealLikeRoot()
            defer { r.remove() }
            let l = try r.acquireLease()
            l.release()
            return l
        }()
        #expect(throws: StateStoreError.realStateNeedsLease) {
            _ = try StateStore(root: repo, lease: released)
        }
    }

    @Test func realLikeRootNeedsHeldLeaseAndIsUntouchedWithout() throws {
        let r = try RealLikeRoot()
        defer { r.remove() }
        let stale = ".knowledge.json.jarvis-tmp.STALESTA"
        try Data("x".utf8).write(to: URL(fileURLWithPath: r.path + "/" + stale))
        try setMTime(r.path + "/" + stale, epoch - 7200)
        #expect(throws: StateStoreError.realStateNeedsLease) {
            _ = try StateStore(root: r.path, lease: nil, clock: ManualClock(epoch))
        }
        #expect(entries(r.path) == [stale, "jarvis.py"])                        // nothing touched

        let lease = try r.acquireLease()
        #expect(lease.isHeld)
        let store = try StateStore(root: r.path, lease: lease, clock: ManualClock(epoch))
        #expect(!entries(r.path).contains(stale))                              // cleanup ran after the check
        #expect(store.save(.emotions, Self.sample))
        let before = text(store.path(.emotions))

        lease.release()
        #expect(!lease.isHeld)
        #expect(store.save(.emotions, .object(JSONObject())) == false)          // .leaseLost
        #expect(text(store.path(.emotions)) == before)
    }

    @Test func leaseIsLostWhenTheLockFileIsReplaced() throws {
        let r = try RealLikeRoot()
        defer { r.remove() }
        let lease = try r.acquireLease()
        let store = try StateStore(root: r.path, lease: lease)
        #expect(store.save(.history, .array([])))
        try #require(unlink(r.path + "/.jarvis.lock") == 0)
        #expect(!lease.isHeld)                                                 // path gone
        try Data().write(to: URL(fileURLWithPath: r.path + "/.jarvis.lock"))
        #expect(!lease.isHeld)                                                 // a different inode
        #expect(store.save(.history, .array([.null])) == false)
        #expect(text(store.path(.history)) == "[]")
    }

    @Test func sandboxRootNeedsNoLease() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        try #require(FileManager.default.fileExists(atPath: rootPath(sb) + "/jarvis.py"))
        let store = try StateStore(root: rootPath(sb), lease: nil)
        #expect(store.save(.proactive, .object(JSONObject())))
    }

    // MARK: .unreadable backups (decision D-3, M01 §8 R3)

    @Test func unreadableFileIsBackedUpExactlyOnce() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let clock = ManualClock(epoch + 0.75)
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: clock)
        let backups = rootPath(sb) + "/logs/state-backups"
        #expect(store.backupDirectory == backups)
        let torn = Data("{\n \"core\": [\n  \"Synthetic tr".utf8)
        try torn.write(to: sb.paths.personality)

        #expect(store.load(.personality) == nil)
        #expect(entries(backups) == [])                                         // load alone: no copy
        #expect(store.save(.personality, Self.sample))
        let name = "personality.json.1790582400.unreadable"
        #expect(entries(backups) == [name])
        #expect(FileManager.default.contents(atPath: backups + "/" + name) == torn)
        #expect(try sb.read("personality.json") == PyJSON.dumps(Self.sample, indent: 1))

        // A second tear in the same process is overwritten without another backup.
        clock.advance(10)
        try Data("not json".utf8).write(to: sb.paths.personality)
        #expect(store.load(.personality) == nil)
        #expect(store.save(.personality, Self.sample))
        #expect(entries(backups) == [name])
        #expect(FileManager.default.contents(atPath: backups + "/" + name) == torn)
        #expect(store.save(.personality, Self.sample))
        #expect(entries(backups) == [name])
    }

    @Test func backupsArePerFileAndOnlyForNonEmptyUnparseableFiles() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: ManualClock(epoch))
        let backups = rootPath(sb) + "/logs/state-backups"
        try sb.write("emotions.json", "")                                      // empty
        try Data([0x7B, 0xFF, 0x7D]).write(to: sb.paths.knowledge)             // not UTF-8
        try sb.write("corrections.json", "[{")                                 // torn, then fixed
        try sb.write("alarms.json", "[")                                       // torn, never saved
        for f in [StateFile.emotions, .knowledge, .corrections, .alarms, .profile] {
            #expect(store.load(f) == nil)
        }
        try sb.write("corrections.json", "[]")
        #expect(store.load(.corrections) == .array([]))
        for f in [StateFile.emotions, .knowledge, .corrections, .profile] {
            #expect(store.save(f, .object(JSONObject())))
        }
        #expect(entries(backups) == ["knowledge.json.1790582400.unreadable"])
        #expect(FileManager.default.contents(atPath: backups + "/knowledge.json.1790582400.unreadable")
                == Data([0x7B, 0xFF, 0x7D]))
        #expect(try sb.read("alarms.json") == "[")                             // untouched
    }

    @Test func backupRootWithoutLogsDirIsCreated() throws {
        let sb = try Sandbox()
        defer { sb.remove() }
        try FileManager.default.removeItem(at: sb.root.appending(path: "logs"))
        let store = try StateStore(root: rootPath(sb), lease: nil, clock: ManualClock(epoch))
        try sb.write("profile.json", "{")
        #expect(store.load(.profile) == nil)
        #expect(store.save(.profile, .object(JSONObject())))
        #expect(entries(store.backupDirectory) == ["profile.json.1790582400.unreadable"])
    }
}

// MARK: - Protocols

@Suite("Core protocols (M01 §3.6)")
struct CoreProtocolTests {
    @Test func manualClockSetsAndAdvances() {
        let c = ManualClock(epoch)
        #expect(c.now() == epoch)
        c.advance(1.5)
        #expect(c.now() == epoch + 1.5)
        c.set(12.25)
        #expect(c.now() == 12.25)
    }

    @Test func systemClockIsEpochSeconds() {
        let a = Date().timeIntervalSince1970
        let t = SystemClock().now()
        let b = Date().timeIntervalSince1970
        #expect(t >= a - 0.001 && t <= b + 0.001)
    }

    @Test func recordingCounterKeepsBumpOrder() {
        let counter = RecordingCounter()
        let bumper: any ResearchCounting = counter
        bumper.bump("turns", by: 1)
        bumper.bump("tool_calls", by: 2)
        bumper.bump("turns", by: 1)
        #expect(counter.bumps == [.init(key: "turns", n: 1), .init(key: "tool_calls", n: 2),
                                  .init(key: "turns", n: 1)])
        counter.reset()
        #expect(counter.bumps.isEmpty)
    }
}
