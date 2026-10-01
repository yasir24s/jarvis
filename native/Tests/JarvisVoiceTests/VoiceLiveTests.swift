import Foundation
import Testing
@testable import JarvisVoice

/// The one live test: with JARVIS_VOICE_LIVE=1 it runs the real jarvis-voice helper on one line,
/// through the real VoiceHelperProcess and F5Engine. Skipped otherwise, so the default
/// `swift test` never starts the helper or loads a model.
///
/// JARVIS_VOICE_HELPER  the helper (default: VoiceHelper/.build/release/jarvis-voice)
/// JARVIS_VOICE_ASSETS  the assets (default: ~/Library/Application Support/JARVIS/voice)
/// JARVIS_VOICE_LIVE_WAV  if set, the audio is also written there as a WAV, to listen to or transcribe
@Suite("M8 voice live (JARVIS_VOICE_LIVE=1)")
struct VoiceLiveTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_VOICE_LIVE"] == "1"
    static let line = "It's 3:45 PM."

    static var defaultHelper: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "VoiceHelper/.build/release/jarvis-voice", directoryHint: .notDirectory)
    }

    @Test(.enabled(if: VoiceLiveTests.enabled, "set JARVIS_VOICE_LIVE=1 to run the real helper"))
    func theRealHelperSpeaksOneLine() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let setup = VoiceHelperSetup(
            executable: Self.environment["JARVIS_VOICE_HELPER"].map { URL(fileURLWithPath: $0) } ?? Self.defaultHelper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url,
            log: logs.url.appending(path: "jarvis-voice.log"))
        try #require(setup.isInstalled(), "helper \(setup.executable.path) or assets \(setup.assets.path) missing")
        let f5 = F5Engine(launcher: setup)
        let clock = SuspendingClock()
        let start = clock.now
        let chunk = try await SpeechQueue.collect(f5.synthesize(Self.line, context: SynthesisContext(turnID: UUID())))
        let elapsed = clock.now - start
        await f5.release()
        let audio = Double(chunk.samples.count) / chunk.sampleRate
        print("voice live: \"\(Self.line)\" -> \(String(format: "%.2f", audio)) s of audio in \(elapsed); "
              + "helper \(f5.lastFootprintMB.map { "\($0) MB" } ?? "n/a")")
        if let log = try? String(contentsOf: setup.log!, encoding: .utf8) {
            print("voice live: helper stderr:\n\(log)")
        }
        #expect(chunk.sampleRate == 24_000)
        #expect(audio > 0.5, "spelled out, the line needs more than half a second")
        #expect(chunk.samples.contains { abs($0) > 0.05 }, "not silence")
        #expect(out.files.isEmpty, "the helper's PCM file was read and deleted")
        #expect(elapsed < F5Engine.defaultTimeout)
        if let wav = Self.environment["JARVIS_VOICE_LIVE_WAV"] {
            try Self.writeWAV(chunk.samples, to: URL(fileURLWithPath: wav))
        }
    }

    /// 16-bit PCM WAV at 24 kHz.
    static func writeWAV(_ samples: [Float], to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(24_000)); append(UInt32(48_000)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for s in samples { append(Int16((max(-1, min(1, s)) * 32767).rounded())) }
        try data.write(to: url)
    }
}
