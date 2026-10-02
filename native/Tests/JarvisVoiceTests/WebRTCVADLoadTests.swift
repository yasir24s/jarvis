import Foundation
import Testing
@testable import JarvisVoice

/// T0.3 in a checkout: libpystubs, then webrtcvad's extension module, then one 30 ms frame
/// (the bundle half is `JARVIS --selftest-dlopen`). VADGolden checks the flags themselves.
@Suite("M10 webrtcvad dlopen")
struct WebRTCVADLoadTests {
    @Test func loadsAndJudgesOneFrame() throws {
        let vad = try WebRTCVAD(library: try Vendor.webrtcvad(), mode: 3)
        let silence = [Int16](repeating: 0, count: 480)
        #expect(try vad.isSpeech(silence) == false)
        // The self-test's frame: a 200 Hz pulse train, which mode 3 calls speech.
        let voiced = (0 ..< 480).map { n -> Int16 in
            let t = Double(n) / 16000
            let v = (1 ... 15).reduce(0.0) { $0 + sin(2 * .pi * 200 * Double($1) * t) / Double($1) }
            return Int16((v * 4000).rounded())
        }
        #expect(try vad.isSpeech(voiced) == true)
    }

    /// Python raises on a frame that is not 10, 20 or 30 ms; so does the port.
    @Test func rejectsABadFrameLength() throws {
        let vad = try WebRTCVAD(library: try Vendor.webrtcvad(), mode: 3)
        #expect(throws: WebRTCVADError.self) { try vad.isSpeech([Int16](repeating: 0, count: 100)) }
        #expect(throws: WebRTCVADError.self) { try vad.isSpeech([Int16](repeating: 0, count: 480), sampleRate: 11025) }
    }

    @Test func aModeOutOfRangeThrows() throws {
        let library = try Vendor.webrtcvad()
        #expect(throws: WebRTCVADError.self) { try WebRTCVAD(library: library, mode: 4) }
    }

    @Test func aMissingFileIsNamed() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-such-\(UUID().uuidString)")
        #expect(throws: WebRTCVADError.missing(nowhere.appending(path: "libpystubs.dylib").path)) {
            try WebRTCVADLibrary.load(stubs: nowhere.appending(path: "libpystubs.dylib"),
                                      module: nowhere.appending(path: VendoredAssets.webrtcvadFile))
        }
    }

    /// The test helper's own message, which a clean checkout shows until the script has run.
    @Test func theMissingMessageNamesTheScript() {
        let message = Vendor.Missing(files: ["libonnxruntime.1.26.0.dylib"]).description
        #expect(message.contains("scripts/vendor-voice-assets.sh"))
    }

    @Test func flagsCoverWholeFramesOnly() throws {
        let vad = try WebRTCVAD(library: try Vendor.webrtcvad(), mode: 3)
        #expect(try vad.flags([Int16](repeating: 0, count: 1000), frameMs: 30).count == 2)
        #expect(try vad.flags([Int16](repeating: 0, count: 479), frameMs: 30).isEmpty)
    }
}
