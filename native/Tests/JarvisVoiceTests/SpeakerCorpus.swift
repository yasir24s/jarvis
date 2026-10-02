import CryptoKit
import Foundation
import JarvisCore
import Synchronization
@testable import JarvisVoice

/// The M10 speaker corpus (Tests/Fixtures/golden/voice/speaker: synthetic `say` voices) and the
/// helpers the speaker golden tests share. Inputs are rebuilt from a golden case's `input`
/// exactly as tools/golden_m10_speaker.py builds them.
enum SpeakerCorpus {
    static let folder: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // JarvisVoiceTests/
        .deletingLastPathComponent()        // Tests/
        .appending(path: "Fixtures/golden/voice/speaker", directoryHint: .isDirectory)

    struct BadWAV: Error, CustomStringConvertible {
        let why: String
        var description: String { "speaker corpus: \(why)" }
    }

    /// A corpus clip's samples (16 kHz mono 16-bit), read with the app's own WAVFile.
    static func samples(_ clip: String) throws -> [Int16] {
        try WAVFile.samples(folder.appending(path: "\(clip).wav"))
    }

    /// The input a golden case names: {"clip"} with an optional "shift" (pcm >> k) and "stop"
    /// (pcm[:stop]), or {"silence": n}.
    static func input(_ spec: JSONObject) throws -> [Int16] {
        if let n = spec.int("silence") { return [Int16](repeating: 0, count: Int(n)) }
        guard let clip = spec.string("clip") else { throw BadWAV(why: "a case names no clip") }
        var pcm = try samples(clip)
        if let k = spec.int("shift") { pcm = pcm.map { $0 >> Int16(k) } }
        if let stop = spec.int("stop") { pcm = Array(pcm.prefix(Int(stop))) }
        return pcm
    }

    /// base64 of little-endian float32 bytes.
    static func f32(_ text: String?) -> [Float]? {
        guard let text, let data = Data(base64Encoded: text), data.count % 4 == 0 else { return nil }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 4).map {
            Float(bitPattern: UInt32(bytes[$0]) | UInt32(bytes[$0 + 1]) << 8 | UInt32(bytes[$0 + 2]) << 16 | UInt32(bytes[$0 + 3]) << 24)
        }
    }

    /// SHA-256 of the little-endian float32 bytes, as the suite hashes numpy arrays.
    static func sha256(_ values: [Float]) -> String {
        var data = Data(capacity: values.count * 4)
        for v in values {
            let b = v.bitPattern
            data.append(contentsOf: [UInt8(b & 0xFF), UInt8(b >> 8 & 0xFF), UInt8(b >> 16 & 0xFF), UInt8(b >> 24)])
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func bits(_ flags: [Bool]) -> String { String(flags.map { $0 ? "1" : "0" }) }

    /// max |a - b| over the shorter length; NaN when either has a NaN where the other has not.
    static func maxDelta(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { worst, p in
            if p.0.isNaN && p.1.isNaN { return worst }
            return max(worst, abs(p.0 - p.1))
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += Double(x) * Double(y); na += Double(x) * Double(x); nb += Double(y) * Double(y) }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// A fresh encoder over this checkout's vendored binaries.
    static func encoder(idleRelease: Duration = SpeakerEncoder.defaultIdleRelease,
                        log: @escaping @Sendable (String) -> Void = { _ in }) throws -> SpeakerEncoder {
        let assets = try Vendor.assets(needing: [\.onnxRuntime, \.pyStubs, \.webrtcvad, \.speakerModel])
        return SpeakerEncoder(assets: assets, idleRelease: idleRelease, log: log)
    }

    private static let shared = Mutex<SpeakerEncoder?>(nil)

    /// The one encoder the embedding tests share. It is an actor, so their preprocessing, mel
    /// and ORT work runs one call at a time on one thread, and leaves the rest of the
    /// cooperative pool to the timing-sensitive M8 tests in this target (full runs at load ~15
    /// starved them when every case had its own encoder).
    static func sharedEncoder() throws -> SpeakerEncoder {
        let made = try encoder()
        return shared.withLock { cached in
            if let cached { return cached }
            cached = made
            return made
        }
    }
}

/// Research counters bumped, in order.
final class BumpRecorder: ResearchCounting, Sendable {
    private let keys = Mutex<[String]>([])
    func bump(_ key: String, by n: Int) { keys.withLock { $0.append(contentsOf: Array(repeating: key, count: n)) } }
    var bumped: [String] { keys.withLock { $0 } }
}

/// Log lines, in order.
final class LogRecorder: Sendable {
    private let lines = Mutex<[String]>([])
    var sink: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }
    var logged: [String] { lines.withLock { $0 } }
}
