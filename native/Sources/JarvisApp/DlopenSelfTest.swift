import Foundation
import JarvisVoice

/// `JARVIS --selftest-dlopen` (plan: M08-M13 T0.3): inside the signed bundle, load
/// libpystubs (RTLD_GLOBAL), then webrtcvad's extension module, and run one 30 ms frame
/// through `WebRtcVad_Create/Init/set_mode(3)/Process`. One JSON line on stdout; exit 0 when
/// both load and Process returns 0 or 1, else 1. Headless: no TCC service, no state, no lock.
enum DlopenSelfTest {
    static let flag = "--selftest-dlopen"

    static func run(bundle: Bundle = .main) -> Int32 {
        let assets = VendoredAssets.appBundle(bundle)
        var report: [String: Any] = [
            "pystubs": assets.pyStubs.lastPathComponent,
            "webrtcvad": assets.webrtcvad.lastPathComponent,
        ]
        var ok = false
        do {
            let library = try WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad)
            report["loaded"] = true
            let vad = try WebRTCVAD(library: library, mode: 3)
            let speech = try vad.isSpeech(frame())
            report["vad_30ms"] = speech ? 1 : 0
            ok = true
        } catch {
            report["error"] = String(describing: error)
        }
        report["ok"] = ok
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return ok ? 0 : 1
    }

    /// 480 samples (30 ms at 16 kHz) of a 200 Hz pulse train with harmonics up to 3 kHz, at
    /// about -12 dBFS: speech-like, so mode 3 has something to judge. Deterministic.
    static func frame() -> [Int16] {
        (0 ..< 480).map { n in
            let t = Double(n) / 16000
            let v = (1 ... 15).reduce(0.0) { $0 + sin(2 * .pi * 200 * Double($1) * t) / Double($1) }
            return Int16((v * 4000).rounded())
        }
    }
}
