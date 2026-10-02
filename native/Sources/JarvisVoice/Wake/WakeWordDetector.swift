import Foundation

/// openWakeWord's "hey jarvis" for 1280-sample frames (plan M08-M13 §3.6), adapted from
/// jarvis-swift's WakeWord.swift. It ports openwakeword 0.6's streaming path as jarvis.py drives
/// it (`Model(wakeword_models=["hey_jarvis"], inference_framework="onnx")`, one `predict` per
/// 80 ms frame, J:1073-1082), on the same three models and ORT 1.26.0 with one thread each:
///
/// 1. melspectrogram.onnx on the last 1760 samples (the 1280 new ones and 480 before them, or
///    the 1280 alone on the first frame), each value then `x / 10 + 2` (openwakeword's
///    `melspec_transform`), appended to the mel buffer (at most 970 rows of 32);
/// 2. embedding_model.onnx on the last 76 mel rows, one 96-value row onto the feature buffer
///    (at most 120 rows);
/// 3. hey_jarvis_v0.1.onnx on the last 16 feature rows: the score.
///
/// `reset()` is `Model.reset()`: the mel buffer back to 76 rows of ones, and the feature buffer
/// seeded with the embeddings of 4 s of noise (`np.random.randint(-1000, 1000, 64000)`, which
/// `noise` stands in for, so tests can give Python's exact array), taken as openwakeword's
/// `_get_embeddings` does: windows of 76 rows every 8, in one batch. The first 5 scores after a
/// reset are 0, as `Model.predict` zeroes them while its buffers fill.
///
/// Not Sendable: `WakeWatcher`, an actor, owns it.
public final class WakeWordDetector {
    public static let frameSamples = 1280
    static let melBins = 32
    static let melWindow = 76
    static let melMaxRows = 10 * 97
    static let embeddingSize = 96
    static let featureMaxRows = 120
    static let classifierRows = 16
    static let lookback = 160 * 3
    static let seedSamples = 16_000 * 4
    static let seedStep = 8

    /// 4 s of noise for a reset: `seedSamples` values in -1000..<1000.
    public typealias NoiseSource = () -> [Int16]

    /// `np.random.randint(-1000, 1000, 64000)`'s range, from the system's generator.
    public static func randomNoise() -> [Int16] {
        (0..<seedSamples).map { _ in Int16.random(in: -1000...999) }
    }

    private let mel: OrtSession
    private let embedding: OrtSession
    private let classifier: OrtSession
    private let noise: NoiseSource
    private var raw: [Int16] = []
    private var melRows: [Float] = []
    private var features: [Float] = []
    private var scored = 0

    /// Loads the three models (the tensor names are those of these exact files) and resets.
    public init(runtime: OrtRuntime, assets: VendoredAssets, noise: @escaping NoiseSource = WakeWordDetector.randomNoise)
        throws {
        mel = try OrtSession(runtime: runtime, model: assets.wakeMelModel, inputName: "input", outputName: "output")
        embedding = try OrtSession(runtime: runtime, model: assets.wakeEmbeddingModel, inputName: "input_1",
                                   outputName: "conv2d_19")
        classifier = try OrtSession(runtime: runtime, model: assets.wakeClassifierModel, inputName: "x.1",
                                    outputName: "53")
        self.noise = noise
        try reset()
    }

    /// `Model.reset()`.
    public func reset() throws {
        raw.removeAll(keepingCapacity: true)
        melRows = [Float](repeating: 1, count: Self.melWindow * Self.melBins)
        scored = 0
        let seed = noise()
        guard seed.count == Self.seedSamples else {
            throw OrtError.failure("wake word: the seed noise has \(seed.count) samples, not \(Self.seedSamples)")
        }
        let spec = try melspectrogram(seed[...])
        let rows = spec.count / Self.melBins
        var batch: [Float] = []
        var windows = 0
        var start = 0
        while start < rows {
            if start + Self.melWindow <= rows {
                batch += spec[(start * Self.melBins)..<((start + Self.melWindow) * Self.melBins)]
                windows += 1
            }
            start += Self.seedStep
        }
        features = try embedding.run(batch, shape: [Int64(windows), Int64(Self.melWindow), Int64(Self.melBins), 1]).values
        trimFeatures()
    }

    /// The score for one frame of exactly 1280 samples, 0...1.
    public func process(_ frame: [Int16]) throws -> Float {
        guard frame.count == Self.frameSamples else {
            throw OrtError.failure("wake word: a frame has \(frame.count) samples, not \(Self.frameSamples)")
        }
        // _streaming_melspectrogram: the last n + 480 samples.
        raw += frame
        if raw.count > Self.frameSamples + Self.lookback {
            raw.removeFirst(raw.count - Self.frameSamples - Self.lookback)
        }
        melRows += try melspectrogram(raw[...])
        if melRows.count > Self.melMaxRows * Self.melBins {
            melRows.removeFirst(melRows.count - Self.melMaxRows * Self.melBins)
        }
        let window = Array(melRows.suffix(Self.melWindow * Self.melBins))
        features += try embedding.run(window, shape: [1, Int64(Self.melWindow), Int64(Self.melBins), 1]).values
        trimFeatures()
        let input = Array(features.suffix(Self.classifierRows * Self.embeddingSize))
        let out = try classifier.run(input, shape: [1, Int64(Self.classifierRows), Int64(Self.embeddingSize)]).values
        guard let score = out.first else { throw OrtError.failure("wake word: the classifier gave no score") }
        scored += 1
        return scored <= 5 ? 0 : score
    }

    /// For tests: the mel rows one call adds for `samples`, after the transform.
    func melspectrogram(_ samples: ArraySlice<Int16>) throws -> [Float] {
        let x = samples.map { Float($0) }
        return try mel.run(x, shape: [1, Int64(x.count)]).values.map { $0 / 10 + 2 }
    }

    private func trimFeatures() {
        if features.count > Self.featureMaxRows * Self.embeddingSize {
            features.removeFirst(features.count - Self.featureMaxRows * Self.embeddingSize)
        }
    }
}
