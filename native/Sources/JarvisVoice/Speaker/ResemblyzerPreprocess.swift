import Accelerate
import Darwin
import Foundation

/// resemblyzer 0.1.4's audio.py (plan: M08-M13 §3.5, T10.2), ported line for line, with
/// hparams.py's values. Golden-checked against the real functions (tools/golden_m10_speaker.py).
///
/// - `normalizeVolume` runs in Float32, as NumPy 2 does: under NEP 50 every operand in
///   normalize_volume is float32 (wav, the Python int and float scalars are weak). np.mean is
///   NumPy's pairwise float32 sum over f32(n), np.log10 and np.power are libm's log10f and powf,
///   so the result is bit-identical (checked on 39 inputs before porting).
/// - `trimLongSilences` rounds half to even and casts to int16 as NumPy does on arm64, runs a
///   fresh webrtcvad Vad(3) per call as Python does, and keeps a 30 ms window when at least 5
///   of the 8 flags around it are set (np.round(4 / 8) is 0), widened by ±3 windows
///   (binary_dilation with ones(7) is centred, zero border).
/// - `melSpectrogram` is librosa.feature.melspectrogram(sr 16000, n_fft 400, hop 160, n_mels 40,
///   power 2, center, constant padding): 200 zeros each side, a periodic Hann of 400, a DFT
///   by matrix product in Double (400 is not a vDSP DFT size), then the float32 Slaney
///   filterbank. The filterbank is librosa.filters.mel's arithmetic, float64 then rounded to
///   float32 in the same two places.
public enum ResemblyzerPreprocess {
    public static let samplingRate = 16000
    /// audio.py's int16_max.
    static let int16Max: Float = 32767
    /// vad_window_length (30 ms), vad_moving_average_width, vad_max_silence_length.
    public static let vadWindow = 480
    static let movingAverageWidth = 8
    static let maxSilenceLength = 6
    /// audio_norm_target_dBFS.
    public static let targetDBFS: Float = -30
    /// mel_window_length 25 ms, mel_window_step 10 ms, mel_n_channels.
    public static let nFFT = 400
    public static let hop = 160
    public static let melChannels = 40
    public static let bins = 201

    /// preprocess_wav(wav, source_sr=16000): librosa.resample is the identity at 16 kHz, then
    /// normalize_volume(-30, increase_only=True) and trim_long_silences.
    public static func preprocess(_ wav: [Float], vad library: WebRTCVADLibrary) throws -> [Float] {
        try trimLongSilences(normalizeVolume(wav, targetDBFS: targetDBFS, increaseOnly: true), vad: library)
    }

    // MARK: normalize_volume

    public static func normalizeVolume(_ wav: [Float], targetDBFS: Float, increaseOnly: Bool = false,
                                       decreaseOnly: Bool = false) -> [Float] {
        precondition(!(increaseOnly && decreaseOnly), "Both increase only and decrease only are set")
        let squares = wav.map { x -> Float in
            let scaled = x * int16Max
            return scaled * scaled
        }
        let rms = (numpySum(squares) / Float(wav.count)).squareRoot()
        let waveDBFS = 20 * log10f(rms / int16Max)
        let change = targetDBFS - waveDBFS
        if change < 0 && increaseOnly || change > 0 && decreaseOnly { return wav }
        let gain = powf(10, change / 20)
        return wav.map { $0 * gain }
    }

    /// NumPy's float32 add.reduce of a contiguous array: the pairwise summation in
    /// loops_utils.h.src (blocks of 8 accumulators up to 128 values, halves above that, split
    /// on a multiple of 8), added to the identity 0.
    static func numpySum(_ values: [Float]) -> Float {
        values.withUnsafeBufferPointer { 0 + pairwise($0) }
    }

