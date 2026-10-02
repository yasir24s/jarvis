import Foundation

/// speech_recognition 3.14's energy endpointing, as jarvis.py's one `Recognizer` runs it on the
/// microphone (plan M08-M13 §3.4): `Recognizer.listen` (`_listen`, __init__.py 466-570) and
/// `adjust_for_ambient_noise` (368-393), for 1280-sample buffers at 16 kHz. A pure value: the
/// caller reads the frames, asks `next()` before each read and hands each frame to `feed`.
///
/// - The threshold is dynamic (`dynamic_energy_threshold`), starting at 300: each quiet buffer
///   while waiting, and each buffer inside a phrase, moves it toward 1.5 × the buffer's energy
///   with damping 0.15^0.08. It carries from one listen to the next, as the Recognizer's does.
/// - A phrase starts on a buffer louder than the threshold, with up to 7 buffers before it
///   (`non_speaking_duration` 0.5 s); it ends after more than `ceil(pause / 0.08)` quiet
///   buffers, or `phraseTimeLimit` seconds. A phrase of fewer than 4 louder buffers
///   (`phrase_threshold` 0.3 s) is dropped and the wait starts again. The clip keeps 7 of the
///   quiet buffers at its end.
/// - Waiting longer than `timeout` is Python's WaitTimeoutError. Like Python, the check comes
///   before the read, so the frame that would have been read next is left for the next reader.
/// - Elapsed time is summed buffer by buffer in Double, as Python sums it: 25 × 0.08 is more than
///   2.0, so a 2 s calibration reads 24 buffers.
/// - Energy is `audioop.rms`: `MicFrame.rms`, truncated to an integer.
public struct EnergyEndpointer: Sendable {
    /// What to do before reading the next buffer.
    public enum Step: Sendable, Equatable {
        case read
        /// WaitTimeoutError: no phrase started within the timeout.
        case timedOut
        /// The phrase reached `phraseTimeLimit`: here is the clip.
        case ended([Int16])
    }

    /// What one buffer did.
    public enum Event: Sendable, Equatable {
        /// No phrase yet.
        case waiting
        /// This buffer started a phrase; `retained` holds it and the buffers before it.
        case started
        /// Inside the phrase; `loud` when the buffer was over the threshold (it resets the pause).
        case inPhrase(loud: Bool)
        /// The phrase was too short and is dropped: waiting again.
        case discarded
        /// The phrase is over: its clip.
        case ended([Int16])
    }

    public static let chunk = 1280
    public static let sampleRate = 16_000.0

    public var energyThreshold: Double = 300
    public var dynamicEnergyThreshold = true
    public var dynamicEnergyAdjustmentDamping = 0.15
    public var dynamicEnergyRatio = 1.5
    /// `pause_threshold`: jarvis.py sets `SENT_PAUSE` (J:5525).
    public var pauseThreshold = 0.8
    public var phraseThreshold = 0.3
    public var nonSpeakingDuration = 0.5

    /// `float(source.CHUNK) / source.SAMPLE_RATE`.
    let secondsPerBuffer = Double(chunk) / sampleRate

    private enum Phase: Sendable { case idle, waiting, phrase }
    private var phase = Phase.idle
    private var timeout: Double?
    private var phraseTimeLimit: Double?
    private var elapsed = 0.0
    private var phraseStart = 0.0
    private var frames: [[Int16]] = []
    private var pauseCount = 0
    private var phraseCount = 0

    public init(pauseThreshold: Double = 0.8) {
        self.pauseThreshold = pauseThreshold
    }

    var pauseBufferCount: Int { Int((pauseThreshold / secondsPerBuffer).rounded(.up)) }
    var phraseBufferCount: Int { Int((phraseThreshold / secondsPerBuffer).rounded(.up)) }
    var nonSpeakingBufferCount: Int { Int((nonSpeakingDuration / secondsPerBuffer).rounded(.up)) }

    /// The buffers kept so far: the pre-roll and the phrase.
    public var retained: [[Int16]] { frames }

    /// Starts one `listen(source, timeout, phrase_time_limit)`. nil (or 0) means no limit, as
    /// Python's falsy test does.
    public mutating func begin(timeout: Double?, phraseTimeLimit: Double?) {
        self.timeout = timeout
        self.phraseTimeLimit = phraseTimeLimit
        elapsed = 0
        startWaiting()
    }

    /// Python's steps before `source.stream.read`.
    public mutating func next() -> Step {
        switch phase {
        case .idle:
            return .read
        case .waiting:
            elapsed += secondsPerBuffer
            if let timeout, timeout != 0, elapsed > timeout {
                phase = .idle
                return .timedOut
            }
            return .read
        case .phrase:
            elapsed += secondsPerBuffer
            if let limit = phraseTimeLimit, limit != 0, elapsed - phraseStart > limit {
                // The limit cuts the phrase off: it ends there, or is too short and the wait
                // starts again (with its own elapsed step, as Python's loop takes one).
                if let clip = finishPhrase() { return .ended(clip) }
                return next()
            }
            return .read
        }
    }

    /// One buffer, read after `next()` said `.read`.
    public mutating func feed(_ frame: [Int16]) -> Event {
        let energy = Double(MicFrame(samples: frame, index: 0).rms)
        switch phase {
        case .idle:
            return .waiting
        case .waiting:
            frames.append(frame)
            if frames.count > nonSpeakingBufferCount { frames.removeFirst() }
            if energy > energyThreshold {
                phase = .phrase
                pauseCount = 0
                phraseCount = 0
                phraseStart = elapsed
                return .started
            }
            adjust(energy)
            return .waiting
        case .phrase:
            frames.append(frame)
            phraseCount += 1
            let loud = energy > energyThreshold
            pauseCount = loud ? 0 : pauseCount + 1
            if pauseCount > pauseBufferCount {
                if let clip = finishPhrase() { return .ended(clip) }
                return .discarded
            }
            adjust(energy)
            return .inPhrase(loud: loud)
        }
    }

    /// The number of buffers `adjust_for_ambient_noise(source, duration)` reads.
    public func calibrationBuffers(duration: Double) -> Int {
        var elapsed = 0.0
        var count = 0
        while true {
            elapsed += secondsPerBuffer
            if elapsed > duration { return count }
            count += 1
        }
    }

    /// One buffer of `adjust_for_ambient_noise`.
    public mutating func calibrate(_ frame: [Int16]) {
        adjust(Double(MicFrame(samples: frame, index: 0).rms), always: true)
    }

    private mutating func adjust(_ energy: Double, always: Bool = false) {
        guard always || dynamicEnergyThreshold else { return }
        let damping = pow(dynamicEnergyAdjustmentDamping, secondsPerBuffer)
        let target = energy * dynamicEnergyRatio
        energyThreshold = energyThreshold * damping + target * (1 - damping)
    }

    private mutating func startWaiting() {
        phase = .waiting
        frames.removeAll(keepingCapacity: true)
        pauseCount = 0
        phraseCount = 0
    }

    /// The end of a phrase: the clip if it was long enough, else nil and waiting again.
    private mutating func finishPhrase() -> [Int16]? {
        phraseCount -= pauseCount
        guard phraseCount >= phraseBufferCount else {
            startWaiting()
            return nil
        }
        let drop = max(0, pauseCount - nonSpeakingBufferCount)
        let clip = frames.dropLast(drop).flatMap { $0 }
        phase = .idle
        return clip
    }
}
