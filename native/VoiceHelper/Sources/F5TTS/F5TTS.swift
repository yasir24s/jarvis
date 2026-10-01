import Foundation
import MLX
import MLXNN
import MLXRandom
import Vocos

// MARK: - F5TTS

func odeint_euler(fun: (Float, MLXArray) -> MLXArray, y0: MLXArray, t: MLXArray) -> MLXArray {
    var ys = [y0]
    var yCurrent = y0

    for i in 0..<(t.shape[0] - 1) {
        let tCurrent = t[i].item(Float.self)
        let dt = t[i + 1].item(Float.self) - tCurrent

        let k = fun(tCurrent, yCurrent)
        let yNext = yCurrent + dt * k

        ys.append(yNext)
        yCurrent = yNext
    }

    return MLX.stacked(ys, axis: 0)
}

func odeint_midpoint(fun: (Float, MLXArray) -> MLXArray, y0: MLXArray, t: MLXArray) -> MLXArray {
    var ys = [y0]
    var yCurrent = y0

    for i in 0..<(t.shape[0] - 1) {
        let tCurrent = t[i].item(Float.self)
        let dt = t[i + 1].item(Float.self) - tCurrent

        let k1 = fun(tCurrent, yCurrent)
        let mid = yCurrent + 0.5 * dt * k1

        let k2 = fun(tCurrent + 0.5 * dt, mid)
        let yNext = yCurrent + dt * k2

        ys.append(yNext)
        yCurrent = yNext
    }

    return MLX.stacked(ys, axis: 0)
}

func odeint_rk4(fun: (Float, MLXArray) -> MLXArray, y0: MLXArray, t: MLXArray) -> MLXArray {
    var ys = [y0]
    var yCurrent = y0

    for i in 0..<(t.shape[0] - 1) {
        let tCurrent = t[i].item(Float.self)
        let dt = t[i + 1].item(Float.self) - tCurrent

        let k1 = fun(tCurrent, yCurrent)
        let k2 = fun(tCurrent + 0.5 * dt, yCurrent + 0.5 * dt * k1)
        let k3 = fun(tCurrent + 0.5 * dt, yCurrent + 0.5 * dt * k2)
        let k4 = fun(tCurrent + dt, yCurrent + dt * k3)

        let yNext = yCurrent + (dt / 6) * (k1 + 2 * k2 + 2 * k3 + k4)

        ys.append(yNext)
        yCurrent = yNext
    }

    return MLX.stacked(ys)
}

public class F5TTS: Module {
    public enum ODEMethod: String {
        case euler
        case midpoint
        case rk4
    }
    
    enum F5TTSError: Error {
        case unableToLoadModel
        case unableToLoadReferenceAudio
        case unableToDetermineDuration
    }

    public let melSpec: MelSpec
    public let transformer: DiT

    let dim: Int
    let numChannels: Int
    let vocabCharMap: [String: Int]
    let _durationPredictor: DurationPredictor?

    init(
        transformer: DiT,
        melSpec: MelSpec,
        vocabCharMap: [String: Int],
        durationPredictor: DurationPredictor? = nil
    ) {
        self.melSpec = melSpec
        self.numChannels = self.melSpec.nMels
        self.transformer = transformer
        self.dim = transformer.dim
        self.vocabCharMap = vocabCharMap
        self._durationPredictor = durationPredictor

        super.init()
    }

