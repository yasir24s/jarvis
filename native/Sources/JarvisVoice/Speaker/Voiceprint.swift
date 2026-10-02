import Accelerate
import Foundation
import JarvisCore

/// voiceprint.npy as numpy writes and reads it (plan: M08-M13 §3.5): NPY format 1.0, a
/// 128-byte header (`{'descr': '<f4', 'fortran_order': False, 'shape': (256,), }`, padded with
/// spaces to a multiple of 64 and ending in a newline), then 256 little-endian float32.
public enum NPYVector {
    public enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case notNPY
        case unsupportedVersion(UInt8, UInt8)
        case badHeader(String)
        case truncated(expected: Int, got: Int)

        public var description: String {
            switch self {
            case .notNPY: return "not an NPY file"
            case let .unsupportedVersion(major, minor): return "NPY version \(major).\(minor) is not 1.0"
            case let .badHeader(why): return "NPY header: \(why)"
            case let .truncated(expected, got): return "NPY data: expected \(expected) bytes, got \(got)"
            }
        }
    }

    static let magic: [UInt8] = [0x93] + Array("NUMPY".utf8)

    /// `np.load` of a 1-D little-endian float32 array in C order, of `count` values.
    public static func decode(_ data: Data, count: Int = SpeakerEncoder.embeddingSize) throws -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, Array(bytes[0 ..< 6]) == magic else { throw Error.notNPY }
        guard bytes[6] == 1, bytes[7] == 0 else { throw Error.unsupportedVersion(bytes[6], bytes[7]) }
        let headerLength = Int(bytes[8]) | Int(bytes[9]) << 8
        guard bytes.count >= 10 + headerLength,
              let header = String(bytes: bytes[10 ..< 10 + headerLength], encoding: .isoLatin1) else {
            throw Error.badHeader("shorter than its length field")
        }
        let fields = try parseHeader(header)
        guard fields["descr"] == "'<f4'" else { throw Error.badHeader("descr is \(fields["descr"] ?? "missing"), not '<f4'") }
        guard fields["fortran_order"] == "False" else { throw Error.badHeader("fortran_order is not False") }
        guard fields["shape"] == "(\(count),)" else { throw Error.badHeader("shape is \(fields["shape"] ?? "missing"), not (\(count),)") }
        let body = bytes.count - 10 - headerLength
        guard body >= count * 4 else { throw Error.truncated(expected: count * 4, got: body) }
        let start = 10 + headerLength
        return (0 ..< count).map { i in
            let o = start + i * 4
            let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
            return Float(bitPattern: bits)
        }
    }

    /// The header dict's three keys, as their literal text: "'<f4'", "False", "(256,)".
    static func parseHeader(_ header: String) throws -> [String: String] {
        var text = Substring(header.trimmingCharacters(in: .whitespacesAndNewlines))
        guard text.first == "{", text.last == "}" else { throw Error.badHeader("not a dict") }
        text = text.dropFirst().dropLast()
        var fields: [String: String] = [:]
        for key in ["descr", "fortran_order", "shape"] {
            guard let range = text.range(of: "'\(key)':") else { throw Error.badHeader("no \(key)") }
            var value = text[range.upperBound...].drop { $0 == " " }
            if value.first == "(" {
                guard let close = value.firstIndex(of: ")") else { throw Error.badHeader("open shape") }
                value = value[...close]
            } else {
                value = value.prefix { $0 != "," }
            }
            fields[key] = value.replacingOccurrences(of: " ", with: "")
        }
        return fields
    }

    /// The bytes `np.save` writes for a 1-D float32 array: numpy's _write_array_header (the
    /// sorted keys, room for 21 shape digits, padded to a multiple of 64, a final newline).
    public static func encode(_ values: [Float]) -> Data {
        var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(values.count),), }"
        header += String(repeating: " ", count: 21 - String(values.count).count)
        let used = magic.count + 2 + 2 + header.utf8.count + 1
        let pad = (64 - used % 64) % 64
        header += String(repeating: " ", count: pad) + "\n"
        var out = Data(magic + [1, 0])
        let length = UInt16(header.utf8.count)
        out.append(contentsOf: [UInt8(length & 0xFF), UInt8(length >> 8)])
        out.append(contentsOf: Array(header.utf8))
        for v in values {
            let bits = v.bitPattern
            out.append(contentsOf: [UInt8(bits & 0xFF), UInt8(bits >> 8 & 0xFF), UInt8(bits >> 16 & 0xFF), UInt8(bits >> 24)])
        }
        return out
    }
}

