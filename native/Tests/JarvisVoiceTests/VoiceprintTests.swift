import Foundation
import JarvisCore
import Testing
@testable import JarvisVoice

extension M10Speaker {
    /// voiceprint.npy's format and the encoder's session lifetime. The real voiceprint is never
    /// read here: the file below is synthetic, built with the header the Python build wrote
    /// (learnt from the real file's first 128 bytes, which hold the header and no values).
    @Suite("M10 voiceprint file and encoder lifetime")
    struct VoiceprintTests {
        /// The real file's header: NPY 1.0, header length 118, the dict, 58 spaces, a newline.
        static let pythonHeader: [UInt8] = [0x93] + Array("NUMPY".utf8) + [1, 0, 118, 0]
            + Array("{'descr': '<f4', 'fortran_order': False, 'shape': (256,), }".utf8)
            + Array(repeating: UInt8(ascii: " "), count: 58) + [UInt8(ascii: "\n")]

        static func synthetic(_ values: [Float]) -> Data {
            var data = Data(pythonHeader)
            for v in values {
                let b = v.bitPattern
                data.append(contentsOf: [UInt8(b & 0xFF), UInt8(b >> 8 & 0xFF), UInt8(b >> 16 & 0xFF), UInt8(b >> 24)])
            }
            return data
        }

        static let values: [Float] = (0 ..< 256).map { Float(sin(Double($0) * 0.37)) * 0.1 }

        @Test func aFileWithThePythonHeaderLoads() throws {
            #expect(Self.pythonHeader.count == 128)
            let data = Self.synthetic(Self.values)
            #expect(data.count == 1152)                                  // the real file's size
            #expect(try NPYVector.decode(data) == Self.values)
            #expect(NPYVector.encode(Self.values) == data, "the writer gives the same header")
        }

        @Test func npLoadToleratesTrailingBytes() throws {
            #expect(try NPYVector.decode(Self.synthetic(Self.values) + Data([1, 2, 3])) == Self.values)
        }

        @Test func badFilesAreRefused() {
            let good = [UInt8](Self.synthetic(Self.values))
            func variant(_ change: (inout [UInt8]) -> Void) -> Data {
                var b = good
                change(&b)
                return Data(b)
            }
            func header(_ old: String, _ new: String) -> Data {
                variant { b in
                    let text = String(decoding: b[10 ..< 128], as: UTF8.self).replacingOccurrences(of: old, with: new)
                    b.replaceSubrange(10 ..< 128, with: Array(text.utf8))
                }
            }
            #expect(throws: NPYVector.Error.notNPY) { try NPYVector.decode(variant { $0[1] = UInt8(ascii: "X") }) }
            #expect(throws: NPYVector.Error.unsupportedVersion(2, 0)) { try NPYVector.decode(variant { $0[6] = 2 }) }
            #expect(throws: NPYVector.Error.self) { try NPYVector.decode(header("'<f4'", "'<f8'")) }
            #expect(throws: NPYVector.Error.self) { try NPYVector.decode(header("False", "True ")) }
            #expect(throws: NPYVector.Error.self) { try NPYVector.decode(header("(256,)", "(255,)")) }
            #expect(throws: NPYVector.Error.truncated(expected: 1024, got: 1020)) { try NPYVector.decode(Data(good.dropLast(4))) }
            #expect(throws: NPYVector.Error.notNPY) { try NPYVector.decode(Data()) }
        }

        @Test func aBadFileIsLoggedAndIgnored() async throws {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "m10-vp-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = dir.appending(path: "voiceprint.npy")
            try Data("not numpy".utf8).write(to: url)
            let log = LogRecorder()
            let assets = VendoredAssets.checkout(vendor: dir, buildProducts: dir)
            let voiceprint = Voiceprint(url: url, encoder: SpeakerEncoder(assets: assets), research: BumpRecorder(), log: log.sink)
            await voiceprint.load()
            #expect(await !voiceprint.isEnrolled)
            #expect(log.logged == ["Voiceprint load failed: not an NPY file"])
        }

        /// The session loads on first use and goes after the idle time (1 s here), unless a
        /// conversation is open. The 10 s window is for a loaded machine: this checks that the
        /// release happens, not how fast.
        @Test func theSessionIsReleasedWhenIdle() async throws {
            let encoder = try SpeakerCorpus.encoder(idleRelease: .seconds(1))
            let clip = try SpeakerCorpus.samples("daniel_cmd_1")
            #expect(await !encoder.isLoaded)
            #expect(await encoder.embed(clip) != nil)
            #expect(await encoder.isLoaded)
            #expect(await Self.released(encoder, within: .seconds(10)))

            await encoder.setConversationOpen(true)
            #expect(await encoder.embed(clip) != nil)
            try await Task.sleep(for: .milliseconds(1500))
            #expect(await encoder.isLoaded, "kept while the conversation is open")
            await encoder.setConversationOpen(false)
            #expect(await Self.released(encoder, within: .seconds(10)))
        }

        static func released(_ encoder: SpeakerEncoder, within limit: Duration) async -> Bool {
            let clock = SuspendingClock(), deadline = clock.now + limit
            while clock.now < deadline {
                if await !encoder.isLoaded { return true }
                try? await Task.sleep(for: .milliseconds(25))
            }
            return false
        }

        @Test func cosineMatchesTheFormula() {
            let a: [Float] = [1, 2, 3], b: [Float] = [3, 2, 1]
            #expect(abs(Voiceprint.cosine(a, b) - Float(10.0 / 14.0)) < 1e-6)
            #expect(Voiceprint.cosine([0, 0, 0], a) == 0, "the + 1e-9 keeps a zero vector finite")
        }
    }
}