    public func sample(
        cond: MLXArray,
        text: [String],
        duration: Int? = nil,
        lens: MLXArray? = nil,
        steps: Int = 8,
        method: ODEMethod = .rk4,
        cfgStrength: Double = 2.0,
        swayCoef: Double? = -1.0,
        seed: Int? = nil,
        maxDuration: Int = 4096,
        vocoder: ((MLXArray) -> MLXArray)? = nil,
        progressHandler: ((Double) -> Void)? = nil
    ) throws -> (MLXArray, MLXArray) {
        MLX.eval(self.parameters())

        var cond = cond

        // raw wave

        if cond.ndim == 2 {
            cond = cond.reshaped([cond.shape[1]])
            cond = self.melSpec(x: cond)
        }

        let batch = cond.shape[0]
        let condSeqLen = cond.shape[1]
        var lens = lens ?? MLX.full([batch], values: condSeqLen, type: Int.self)

        // text

        let inputText = listStrToIdx(text, vocabCharMap: vocabCharMap)
        let textLens = (inputText .!= -1).sum(axis: -1)
        lens = MLX.maximum(textLens, lens)

        var condMask = lensToMask(t: lens)

        // duration
        var resolvedDuration: MLXArray? = (duration != nil) ? MLXArray(duration!) : nil

        if resolvedDuration == nil, let durationPredictor = self._durationPredictor {
            let estimatedDurationInSeconds = durationPredictor(cond, text: text).item(Float32.self)
            resolvedDuration = MLXArray(Int(Double(estimatedDurationInSeconds) * F5TTS.framesPerSecond))
        }

        guard let resolvedDuration else {
            throw F5TTSError.unableToDetermineDuration
        }

        print("Generating \(Double(resolvedDuration.item(Float32.self)) / F5TTS.framesPerSecond) seconds of audio...")

        var duration = resolvedDuration
        duration = MLX.clip(MLX.maximum(lens + 1, duration), min: 0, max: maxDuration)
        let maxDuration = duration.max().item(Int.self)

        cond = MLX.padded(cond, widths: [.init((0, 0)), .init((0, maxDuration - condSeqLen)), .init((0, 0))])
        condMask = MLX.padded(condMask, widths: [.init((0, 0)), .init((0, maxDuration - condMask.shape[1]))], value: MLXArray(false))
        condMask = condMask.expandedDimensions(axis: -1)
        let stepCond = MLX.where(condMask, cond, MLX.zeros(like: cond))

        let mask: MLXArray? = (batch > 1) ? lensToMask(t: duration) : nil

        // neural ode

        let fn: (Float, MLXArray) -> MLXArray = { t, x in
            let pred = self.transformer(
                x: x,
                cond: stepCond,
                text: inputText,
                time: MLXArray(t),
                dropAudioCond: false,
                dropText: false,
                mask: mask
            )

            guard cfgStrength > 1e-5 else {
                pred.eval()
                return pred
            }

            let nullPred = self.transformer(
                x: x,
                cond: stepCond,
                text: inputText,
                time: MLXArray(t),
                dropAudioCond: true,
                dropText: true,
                mask: mask
            )

            progressHandler?(Double(t))

            let output = pred + (pred - nullPred) * cfgStrength
            output.eval()

            return output
        }

        // noise input

        var y0: [MLXArray] = []
        for dur in duration {
            if let seed {
                MLXRandom.seed(UInt64(seed))
            }
            let noise = MLXRandom.normal([dur.item(Int.self), self.numChannels])
            y0.append(noise)
        }
        let y0Padded = padSequence(y0, paddingValue: 0.0)

        var t = MLXArray.linspace(Float32(0.0), Float32(1.0), count: steps)

        if let coef = swayCoef {
            t = t + coef * (MLX.cos(MLXArray(.pi) / 2 * t) - 1 + t)
        }

        let odeintFn = switch method {
        case .euler: odeint_euler
        case .midpoint: odeint_midpoint
        case .rk4: odeint_rk4
        }

        let trajectory = odeintFn(fn, y0Padded, t)
        let sampled = trajectory[-1]
        var out = MLX.where(condMask, cond, sampled)

        if let vocoder {
            out = vocoder(out)
        }
        out.eval()

        return (out, trajectory)
    }

