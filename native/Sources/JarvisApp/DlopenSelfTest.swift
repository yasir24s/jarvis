import Foundation
import JarvisVoice
import Synchronization

/// `JARVIS --selftest-dlopen [<clip.wav> [<m10_rz_embed.golden.json>]]` (plan: M08-M13 T0.3, and
/// M10 round 2): inside the signed bundle,
/// 1. load libpystubs (RTLD_GLOBAL), then webrtcvad's extension module, and run one 30 ms frame
///    through `WebRtcVad_Create/Init/set_mode(3)/Process`;
/// 2. load ONNX Runtime and resemblyzer.onnx from the bundle and embed a clip: the WAV given
///    (16 kHz mono 16-bit, such as a speaker-corpus fixture), or else 2 s of a voiced pulse train.
///    With the golden file too, the embedding's cosine to Python's for that clip is reported.
/// One JSON line on stdout; exit 0 when every step works (and the cosine, if asked for, is at
/// least 0.999), else 1. Headless: no TCC service, no state, no lock.
enum DlopenSelfTest {
    static let flag = "--selftest-dlopen"

    static func run(bundle: Bundle = .main, arguments: [String] = []) -> Int32 {
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
        if ok { ok = embedding(assets: assets, arguments: arguments, into: &report) }
        report["ok"] = ok
        let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data("{}".utf8)
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return ok ? 0 : 1
    }

    /// Step 2: ORT, the speaker model and one embedding.
    private static func embedding(assets: VendoredAssets, arguments: [String], into report: inout [String: Any]) -> Bool {
        do {
            report["ort_version"] = try OrtRuntime.load(dylib: assets.onnxRuntime).version
            report["model"] = assets.speakerModel.lastPathComponent
            let clipURL = arguments.first.map { URL(fileURLWithPath: $0) }
            let clip = try clipURL.map { try WAVFile.samples($0) } ?? pulseTrain(seconds: 2)
            report["clip"] = clipURL?.lastPathComponent ?? "pulse train, 2 s"
            let embedding = try embed(clip, assets: assets)
            let norm = embedding.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            report["embed_dims"] = embedding.count
            report["embed_norm"] = (norm * 1e6).rounded() / 1e6
            var good = embedding.count == SpeakerEncoder.embeddingSize && abs(norm - 1) < 1e-3
            if let clipURL, arguments.count > 1 {
                let reference = try pythonEmbedding(golden: URL(fileURLWithPath: arguments[1]),
                                                    clip: clipURL.deletingPathExtension().lastPathComponent)
                let cosine = cosine(embedding, reference)
                report["cosine_to_python"] = (cosine * 1e9).rounded() / 1e9
                good = good && cosine >= 0.999
            }
            return good
        } catch {
            report["embed_error"] = String(describing: error)
            return false
        }
    }

    /// The encoder is an actor; the self-test runs on the main thread before the app exists, so
    /// it waits for the embedding on a semaphore.
    private static func embed(_ clip: [Int16], assets: VendoredAssets) throws -> [Float] {
        let encoder = SpeakerEncoder(assets: assets)
        let result = Mutex<Result<[Float], any Error>?>(nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let embedding = try await encoder.embedUtterance(try await encoder.preprocess(clip))
                result.withLock { $0 = .success(embedding) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            done.signal()
        }
        done.wait()
        return try result.withLock { $0 ?? .failure(OrtError.failure("no result")) }.get()
    }

    struct NoReference: Error, CustomStringConvertible {
        let why: String
        var description: String { why }
    }

    /// Python's embedding of the corpus clip `clip` in an m10_rz_embed golden file.
    private static func pythonEmbedding(golden: URL, clip: String) throws -> [Float] {
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: Any]
        let cases = root?["cases"] as? [[String: Any]] ?? []
        let match = cases.first { c in
            let input = c["input"] as? [String: Any] ?? [:]
            return input.count == 1 && input["clip"] as? String == clip
        }
        guard let expected = match?["expected"] as? [String: Any], let b64 = expected["embed_f32"] as? String,
              let data = Data(base64Encoded: b64), data.count == SpeakerEncoder.embeddingSize * 4 else {
            throw NoReference(why: "no Python embedding for \(clip) in \(golden.lastPathComponent)")
        }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map {
            Float(bitPattern: UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24)
        }
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y) }
        return dot / (na.squareRoot() * nb.squareRoot())
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

    /// `frame()` repeated for `seconds`.
    static func pulseTrain(seconds: Int) -> [Int16] {
        let one = frame()
        return Array((0 ..< seconds * 16000 / one.count).map { _ in one }.joined())
    }
}
