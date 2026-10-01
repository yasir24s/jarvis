import Foundation
import JarvisCore
import Testing

/// Live updates (U1): build-app.sh stages its build, and scripts/jarvis-update promotes it with
/// renames only. The script runs here on fake bundles in a temp folder, never on dist/.
@Suite("U1 staged builds and the update script")
struct UpdateScriptTests {
    static let native = AppShellTests.native
    static let script = native.appending(path: "scripts/jarvis-update")

    /// A throwaway folder standing in for native/dist, removed by `remove()`.
    struct FakeDist {
        let root: URL
        var dist: URL { root.appending(path: "dist", directoryHint: .isDirectory) }

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "jarvis-tests-update-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: "dist"), withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func url(_ relative: String) -> URL { dist.appending(path: relative) }

        /// A fake JARVIS.app at `relative` whose executable is a shell script, labelled `name`
        /// inside the bundle; `version` also writes the version.json beside it.
        func bundle(_ relative: String, name: String, version: Bool = true,
                    executable: String = "#!/bin/sh\nexit 0\n") throws {
            let app = url(relative)
            let fm = FileManager.default
            try fm.createDirectory(at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
            try fm.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
            let exe = app.appending(path: "Contents/MacOS/JARVIS")
            try Data(executable.utf8).write(to: exe)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path(percentEncoded: false))
            try Data(name.utf8).write(to: app.appending(path: "Contents/Resources/name"))
            if version {
                try Data(#"{"commit": "\#(name)", "dirty": false, "built": "2026-10-01T00:00:00Z"}"#.utf8)
                    .write(to: app.deletingLastPathComponent().appending(path: "version.json"))
            }
        }

        /// The label of the fake bundle at `relative`, nil if there is none.
        func name(_ relative: String) -> String? {
            try? String(contentsOf: url(relative).appending(path: "Contents/Resources/name"), encoding: .utf8)
        }

        func commit(_ relative: String) -> String? {
            guard let data = try? Data(contentsOf: url(relative)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return object["commit"] as? String
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: url(relative).path(percentEncoded: false))
        }

        func inode(_ relative: String) throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: url(relative).path(percentEncoded: false))
            return try #require(attributes[.systemFileNumber] as? UInt64)
        }