/// The enrolled speaker (plan: M08-M13 §3.5, T10.3): jarvis.py's `_voiceprint` and the functions
/// around it, `_load_voiceprint`, `speaker_ok`, `_barge_in_speaker_match`, `enroll_voice` (once
/// the takes are recorded) and `forget_voice` (J:680-689, 5150-5263).
///
/// `speakerOK` fails open, as Python's does: no voiceprint, the gate off, a clip too short to
/// judge or any embedding error all accept. `matchesForBargeIn` fails closed: the same cases
/// all refuse. Both compare with speaker_ok's float32 cosine (`+ 1e-9` on the norms).
public actor Voiceprint {
    /// SPEAKER_THRESHOLD and WAKE_SPK_THRESHOLD, Python's defaults.
    public static let threshold = 0.60
    public static let wakeThreshold = 0.38
    /// enroll_voice keeps a take only when its preprocessed length is over 16000 * 0.8.
    public static let minimumTake = 12800

    /// The lines enroll_voice and forget_voice speak or return (golden-checked).
    public enum Lines {
        public static let notReady = "Voice recognition isn't ready yet, sir."
        public static let starting = "Setting up voice recognition, sir. Please speak naturally for about twelve seconds — tell me about your day, or read something aloud."
        public static let nothingCaptured = "I couldn't capture your voice clearly, sir. We can try again later."
        public static let set = "Voice recognition is set, sir. I'll now respond only to you."
        public static let cleared = "Voice recognition cleared, sir. I'll respond to any voice now."
    }

    public enum EnrollOutcome: Equatable, Sendable {
        /// Saved from this many of the takes.
        case saved(takes: Int)
        /// No take was long enough after preprocessing; nothing was saved.
        case nothingCaptured
    }

    public let url: URL
    private let encoder: SpeakerEncoder
    private let research: any ResearchCounting
    private let log: @Sendable (String) -> Void
    public let speakerThreshold: Double
    private(set) var vector: [Float]?
    /// `_spk_enabled`: off, speakerOK accepts everything (barge-in is not affected, as in Python).
    public var enabled = true

    public init(url: URL, encoder: SpeakerEncoder, research: any ResearchCounting,
                speakerThreshold: Double = Voiceprint.threshold, log: @escaping @Sendable (String) -> Void) {
        self.url = url
        self.encoder = encoder
        self.research = research
        self.speakerThreshold = speakerThreshold
        self.log = log
    }

    public var isEnrolled: Bool { vector != nil }
    public var current: [Float]? { vector }
    public func setEnabled(_ on: Bool) { enabled = on }

    /// `_load_voiceprint()`: load the file if it exists; a bad file is logged and ignored.
    public func load() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            vector = try NPYVector.decode(Data(contentsOf: url))
            log("Voiceprint loaded — responding only to the enrolled voice (thr \(speakerThreshold)).")
        } catch {
            log("Voiceprint load failed: \(error)")
        }
    }

    /// `speaker_ok(audio, threshold)`: true to accept the clip.
    public func speakerOK(_ clip: [Int16], threshold: Double? = nil) async -> Bool {
        guard let vector, enabled else { return true }
        guard let embedding = await encoder.embed(clip) else { return true }
        let thr = threshold ?? speakerThreshold
        let sim = Double(Self.cosine(embedding, vector))
        if sim < thr {
            log("(ignored — voice match \(Self.twoPlaces(sim)) < \(thr))")
            research.bump(ResearchKey.speakerReject, by: 1)
            return false
        }
        log("Speaker match \(Self.twoPlaces(sim)) >= \(thr)")
        research.bump(ResearchKey.speakerPass, by: 1)
        return true
    }

    /// `_barge_in_speaker_match(raw_pcm)`: true only for a clip that matches the voiceprint.
    public func matchesForBargeIn(_ clip: [Int16]) async -> Bool {
        guard let vector else { return false }
        guard let embedding = await encoder.embed(clip) else { return false }
        return Double(Self.cosine(embedding, vector)) >= speakerThreshold
    }

    /// enroll_voice after the takes are recorded (three `record(duration=4)` calls in Python):
    /// preprocess each take, keep those over 12800 samples, embed them, average, normalise with
    /// `+ 1e-9`, and save atomically. Throws, saving nothing, when the encoder cannot load
    /// (Python then says `Lines.notReady`) or the file cannot be written.
    public func enroll(takes: [[Int16]]) async throws -> EnrollOutcome {
        try await encoder.prepare()
        var embeddings: [[Float]] = []
        for (i, take) in takes.enumerated() {
            do {
                let pre = try await encoder.preprocess(take)
                if pre.count > Self.minimumTake { embeddings.append(try await encoder.embedUtterance(pre)) }
            } catch {
                log("enroll seg \(i): \(error)")
            }
        }
        guard !embeddings.isEmpty else { return .nothingCaptured }
        let print = Self.enrolled(embeddings)
        try Self.save(print, to: url)
        vector = print
        log("Voiceprint enrolled and saved.")
        return .saved(takes: embeddings.count)
    }

    /// `forget_voice()`: delete the file (errors ignored) and forget the voiceprint.
    @discardableResult
    public func forget() -> String {
        try? FileManager.default.removeItem(at: url)
        vector = nil
        return Lines.cleared
    }

    // MARK: arithmetic, as numpy does it in float32

    /// `np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-9)`.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let na = SpeakerEncoder.dot(a, a).squareRoot(), nb = SpeakerEncoder.dot(b, b).squareRoot()
        return SpeakerEncoder.dot(a, b) / (na * nb + 1e-9)
    }

    /// `vp = np.mean(embs, axis=0); vp / (np.linalg.norm(vp) + 1e-9)`.
    static func enrolled(_ embeddings: [[Float]]) -> [Float] {
        var mean = [Float](repeating: 0, count: embeddings[0].count)
        for e in embeddings {
            for j in mean.indices { mean[j] += e[j] }
        }
        let n = Float(embeddings.count)
        for j in mean.indices { mean[j] /= n }
        let norm = SpeakerEncoder.dot(mean, mean).squareRoot() + 1e-9
        return mean.map { $0 / norm }
    }

    /// Writes `np.save`'s bytes to a temporary file beside `url`, then rename(2)s it over.
    public static func save(_ vector: [Float], to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try NPYVector.encode(vector).write(to: tmp)
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    /// Python's f"{sim:.2f}".
    static func twoPlaces(_ x: Double) -> String { String(format: "%.2f", x) }
}
