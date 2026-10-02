import Accelerate
import Foundation

/// resemblyzer's VoiceEncoder on ONNX Runtime (plan: M08-M13 §3.5, T10.3), with
/// `resemblyzer.onnx` from tools/export_resemblyzer.py: [B,160,40] mels in, [B,256] L2-normed
/// partial embeddings out.
///
/// The ORT session is created on first use and released after `idleRelease` (300 s) without
/// one, except while a conversation is open. `embed` is jarvis.py's `_embed` (J:5177-5193):
/// nil under 9600 samples, nil under 6400 after preprocessing, and nil, logged, on any error.
public actor SpeakerEncoder {
    public static let partialFrames = 160
    public static let melChannels = 40
    public static let embeddingSize = 256
    /// `_embed`'s two length checks: 16000 * 0.6 and 16000 * 0.4.
    public static let minimumSamples = 9600
    public static let minimumPreprocessed = 6400
    public static let defaultIdleRelease: Duration = .seconds(300)

    private let assets: VendoredAssets
    private let idleRelease: Duration
    private let log: @Sendable (String) -> Void
    private var session: OrtSession?
    private var conversationOpen = false
    private var uses = 0                       // the release timer only acts if no use came after it
    private var releaseTimer: Task<Void, Never>?

    public init(assets: VendoredAssets, idleRelease: Duration = defaultIdleRelease,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.assets = assets
        self.idleRelease = idleRelease
        self.log = log
    }

    /// Whether the ORT session is loaded now.
    public var isLoaded: Bool { session != nil }

    /// While a conversation is open the session stays loaded; closing it starts the idle timer.
    public func setConversationOpen(_ open: Bool) {
        conversationOpen = open
        if !open { scheduleRelease() }
    }

    // MARK: compute_partial_slices

    /// `VoiceEncoder.compute_partial_slices(n_samples, rate, min_coverage)`: the mel slices
    /// (the wav slices are these times 160).
    public static func partialSlices(samples n: Int, rate: Double = 1.3, minCoverage: Double = 0.75) -> [Range<Int>] {
        precondition(minCoverage > 0 && minCoverage <= 1)
        let samplesPerFrame = 160
        let frames = Int((Double(n + 1) / Double(samplesPerFrame)).rounded(.up))
        let frameStep = Int((Double(16000) / rate / Double(samplesPerFrame)).rounded(.toNearestOrEven))
        precondition(frameStep > 0 && frameStep <= partialFrames, "rate out of range")
        let steps = max(1, frames - partialFrames + frameStep + 1)
        var slices = stride(from: 0, to: steps, by: frameStep).map { $0 ..< $0 + partialFrames }
        let last = slices[slices.count - 1]
        let start = last.lowerBound * samplesPerFrame, stop = last.upperBound * samplesPerFrame
        let coverage = Double(n - start) / Double(stop - start)
        if coverage < minCoverage && slices.count > 1 { slices.removeLast() }
        return slices
    }

    // MARK: embedding

    /// Loads webrtcvad and the ORT session now: enroll_voice's backend check (`_get_encoder()`).
    public func prepare() throws {
        _ = try vadLibrary()
        _ = try loadedSession()
        scheduleRelease()
    }

    /// `preprocess_wav(int16 / 32768, source_sr=16000)` on 16 kHz mono samples.
    public func preprocess(_ samples: [Int16]) throws -> [Float] {
        try ResemblyzerPreprocess.preprocess(samples.map { Float($0) / 32768 }, vad: try vadLibrary())
    }

    /// jarvis.py's `_embed(audio)` on 16 kHz mono samples.
    public func embed(_ samples: [Int16]) -> [Float]? {
        do {
            if samples.count < Self.minimumSamples { return nil }
            let pre = try preprocess(samples)
            if pre.count < Self.minimumPreprocessed { return nil }
            return try embedUtterance(pre)
        } catch {
            log("Embed error: \(error)")
            return nil
        }
    }

    /// `embed_utterance(wav)` on a preprocessed waveform: pad to the last partial, mel, one
    /// batched run, the mean of the partials, L2-normalised.
    public func embedUtterance(_ wav: [Float]) throws -> [Float] {
        let slices = Self.partialSlices(samples: wav.count)
        let maxLength = slices[slices.count - 1].upperBound * 160
        var padded = wav
        if maxLength >= wav.count { padded += [Float](repeating: 0, count: maxLength - wav.count) }
        let mel = ResemblyzerPreprocess.melSpectrogram(padded)
        var batch: [Float] = []
        batch.reserveCapacity(slices.count * Self.partialFrames * Self.melChannels)
        for s in slices {
            batch += mel.values[s.lowerBound * Self.melChannels ..< s.upperBound * Self.melChannels]
        }
        let partials = try partialEmbeddings(batch, count: slices.count)
        return Self.meanNormalized(partials, count: slices.count)
    }

    /// One ORT run of `count` partials ([count,160,40] row-major) to [count,256] row-major.
    public func partialEmbeddings(_ mels: [Float], count: Int) throws -> [Float] {
        let session = try loadedSession()
        defer { scheduleRelease() }
        let out = try session.run(mels, shape: [Int64(count), Int64(Self.partialFrames), Int64(Self.melChannels)])
        guard out.shape == [Int64(count), Int64(Self.embeddingSize)] else {
            throw OrtError.failure("embeds shape \(out.shape), expected [\(count), \(Self.embeddingSize)]")
        }
        return out.values
    }

    /// `raw = np.mean(partials, axis=0); raw / np.linalg.norm(raw, 2)`, in float32: the rows
    /// added in order, divided by the count, then divided by sqrt(dot(raw, raw)).
    static func meanNormalized(_ partials: [Float], count: Int) -> [Float] {
        var raw = [Float](repeating: 0, count: embeddingSize)
        for b in 0 ..< count {
            for j in 0 ..< embeddingSize { raw[j] += partials[b * embeddingSize + j] }
        }
        let n = Float(count)
        for j in raw.indices { raw[j] /= n }
        let norm = dot(raw, raw).squareRoot()
        return raw.map { $0 / norm }
    }

    /// A float32 dot product (vDSP_dotpr). NumPy's np.dot goes to Accelerate's BLAS, so the
    /// order of the sums may differ in the last bits; the goldens allow for that.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var out: Float = 0
        vDSP_dotpr(a, 1, b, 1, &out, vDSP_Length(min(a.count, b.count)))
        return out
    }

    // MARK: the session

    private func vadLibrary() throws -> WebRTCVADLibrary {
        try WebRTCVADLibrary.load(stubs: assets.pyStubs, module: assets.webrtcvad)
    }

    private func loadedSession() throws -> OrtSession {
        uses += 1
        if let session { return session }
        let runtime = try OrtRuntime.load(dylib: assets.onnxRuntime)
        let made = try OrtSession(runtime: runtime, model: assets.speakerModel, inputName: "mels", outputName: "embeds")
        session = made
        return made
    }

    private func scheduleRelease() {
        releaseTimer?.cancel()
        let marker = uses, wait = idleRelease
        releaseTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self?.releaseIfIdle(since: marker)
        }
    }

    private func releaseIfIdle(since marker: Int) {
        guard uses == marker, !conversationOpen else { return }
        session = nil
    }
}