    public func generate(
        text: String,
        referenceAudioURL: URL? = nil,
        referenceAudioText: String? = nil,
        duration: TimeInterval? = nil,
        steps: Int = 8,
        method: ODEMethod = .rk4,
        cfg: Double = 2.0,
        sway: Double = -1.0,
        speed: Double = 1.0,
        seed: Int? = nil,
        vocos: Vocos,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> MLXArray {

        // load the reference audio + text

        var audio: MLXArray
        let referenceText: String

        // JARVIS: the bundled test clip is not vendored, so a reference URL is required.
        guard let referenceAudioURL else { throw F5TTSError.unableToLoadReferenceAudio }
        audio = try F5TTS.loadAudioArray(url: referenceAudioURL)
        referenceText = referenceAudioText ?? ""

        let refAudioDuration = Double(audio.shape[0]) / Double(F5TTS.sampleRate)
        print("Using reference audio with duration: \(refAudioDuration)")

        // generate the audio

        let normalizedAudio = F5TTS.normalizeAudio(audio: audio)
        let processedText = referenceText + " " + text

        let (outputAudio, _) = try self.sample(
            cond: normalizedAudio.expandedDimensions(axis: 0),
            text: [processedText],
            duration: nil,
            steps: steps,
            method: method,
            cfgStrength: cfg,
            swayCoef: sway,
            seed: seed,
            vocoder: vocos.decode
        ) { progress in
            print("Generation progress: \(progress)")
            progressHandler?(progress)
        }

        return outputAudio[audio.shape[0]...]
    }
}

// MARK: - Pretrained Models

public extension F5TTS {
    static func fromPretrained(modelDirectoryURL: URL) throws -> F5TTS {
        let modelURL = modelDirectoryURL.appendingPathComponent("model.safetensors")
        var modelWeights = try loadArrays(url: modelURL)

        // mel spec

        guard let filterbankURL = Bundle.module.url(forResource: "mel_filters", withExtension: "npy") else {
            throw F5TTSError.unableToLoadModel
        }
        let filterbank = try MLX.loadArray(url: filterbankURL)

        // vocab

        let vocabURL = modelDirectoryURL.appendingPathComponent("vocab.txt")
        guard let vocabString = try String(data: Data(contentsOf: vocabURL), encoding: .utf8) else {
            throw F5TTSError.unableToLoadModel
        }

        let vocabEntries = vocabString.split(separator: "\n").map { String($0) }
        let vocab = Dictionary(uniqueKeysWithValues: zip(vocabEntries, vocabEntries.indices))

        // duration model

        var durationPredictor: DurationPredictor?
        let durationModelURL = modelDirectoryURL.appendingPathComponent("duration_v2.safetensors")
        do {
            let durationModelWeights = try loadArrays(url: durationModelURL)

            let durationTransformer = DurationTransformer(
                dim: 512,
                depth: 8,
                heads: 8,
                dimHead: 64,
                ffMult: 2,
                textNumEmbeds: vocab.count,
                textDim: 512,
                convLayers: 2
            )
            let predictor = DurationPredictor(
                transformer: durationTransformer,
                melSpec: MelSpec(filterbank: filterbank),
                vocabCharMap: vocab
            )
            try predictor.update(parameters: ModuleParameters.unflattened(durationModelWeights), verify: [.all])

            durationPredictor = predictor
        } catch {
            print("Warning: no duration predictor model found: \(error)")
        }

        // model

        // MLX-quantised checkpoint (model_v1_8b: affine, 8 bits, group size 64), see makeLinear.
        if modelWeights.keys.contains(where: { $0.hasSuffix(".scales") }) {
            linearQuantization = (groupSize: 64, bits: 8)
        }
        defer { linearQuantization = nil }
        let dit = DiT(
            dim: 1024,
            depth: 22,
            heads: 16,
            ffMult: 2,
            textNumEmbeds: vocab.count,
            textDim: 512,
            convLayers: 4
        )
        let f5tts = F5TTS(
            transformer: dit,
            melSpec: MelSpec(filterbank: filterbank),
            vocabCharMap: vocab,
            durationPredictor: durationPredictor
        )
        // model_v1_8b lacks arrays the modules build themselves (e.g. melSpec.filterbank from
        // mel_filters.npy). Keep the built values, named in the log, so verify: [.all] checks the rest.
        for (key, value) in f5tts.parameters().flattened() where modelWeights[key] == nil {
            print("F5TTS: \(key) not in checkpoint, keeping the module's own \(value.shape)")
            modelWeights[key] = value
        }
        try f5tts.update(parameters: ModuleParameters.unflattened(modelWeights), verify: [.all])

        return f5tts
    }
}

// MARK: - Utilities

public extension F5TTS {
    static var sampleRate: Int = 24000
    static var hopLength: Int = 256
    static var framesPerSecond: Double = .init(sampleRate) / Double(hopLength)

