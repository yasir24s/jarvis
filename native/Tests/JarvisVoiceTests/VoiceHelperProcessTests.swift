import Foundation
import Testing
@testable import JarvisVoice

/// The real transport, run against /bin/cat and /bin/sleep instead of the helper, and the
/// helper's arguments and install check.
@Suite("M8 VoiceHelperProcess and VoiceHelperSetup")
struct VoiceHelperProcessTests {
    @Test func linesGoInAndComeBackOnePerLine() async throws {
        let cat = try VoiceHelperProcess(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [], log: nil)
        try cat.send(#"{"cmd":"ping"}"#)
        try cat.send("second\u{2028}line")
        var lines: [String] = []
        for await line in cat.lines {
            lines.append(line)
            if lines.count == 2 { break }
        }
        #expect(lines == [#"{"cmd":"ping"}"#, "second\u{2028}line"], "split on \\n only")
        let start = SuspendingClock.now
        await cat.close(grace: .seconds(2))   // EOF: cat exits by itself
        #expect(SuspendingClock.now - start < .seconds(2))
        #expect(throws: (any Error).self) { try cat.send("after close") }
    }

    @Test func closeKillsAHelperThatIgnoresEOFAfterTheGrace() async throws {
        let sleeper = try VoiceHelperProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], log: nil)
        let start = SuspendingClock.now
        await sleeper.close(grace: .milliseconds(200))
        var ended = false
        for await _ in sleeper.lines {}
        ended = true
        #expect(ended)
        #expect(SuspendingClock.now - start < .seconds(5))
    }

    @Test func terminateEndsTheStream() async throws {
        let sleeper = try VoiceHelperProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], log: nil)
        let start = SuspendingClock.now
        sleeper.terminate()
        for await _ in sleeper.lines {}
        #expect(SuspendingClock.now - start < .seconds(5))
    }

    @Test func stderrGoesToTheLog() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let log = folder.url.appending(path: "logs/helper.log")
        let shell = try VoiceHelperProcess(executable: URL(fileURLWithPath: "/bin/sh"),
                                           arguments: ["-c", "echo to-stderr >&2; echo to-stdout"], log: log)
        var lines: [String] = []
        for await line in shell.lines { lines.append(line) }
        #expect(lines == ["to-stdout"])
        #expect(try String(contentsOf: log, encoding: .utf8) == "to-stderr\n")
    }

    @Test func theAppsHelperArgumentsAreD54s() {
        let setup = VoiceHelperSetup.inApp(bundle: .main, log: nil)
        #expect(setup.executable.path(percentEncoded: false).hasSuffix("/Contents/Helpers/jarvis-voice"))
        #expect(setup.assets.path(percentEncoded: false).hasSuffix("/Library/Application Support/JARVIS/voice/"))
        #expect(Array(setup.arguments.suffix(6)) == ["--cache-limit-mb", "512", "--steps", "8", "--idle-exit", "300"])
        #expect(setup.arguments[0] == "--assets")
        #expect(setup.arguments[2] == "--out-dir")
    }

    @Test func installedNeedsTheHelperAndAllSixAssets() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let helper = folder.url.appending(path: "jarvis-voice")
        let assets = folder.url.appending(path: "voice", directoryHint: .isDirectory)
        let setup = VoiceHelperSetup(executable: helper, assets: assets, outDirectory: folder.url.appending(path: "out"), log: nil)
        #expect(!setup.isInstalled())
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path(percentEncoded: false))
        for file in VoiceHelperSetup.assetFiles.dropLast() {
            let url = assets.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        #expect(!setup.isInstalled(), "five of six assets is not installed")
        try Data("x".utf8).write(to: assets.appending(path: VoiceHelperSetup.assetFiles.last!))
        #expect(setup.isInstalled())
    }

    @Test func launchClearsAudioACrashedHelperLeftBehind() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let out = folder.url.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try Data(count: 4).write(to: out.appending(path: "old.f32"))
        try Data("keep".utf8).write(to: out.appending(path: "helper.log"))
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: out, log: nil)
        let helper = try setup.launch()
        for await _ in helper.lines {}
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path(percentEncoded: false))
        #expect(left == ["helper.log"])
    }
}