    private static func pairwise(_ a: UnsafeBufferPointer<Float>) -> Float {
        let n = a.count
        if n < 8 {
            var sum: Float = 0
            for v in a { sum += v }
            return sum
        }
        if n <= 128 {
            var r = (a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7])
            var i = 8
            while i < n - n % 8 {
                r.0 += a[i]; r.1 += a[i + 1]; r.2 += a[i + 2]; r.3 += a[i + 3]
                r.4 += a[i + 4]; r.5 += a[i + 5]; r.6 += a[i + 6]; r.7 += a[i + 7]
                i += 8
            }
            var sum = ((r.0 + r.1) + (r.2 + r.3)) + ((r.4 + r.5) + (r.6 + r.7))
            while i < n {
                sum += a[i]
                i += 1
            }
            return sum
        }
        var half = n / 2
        half -= half % 8
        return pairwise(UnsafeBufferPointer(rebasing: a[0 ..< half]))
            + pairwise(UnsafeBufferPointer(rebasing: a[half ..< n]))
    }

    // MARK: trim_long_silences

    /// trim_long_silences(wav): the samples of the kept 30 ms windows.
    public static func trimLongSilences(_ wav: [Float], vad library: WebRTCVADLibrary) throws -> [Float] {
        let flags = try voiceFlags(wav, vad: library)
        let kept = keptWindows(flags)
        var out: [Float] = []
        out.reserveCapacity(kept.filter { $0 }.count * vadWindow)
        for (k, keep) in kept.enumerated() where keep {
            out.append(contentsOf: wav[k * vadWindow ..< (k + 1) * vadWindow])
        }
        return out
    }

    /// The VAD flag of each whole 30 ms window of `np.round(wav * int16_max).astype(np.int16)`,
    /// from a fresh Vad(mode=3), as trim_long_silences computes them.
    public static func voiceFlags(_ wav: [Float], vad library: WebRTCVADLibrary) throws -> [Bool] {
        let n = wav.count - wav.count % vadWindow
        let pcm = (0 ..< n).map { numpyInt16((wav[$0] * int16Max).rounded(.toNearestOrEven)) }
        let vad = try WebRTCVAD(library: library, mode: 3)
        return try stride(from: 0, to: n, by: vadWindow).map { try vad.isSpeech(pcm[$0 ..< $0 + vadWindow]) }
    }

    /// `moving_average(flags, 8)` then `np.round(...).astype(bool)`: window i averages flags
    /// i-3 through i+4 (3 zeros padded before, 4 after), and a mean of exactly 0.5 rounds to 0.
    public static func smoothedWindows(_ flags: [Bool]) -> [Bool] {
        let before = (movingAverageWidth - 1) / 2, after = movingAverageWidth / 2
        return flags.indices.map { i in
            let lo = max(0, i - before), hi = min(flags.count - 1, i + after)
            let count = flags[lo ... hi].filter { $0 }.count
            return (Double(count) / Double(movingAverageWidth)).rounded(.toNearestOrEven) != 0
        }
    }

    /// The smoothed mask after `binary_dilation(mask, np.ones(7))`: centred, zero border.
    public static func keptWindows(_ flags: [Bool]) -> [Bool] {
        let smoothed = smoothedWindows(flags)
        let reach = maxSilenceLength / 2
        return smoothed.indices.map { i in
            smoothed[max(0, i - reach) ... min(smoothed.count - 1, i + reach)].contains(true)
        }
    }

    /// `x.astype(np.int16)` for one float32 as NumPy does it on arm64: truncate toward zero to
    /// int32 with saturation (fcvtzs; NaN gives 0), then keep the low 16 bits.
    static func numpyInt16(_ x: Float) -> Int16 {
        let wide: Int32
        if x.isNaN {
            wide = 0
        } else if x >= 2_147_483_648 {
            wide = .max
        } else if x < -2_147_483_648 {
            wide = .min
        } else {
            wide = Int32(x.rounded(.towardZero))
        }
        return Int16(truncatingIfNeeded: wide)
    }

    // MARK: wav_to_mel_spectrogram

    /// librosa.filters.mel(sr=16000, n_fft=400, n_mels=40) (Slaney scale and norm), float32,
    /// 40 rows of 201 bins, row-major.
    public static let melFilterbank: [Float] = makeMelFilterbank()

    static func hzToMel(_ hz: Double) -> Double {
        let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27.0
        return hz >= minLogHz ? minLogMel + log(hz / minLogHz) / logStep : hz / fSp
    }

    static func melToHz(_ mel: Double) -> Double {
        let fSp = 200.0 / 3, minLogHz = 1000.0, minLogMel = minLogHz / fSp, logStep = log(6.4) / 27.0
        return mel >= minLogMel ? minLogHz * exp(logStep * (mel - minLogMel)) : fSp * mel
    }

    private static func makeMelFilterbank() -> [Float] {
        let n = melChannels + 2
        // mel_frequencies: np.linspace(min_mel, max_mel, 42) (start + i * step, the last one
        // exactly max_mel), then mel_to_hz.
        let maxMel = hzToMel(Double(samplingRate) / 2), minMel = hzToMel(0)
        let step = (maxMel - minMel) / Double(n - 1)
        let melF = (0 ..< n).map { i in melToHz(i == n - 1 ? maxMel : Double(i) * step + minMel) }
        // fft_frequencies: np.fft.rfftfreq(400, 1/16000) = k * (1 / (n * d)).
        let binHz = 1.0 / (Double(nFFT) * (1.0 / Double(samplingRate)))
        let fftFreqs = (0 ..< bins).map { Double($0) * binHz }
        var weights = [Float](repeating: 0, count: melChannels * bins)
        for i in 0 ..< melChannels {
            let lowerDiff = melF[i + 1] - melF[i], upperDiff = melF[i + 2] - melF[i + 1]
            let enorm = 2.0 / (melF[i + 2] - melF[i])
            for k in 0 ..< bins {
                let lower = -(melF[i] - fftFreqs[k]) / lowerDiff
                let upper = (melF[i + 2] - fftFreqs[k]) / upperDiff
                let triangle = Float(max(0, min(lower, upper)))       // stored into a float32 row
                weights[i * bins + k] = Float(Double(triangle) * enorm)  // weights *= enorm, in float64
            }
        }
        return weights
    }

    /// cos and sin of 2πkn/400 for n in 0..<400 (rows) and k in 0...200 (columns), with the
    /// angle reduced mod 400 first.
    private static let dft: (cos: [Double], sin: [Double]) = {
        var c = [Double](repeating: 0, count: nFFT * bins), s = c
        for n in 0 ..< nFFT {
            for k in 0 ..< bins {
                let angle = 2 * Double.pi * Double((k * n) % nFFT) / Double(nFFT)
                c[n * bins + k] = cos(angle)
                s[n * bins + k] = sin(angle)
            }
        }
        return (c, s)
    }()

    /// The periodic Hann window of 400 (scipy get_window('hann', 400, fftbins=True)).
    private static let hann: [Double] = (0 ..< nFFT).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(nFFT)) }

    /// wav_to_mel_spectrogram(wav): (frames, 40) row-major, frames = 1 + count / 160.
    public static func melSpectrogram(_ wav: [Float]) -> (values: [Float], frames: Int) {
        let pad = nFFT / 2
        let frames = 1 + wav.count / hop
        var padded = [Double](repeating: 0, count: wav.count + 2 * pad)
        for (i, v) in wav.enumerated() { padded[pad + i] = Double(v) }
        var windowed = [Double](repeating: 0, count: frames * nFFT)
        for t in 0 ..< frames {
            for n in 0 ..< nFFT { windowed[t * nFFT + n] = padded[t * hop + n] * hann[n] }
        }
        var re = [Double](repeating: 0, count: frames * bins), im = re
        let m = vDSP_Length(frames), p = vDSP_Length(bins), q = vDSP_Length(nFFT)
        vDSP_mmulD(windowed, 1, dft.cos, 1, &re, 1, m, p, q)
        vDSP_mmulD(windowed, 1, dft.sin, 1, &im, 1, m, p, q)
        var power = [Double](repeating: 0, count: frames * bins)
        for i in power.indices { power[i] = re[i] * re[i] + im[i] * im[i] }
        // (frames × 201) · (201 × 40): the filterbank transposed, in Double.
        var bankT = [Double](repeating: 0, count: bins * melChannels)
        for mel in 0 ..< melChannels {
            for k in 0 ..< bins { bankT[k * melChannels + mel] = Double(melFilterbank[mel * bins + k]) }
        }
        var mels = [Double](repeating: 0, count: frames * melChannels)
        vDSP_mmulD(power, 1, bankT, 1, &mels, 1, m, vDSP_Length(melChannels), p)
        return (mels.map { Float($0) }, frames)
    }
}
