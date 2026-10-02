import Foundation
import Testing
@testable import JarvisVoice

/// The vendored ONNX Runtime loads by dlopen and runs a model. The speaker encoder's own
/// parity is checked against torch in SpeakerGoldenTests.
@Suite("M10 ONNX Runtime dlopen")
struct OrtRuntimeTests {
    @Test func loadsTheVendoredRuntime() throws {
        let assets = try Vendor.assets(needing: [\.onnxRuntime])
        let runtime = try OrtRuntime.load(dylib: assets.onnxRuntime)
        #expect(runtime.version == "1.26.0")
        #expect(try OrtRuntime.load(dylib: assets.onnxRuntime) === runtime)
    }

    /// openWakeWord's melspectrogram.onnx on a fixed ramp. The reference sum is Python's
    /// onnxruntime 1.26.0 on the same input (shape (1, 1, 8, 32), sum 14791.818359375).
    @Test func runsAModel() throws {
        let assets = try Vendor.assets(needing: [\.onnxRuntime])
        let model = Vendor.folder.appending(path: "melspectrogram.onnx")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw Vendor.Missing(files: [model.lastPathComponent])
        }
        let session = try OrtSession(runtime: try OrtRuntime.load(dylib: assets.onnxRuntime), model: model,
                                     inputName: "input", outputName: "output")
        let input = (0 ..< 1760).map { Float(($0 % 200) - 100) * 10 }
        let out = try session.run(input, shape: [1, 1760])
        #expect(out.shape == [1, 1, 8, 32])
        let sum = out.values.reduce(0, +)
        #expect(abs(sum - 14791.818) < 0.05, "sum \(sum)")
    }

    @Test func aWrongInputSizeThrows() throws {
        let assets = try Vendor.assets(needing: [\.onnxRuntime])
        let model = Vendor.folder.appending(path: "melspectrogram.onnx")
        let session = try OrtSession(runtime: try OrtRuntime.load(dylib: assets.onnxRuntime), model: model,
                                     inputName: "input", outputName: "output")
        #expect(throws: OrtError.self) { try session.run([0, 0, 0], shape: [1, 4]) }
    }

    @Test func aMissingDylibIsNamed() {
        let nowhere = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "no-such-\(UUID().uuidString).dylib")
        #expect(throws: OrtError.missing(nowhere.path)) { try OrtRuntime.load(dylib: nowhere) }
    }
}
