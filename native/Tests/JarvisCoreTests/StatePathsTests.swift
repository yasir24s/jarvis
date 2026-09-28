import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

@Suite("StatePaths")
struct StatePathsTests {
    @Test func sandboxPathsResolveInsideSandbox() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let paths = sandbox.paths
        let expected: [(String, URL)] = [
            ("knowledge.json", paths.knowledge),
            ("history.json", paths.history),
            ("corrections.json", paths.corrections),
            ("CHANGELOG.md", paths.changelog),
            ("profile.json", paths.profile),
            ("personality.json", paths.personality),
            ("emotions.json", paths.emotions),
            ("proactive.json", paths.proactive),
            ("alarms.json", paths.alarms),
            ("voiceprint.npy", paths.voiceprint),
            ("research", paths.researchDir),
            ("research/metrics.jsonl", paths.researchMetrics),
            ("research/usage.json", paths.researchUsage),
            ("jarvis_notes.txt", paths.notesFallback),
            ("audd_key.txt", paths.auddKey),
            ("logs/jarvis.log", paths.logFile),
            (".jarvis.lock", paths.lockFile),
            ("jarvis.py", paths.jarvisPy),
        ]
        // Lexical comparison: most of these files do not exist, so symlinks are not resolved.
        let root = lexical(sandbox.root)
        let tmp = lexical(FileManager.default.temporaryDirectory)
        #expect(root.hasPrefix(tmp + "/jarvis-tests-"))
        for (relative, url) in expected {
            #expect(url.isFileURL, "\(relative)")
            #expect(lexical(url) == root + "/" + relative, "\(relative)")
        }
        #expect(paths.researchDir.hasDirectoryPath)
    }

    @Test func sandboxWritesAndReadsInsideRoot() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        try sandbox.write("research/usage.json", "{}\n")
        #expect(try sandbox.read("research/usage.json") == "{}\n")
        #expect(FileManager.default.fileExists(atPath: sandbox.paths.researchUsage.path(percentEncoded: false)))
        sandbox.remove()
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path(percentEncoded: false)))
    }

    @Test func liveThrowsNotInAppBundleUnderTest() {
        #expect(Bundle.main.bundleIdentifier != "com.jarvis.assistant")
        #expect(throws: StatePathsError.notInAppBundle(bundleID: Bundle.main.bundleIdentifier)) {
            try StatePaths.live()
        }
    }

    @Test func liveTripwireWinsOverJarvisHome() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        #expect(throws: StatePathsError.notInAppBundle(bundleID: Bundle.main.bundleIdentifier)) {
            try StatePaths.live(environment: ["JARVIS_HOME": sandbox.root.path(percentEncoded: false)])
        }
    }

    @Test func liveResolvesRepoFromAppBundle() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bundle = try fakeAppBundle(in: sandbox)
        let paths = try StatePaths.live(environment: [:], bundle: bundle)
        #expect(canonical(paths.root) == canonical(sandbox.root))
    }

    @Test func liveUsesJarvisHomeBeforeBundle() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let other = try Sandbox()
        defer { other.remove() }
        let bundle = try fakeAppBundle(in: sandbox)
        let env = ["JARVIS_HOME": other.root.path(percentEncoded: false)]
        let paths = try StatePaths.live(environment: env, bundle: bundle)
        #expect(canonical(paths.root) == canonical(other.root))
    }

    @Test func liveRejectsRootWithoutJarvisPy() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bundle = try fakeAppBundle(in: sandbox)
        try FileManager.default.removeItem(at: sandbox.paths.jarvisPy)
        #expect {
            try StatePaths.live(environment: [:], bundle: bundle)
        } throws: { error in
            guard case StatePathsError.notAJarvisRepo(let url)? = error as? StatePathsError else { return false }
            return canonical(url) == canonical(sandbox.root)
        }
    }

    /// <sandbox>/native/dist/JARVIS.app with the real app's bundle identifier — the only way
    /// to reach the success path of live(), and it resolves back into the sandbox.
    private func fakeAppBundle(in sandbox: Sandbox) throws -> Bundle {
        let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleIdentifier</key><string>com.jarvis.assistant</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            </dict></plist>
            """
        try sandbox.write("native/dist/JARVIS.app/Contents/Info.plist", plist)
        let url = sandbox.root.appending(path: "native/dist/JARVIS.app", directoryHint: .isDirectory)
        return try #require(Bundle(url: url))
    }

    /// For existing directories only (the temporary directory sits behind /var → /private/var).
    private func canonical(_ url: URL) -> String {
        lexical(url.resolvingSymlinksInPath())
    }

    private func lexical(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