        func entries() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: dist.path(percentEncoded: false)).sorted()
        }
    }

    /// Runs `executable` and waits for it. Output goes to a file, not a pipe, so a detached
    /// grandchild that inherits it cannot keep the test waiting; and the wait is a termination
    /// handler, not `waitUntilExit()` (see InstanceLockTests).
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String] = [:],
                    in folder: URL) throws -> (status: Int32, output: String) {
        let log = folder.appending(path: "run-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        try process.run()
        exited.wait()
        let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return (process.terminationStatus, output)
    }

    @Test("build-app.sh signs into staged/, writes version.json last, and promotes only when the lock is free")
    func buildScriptStages() throws {
        let text = try String(contentsOf: Self.native.appending(path: "scripts/build-app.sh"), encoding: .utf8)
        #expect(text.contains(#"STAGED="$NATIVE/dist/staged""#))
        #expect(!text.contains(#"rm -rf "$APP""#), "the app that may be running is never deleted in place")
        // The bundle's own version.json is sealed by the signature: written before the app is signed.
        let sealed = try #require(text.range(of: #"> "$STAGE/Contents/Resources/version.json""#))
        let signed = try #require(text.range(of: #"--entitlements "$NATIVE/Resources/JARVIS.entitlements" "$STAGE""#))
        #expect(sealed.lowerBound < signed.lowerBound)
        // Staged only after the verified signature; the version.json beside it goes last.
        let verified = try #require(text.range(of: #"codesign --verify --strict "$STAGE" 2>/dev/null"#))
        let moved = try #require(text.range(of: #"mv "$STAGE" "$STAGED/JARVIS.app""#))
        let marker = try #require(text.range(of: #"mv "$STAGED/.version.json.tmp" "$STAGED/version.json""#))
        #expect(verified.lowerBound < moved.lowerBound && moved.lowerBound < marker.lowerBound)
        let cleared = try #require(text.range(of: #"rm -f "$STAGED/version.json"; rm -rf "$STAGED/JARVIS.app""#))
        #expect(cleared.lowerBound < moved.lowerBound, "an old marker never vouches for a new, unfinished stage")
        // The decision: the lock .jarvis.lock, the state root StatePaths.live() uses.
        let probe = try #require(text.range(of: #"if "$NATIVE/scripts/jarvis-update" lock-free "${JARVIS_HOME:-$REPO}/.jarvis.lock"; then"#))
        let promote = try #require(text.range(of: #""$NATIVE/scripts/jarvis-update" promote "$NATIVE/dist""#))
        #expect(marker.lowerBound < probe.lowerBound && probe.lowerBound < promote.lowerBound)
        #expect(text.contains("Built and staged: $STAGED/JARVIS.app$LABEL"))
    }

    @Test("promote: JARVIS.app moves to previous/ and the staged build takes its place, by rename")
    func promoteRenames() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "current")
        try fake.bundle("previous/JARVIS.app", name: "older")
        try fake.bundle("staged/JARVIS.app", name: "new")
        let current = try fake.inode("JARVIS.app"), staged = try fake.inode("staged/JARVIS.app")

        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 0, "\(result.output)")
        #expect(fake.name("JARVIS.app") == "new")
        #expect(fake.commit("version.json") == "new")
        #expect(fake.name("previous/JARVIS.app") == "current")
        #expect(fake.commit("previous/version.json") == "current")
        #expect(!fake.exists("staged/JARVIS.app") && !fake.exists("staged/version.json"))
        // Renames only: the same directories, not copies. The build before last is gone.
        #expect(try fake.inode("JARVIS.app") == staged)
        #expect(try fake.inode("previous/JARVIS.app") == current)
        #expect(try fake.entries() == ["JARVIS.app", "previous", "staged", "version.json"])
    }

    @Test("promote with no current build (the first one) moves the staged build in and makes no previous/")
    func promoteFirstBuild() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("staged/JARVIS.app", name: "first")
        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 0, "\(result.output)")
        #expect(fake.name("JARVIS.app") == "first")
        #expect(fake.commit("version.json") == "first")
        #expect(!fake.exists("previous"))
    }

    @Test("promote refuses a stage without its version.json, and moves nothing")
    func promoteRefusesUnfinishedStage() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        try fake.bundle("JARVIS.app", name: "current")
        try fake.bundle("staged/JARVIS.app", name: "half", version: false)
        let result = try Self.run(Self.script, ["promote", fake.dist.path(percentEncoded: false)], in: fake.root)
        #expect(result.status == 3)
        #expect(result.output.contains("nothing staged"))
        #expect(fake.name("JARVIS.app") == "current")
        #expect(fake.name("staged/JARVIS.app") == "half")
        #expect(!fake.exists("previous"))
    }

    @Test("lock-free: 0 for a missing or free .jarvis.lock, 1 while a JARVIS holds it")
    func lockFree() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        let lockFile = fake.root.appending(path: ".jarvis.lock")
        let path = lockFile.path(percentEncoded: false)
        #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 0)
        #expect(!FileManager.default.fileExists(atPath: path), "the probe never creates the lock file")
        do {
            guard case .acquired(let held) = InstanceLock.tryAcquire(at: lockFile, repoRoot: fake.root) else {
                Issue.record("could not take the test lock")
                return
            }
            #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 1)
            withExtendedLifetime(held) {}
        }
        // Released when the InstanceLock is dropped; the file is still there.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try Self.run(Self.script, ["lock-free", path], in: fake.root).status == 0)
    }

    @Test("jarvis-update without a known command is a usage error")
    func usage() throws {
        let fake = try FakeDist()
        defer { fake.remove() }
        #expect(try Self.run(Self.script, [], in: fake.root).status == 64)
        #expect(try Self.run(Self.script, ["promote"], in: fake.root).status == 64)
        #expect(try Self.run(Self.script, ["unknown", "x"], in: fake.root).status == 64)
    }
}