    static func loadAudioArray(url: URL) throws -> MLXArray {
        try AudioUtilities.loadAudioFile(url: url)
    }

    static func normalizeAudio(audio: MLXArray, targetRMS: Double = 0.1) -> MLXArray {
        let rms = Double(audio.square().mean().sqrt().item(Float.self))
        if rms < targetRMS {
            return audio * targetRMS / rms
        }
        return audio
    }

    static func estimatedDuration(refAudio: MLXArray, refText: String, text: String, speed: Double = 1.0) -> TimeInterval {
        let refDurationInFrames = refAudio.shape[0] / self.hopLength
        let refTextLength = refText.utf8.count
        let genTextLength = text.utf8.count

        let refAudioToTextRatio = Double(refDurationInFrames) / Double(refTextLength)
        let textLength = Double(genTextLength) / speed
        let estimatedDurationInFrames = Int(refAudioToTextRatio * textLength)

        let estimatedDuration = TimeInterval(estimatedDurationInFrames) / Self.framesPerSecond
        print("Using duration of \(estimatedDuration) seconds (\(estimatedDurationInFrames) frames) for generated speech.")

        return estimatedDuration
    }
}

// MLX utilities

func lensToMask(t: MLXArray, length: Int? = nil) -> MLXArray {
    let maxLength = length ?? t.max(keepDims: false).item(Int.self)
    let seq = MLXArray(0..<maxLength)
    let expandedSeq = seq.expandedDimensions(axis: 0)
    let expandedT = t.expandedDimensions(axis: 1)
    return MLX.less(expandedSeq, expandedT)
}

func padToLength(_ t: MLXArray, length: Int, value: Float? = nil) -> MLXArray {
    let ndim = t.ndim

    guard let seqLen = t.shape.last, length > seqLen else {
        return t[0..., .ellipsis]
    }

    let paddingValue = MLXArray(value ?? 0.0)

    let padded: MLXArray
    switch ndim {
    case 1:
        padded = MLX.padded(t, widths: [.init((0, length - seqLen))], value: paddingValue)
    case 2:
        padded = MLX.padded(t, widths: [.init((0, 0)), .init((0, length - seqLen))], value: paddingValue)
    case 3:
        padded = MLX.padded(t, widths: [.init((0, 0)), .init((0, length - seqLen)), .init((0, 0))], value: paddingValue)
    default:
        fatalError("Unsupported padding dims: \(ndim)")
    }

    return padded[0..., .ellipsis]
}

func padSequence(_ t: [MLXArray], paddingValue: Float = 0) -> MLXArray {
    let maxLen = t.map { $0.shape.last ?? 0 }.max() ?? 0
    let t = MLX.stacked(t, axis: 0)
    return padToLength(t, length: maxLen, value: paddingValue)
}

func listStrToIdx(_ text: [String], vocabCharMap: [String: Int], paddingValue: Int = -1) -> MLXArray {
    let listIdxTensors = text.map { str in str.map { char in vocabCharMap[String(char), default: 0] }}
    let mlxArrays = listIdxTensors.map { MLXArray($0) }
    let paddedText = padSequence(mlxArrays, paddingValue: Float(paddingValue))
    return paddedText.asType(.int32)
}
