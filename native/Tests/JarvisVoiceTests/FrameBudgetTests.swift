import Foundation
import Testing
@testable import JarvisVoice

/// V1 part 2: a reply is generated whole, so it must fit F5's 4096 frames, reference included.
/// The app works the frames out by the helper's rule before asking (`F5Engine.tooLong`).
@Suite("V1 F5 frame budget")
struct FrameBudgetTests {
    /// The installed reference: 102,720 samples (4.28 s at 24 kHz) and 65 bytes of text.
    static let samples = 102_720
    static let textBytes = 65

    /// 401 reference frames, plus 401/65 frames a byte over the speed: 600 bytes take 3362 frames
    /// at 1.25, and 748 is the most that fits.
    @Test func sixHundredCharactersFitAt1Point25WithTheInstalledReference() {
        func frames(_ bytes: Int) -> Int {
            VoiceHelperSetup.frames(referenceSamples: Self.samples, referenceTextBytes: Self.textBytes,
                                    textBytes: bytes, speed: 1.25)
        }
        #expect(frames(600) == 3362)
        #expect(frames(748) <= F5Engine.maxFrames)
        #expect(frames(749) > F5Engine.maxFrames)
        #expect(frames(0) == 401)
    }

    /// V1 part 4 stepped the default back to 1.2: 600 bytes take 3485 frames, and 718 is the most
    /// that fits.
    @Test func sixHundredCharactersFitAtTheDefaultSpeed() {
        func frames(_ bytes: Int) -> Int {
            VoiceHelperSetup.frames(referenceSamples: Self.samples, referenceTextBytes: Self.textBytes,
                                    textBytes: bytes, speed: VoiceHelperSetup.defaultSpeed)
        }
        #expect(VoiceHelperSetup.defaultSpeed == 1.2)
        #expect(frames(600) == 3485)
        #expect(frames(718) <= F5Engine.maxFrames)
        #expect(frames(719) > F5Engine.maxFrames)
    }

    @Test func theSetupReadsItsReferenceAndTheEngineNamesWhatDoesNotFit() throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let reference = folder.url.appending(path: "reference", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: reference, withIntermediateDirectories: true)
        let setup = VoiceHelperSetup(executable: URL(fileURLWithPath: "/usr/bin/true"), assets: folder.url,
                                     outDirectory: folder.url, log: nil, speed: 1.25)
        #expect(setup.frames(forSpokenText: "Hello.") == nil, "no reference yet")
        #expect(F5Engine(launcher: setup).tooLong("Hello.") == nil, "unknown: the helper decides")
        try AcknowledgementTests.writeFloatWAV([Float](repeating: 0, count: Self.samples), rate: 24_000,
                                               to: reference.appending(path: "reference.wav"))
        try "But we were friends by that point and he's so lovely to work for.\n"
            .write(to: reference.appending(path: "reference.txt"), atomically: true, encoding: .utf8)
        #expect(setup.frames(forSpokenText: String(repeating: "a", count: 600)) == 3362)
        let f5 = F5Engine(launcher: setup)
        let fits = Array(repeating: "word", count: 120).joined(separator: " ")    // 599 bytes
        let over = Array(repeating: "word", count: 160).joined(separator: " ")    // 799 bytes
        #expect(f5.tooLong(fits) == nil)
        #expect(f5.tooLong(over) == "needs 4344 frames, F5 stops at 4096")
        // Digits are counted as the helper hears them, in words.
        let digits = "It is 3:45."
        #expect(setup.frames(forSpokenText: SpeechNormaliser.spoken(digits))
            == setup.frames(forSpokenText: "It is three forty-five."))
    }
}
