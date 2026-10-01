import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// SayEngine with a fake runner: Python's voice and rate, the AIFF read back at 24 kHz, and the
/// file removed. `/usr/bin/say` never runs here.
@Suite("M8 SayEngine (fake say)")
struct SayEngineTests {
    let folder: TempFolder
    let context = SynthesisContext(turnID: UUID())

    init() throws {
        folder = try TempFolder()
    }

    /// What `say -o` writes: 16-bit big-endian AIFF, 22050 Hz, mono.
    static func writeSayAIFF(_ url: URL, frames: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 22_050.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: true, AVLinearPCMIsFloatKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard frames > 0 else { return }
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<frames { channel[i] = Float(sin(Double(i) * 0.05) * 0.5) }
        try file.write(from: buffer)
    }

    @Test func argumentsArePythonsVoiceAndRate() {
        let out = URL(fileURLWithPath: "/tmp/x.aiff")
        #expect(SayEngine.arguments(text: "-r 1 hello", output: out)
            == ["-v", "Daniel", "-r", "200", "-o", "/tmp/x.aiff", "--", "-r 1 hello"])
    }

    @Test func rendersReadsAt24kAndRemovesTheFile() async throws {
        defer { folder.remove() }
        let seen = Mutex<[[String]]>([])
        let say = SayEngine(directory: folder.url, runner: { arguments in
            seen.withLock { $0.append(arguments) }
            let output = URL(fileURLWithPath: arguments[5])
            try Self.writeSayAIFF(output, frames: 22_050)
        })
        let chunk = try await SpeechQueue.collect(say.synthesize("Good evening, sir.", context: context))
        #expect(chunk.sampleRate == 24_000)
        // One second of 22.05 kHz audio is about 24000 samples at 24 kHz.
        #expect(abs(chunk.samples.count - 24_000) < 600, "\(chunk.samples.count)")
        #expect(chunk.samples.contains { abs($0) > 0.1 })
        let arguments = try #require(seen.withLock { $0.first })
        #expect(Array(arguments.prefix(4)) == ["-v", "Daniel", "-r", "200"])
        #expect(arguments.last == "Good evening, sir.")
        #expect(arguments[5].hasSuffix(".aiff"))
        #expect(folder.files.isEmpty, "the AIFF is deleted once read")
    }

    @Test func aFailingSayThrowsAndLeavesNoFile() async throws {
        defer { folder.remove() }
        let say = SayEngine(directory: folder.url, runner: { arguments in
            try Self.writeSayAIFF(URL(fileURLWithPath: arguments[5]), frames: 100)
            throw SpeechEngineError(.error, "say exited 1")
        })
        await #expect(throws: SpeechEngineError.self) {
            _ = try await SpeechQueue.collect(say.synthesize("Hello.", context: context))
        }
        #expect(folder.files.isEmpty)
    }

    @Test func theRealReaderConvertsAnEmptyFileToNoSamples() throws {
        defer { folder.remove() }
        let url = folder.url.appending(path: "empty.aiff")
        try Self.writeSayAIFF(url, frames: 0)
        #expect(try SayEngine.read24k(url).isEmpty)
    }
}
