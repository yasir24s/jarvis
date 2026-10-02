import Foundation

/// Where the vendored voice binaries are (plan: M08-M13 §3.1). In the app, build-app.sh puts
/// the libraries in Contents/Frameworks and the models in Contents/Resources/vendor. In a
/// checkout, scripts/vendor-voice-assets.sh fills native/Resources/vendor, and SwiftPM builds
/// libpystubs.dylib into the build folder.
public struct VendoredAssets: Sendable, Equatable {
    /// The ONNX Runtime 1.26.0 dylib.
    public var onnxRuntime: URL
    /// libpystubs.dylib, loaded RTLD_GLOBAL before webrtcvad's module.
    public var pyStubs: URL
    /// py-webrtcvad 2.0.10's extension module, `_webrtcvad.cpython-314-darwin.so`.
    public var webrtcvad: URL
    /// The resemblyzer encoder exported to ONNX (tools/export_resemblyzer.py).
    public var speakerModel: URL

    public static let webrtcvadFile = "_webrtcvad.cpython-314-darwin.so"
    public static let speakerModelFile = "resemblyzer.onnx"
    /// openWakeWord 0.6's three models (M11), beside the speaker model.
    public static let wakeMelFile = "melspectrogram.onnx"
    public static let wakeEmbeddingFile = "embedding_model.onnx"
    public static let wakeClassifierFile = "hey_jarvis_v0.1.onnx"

    /// The wake word's melspectrogram, embedding and "hey jarvis" models: build-app.sh and
    /// vendor-voice-assets.sh put them in the same folder as the speaker model.
    public var wakeMelModel: URL { speakerModel.deletingLastPathComponent().appendingPathComponent(Self.wakeMelFile) }
    public var wakeEmbeddingModel: URL {
        speakerModel.deletingLastPathComponent().appendingPathComponent(Self.wakeEmbeddingFile)
    }
    public var wakeClassifierModel: URL {
        speakerModel.deletingLastPathComponent().appendingPathComponent(Self.wakeClassifierFile)
    }

    public init(onnxRuntime: URL, pyStubs: URL, webrtcvad: URL, speakerModel: URL) {
        self.onnxRuntime = onnxRuntime
        self.pyStubs = pyStubs
        self.webrtcvad = webrtcvad
        self.speakerModel = speakerModel
    }

    /// The layout inside a built JARVIS.app.
    public static func appBundle(_ bundle: Bundle = .main) -> VendoredAssets {
        let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
        let models = contents.appendingPathComponent("Resources/vendor", isDirectory: true)
        return VendoredAssets(
            onnxRuntime: frameworks.appendingPathComponent("libonnxruntime.1.dylib"),
            pyStubs: frameworks.appendingPathComponent("libpystubs.dylib"),
            webrtcvad: frameworks.appendingPathComponent(webrtcvadFile),
            speakerModel: models.appendingPathComponent(speakerModelFile))
    }

    /// The layout in a checkout: `vendor` is native/Resources/vendor, `buildProducts` the SwiftPM
    /// folder holding libpystubs.dylib.
    public static func checkout(vendor: URL, buildProducts: URL) -> VendoredAssets {
        VendoredAssets(
            onnxRuntime: vendor.appendingPathComponent("libonnxruntime.1.26.0.dylib"),
            pyStubs: buildProducts.appendingPathComponent("libpystubs.dylib"),
            webrtcvad: vendor.appendingPathComponent(webrtcvadFile),
            speakerModel: vendor.appendingPathComponent(speakerModelFile))
    }
}
