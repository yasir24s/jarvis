import Foundation
import JarvisCore

/// What waiting for the wake word came to (J:1087-1142).
public enum WakeResult: Sendable, Equatable {
    /// A score at or over `WAKE_THRESHOLD`: the last 25 frames (2 s) up to it, so the caller can
    /// check the wake against the voiceprint before answering.
    case hard(clip: [Int16])
    /// A score at or over `WAKE_SOFT` that the transcriber confirmed holds the wake word: what it
    /// heard (lowercased, stripped and corrected) and the 45 frames it heard it in.
    case soft(text: String, clip: [Int16])
    /// 250 frames in a row of digital silence (20 s): the stream went to a dead device.
    case deadStream
    /// The frames stopped (the microphone closed) first. Python's `stream.read` error.
    case ended
}

/// The wake word's settings (J:1074, J:1084), from the environment as jarvis.py reads them.
public struct WakeSettings: Sendable, Equatable {
    /// `WAKE_THRESHOLD`: `JARVIS_WAKE_THRESHOLD`, default 0.5. A Python float, so a float32 score
    /// is compared with it in double, as numpy does.
    public var threshold: Double
    /// `WAKE_SOFT`: `JARVIS_WAKE_SOFT`, default 0.15; 0 turns the soft tier off.
    public var soft: Double

    public init(threshold: Double = 0.5, soft: Double = 0.15) {
        self.threshold = threshold
        self.soft = soft
    }

    /// `float(os.environ.get(..., default))`. A value Python's float() refuses would stop Python
    /// JARVIS at import; here the default is kept and the reason logged.
    public static func from(_ environment: [String: String], log: (String) -> Void = { _ in }) -> WakeSettings {
        func read(_ name: String, _ fallback: Double) -> Double {
            guard let raw = environment[name] else { return fallback }
            if let value = PythonFloat.parse(raw) { return value }
            log("wake: \(name)=\(raw.debugDescription) is not a number Python's float() reads; using \(fallback)")
            return fallback
        }
        return WakeSettings(threshold: read("JARVIS_WAKE_THRESHOLD", 0.5), soft: read("JARVIS_WAKE_SOFT", 0.15))
    }
}

/// `wait_for_wake_word` (J:1087-1142, plan §3.6): scores each 80 ms frame until the wake word.
///
/// - A ring holds the last 25 frames; a hard fire returns them.
/// - 250 all-zero frames in a row (20 s) is a dead stream, not a quiet room: a live microphone
///   always has a noise floor. As in Python, a frame counts as zero when the largest of its
///   `np.abs` values is 0, and `np.abs(-32768)` is -32768 in int16.
/// - The soft tier: a score at or over `WAKE_SOFT`, at most every 3 s, takes 20 more frames
///   (about 1.6 s, so a trailing command is in the clip) and has `confirm` transcribe the 45
///   frames. A transcript holding the wake word returns `.soft`; otherwise the detector is reset
///   and the wait goes on. The 20 frames are not scored, as in Python.
/// - The detector is reset at the start of each wait, as `model.reset()` is.
///
/// What was heard is never logged, only scores and lengths.
public actor WakeWatcher {
    /// Transcribes a clip for the soft tier: the text lowercased, stripped and corrected, "" when
    /// nothing was heard, nil when the transcriber failed (Python logs "Soft wake confirm failed"
    /// and carries on).
    public typealias Confirm = @Sendable ([Int16]) async -> String?

    static let ringFrames = 25
    static let deadFrames = 250
    static let softExtraFrames = 20
    static let softInterval = 3.0

    private let makeDetector: @Sendable () throws -> WakeWordDetector
    private let settings: WakeSettings
    private let now: @Sendable () -> Double
    private let log: @Sendable (String) -> Void
    private var detector: WakeWordDetector?
    /// Frames the detector could not score (each scores 0): the plan's error counter.
    public private(set) var failures = 0

    /// - makeDetector: builds the models, on the first `warm()` or `wait`.
    /// - now: seconds, for the soft tier's 3 s spacing; tests pass a clock that moves 80 ms a frame.
    public init(settings: WakeSettings, makeDetector: @escaping @Sendable () throws -> WakeWordDetector,
                now: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.settings = settings
        self.makeDetector = makeDetector
        self.now = now
        self.log = log
    }

    /// Loads the models now (the boot's "warm wake model"), so the first wait does not.
    public func warm() throws {
        if detector == nil { detector = try makeDetector() }
    }

    /// Waits on `frames` until the wake word, a dead stream, or their end. `confirm` nil turns the
    /// soft tier off (Python's `recognizer=None`).
    public func wait<Frames: AsyncSequence & Sendable>(frames: Frames, confirm: Confirm?) async throws -> WakeResult
    where Frames.Element == MicFrame, Frames.Failure == Never {
        try warm()
        guard let detector else { return .ended }
        try detector.reset()
        var ring: [[Int16]] = []
        ring.reserveCapacity(Self.ringFrames + 1)
        var flat = 0
        // Python's `last_soft = 0.0` against time.time(): the first soft fire is never held back.
        var lastSoft: Double?
        var iterator = frames.makeAsyncIterator()
        while let frame = await iterator.next(isolation: #isolation) {
            if Task.isCancelled { return .ended }
            ring.append(frame.samples)
            if ring.count > Self.ringFrames { ring.removeFirst() }
            if Self.isFlat(frame.samples) {
                flat += 1
                if flat >= Self.deadFrames {
                    log("wake: the microphone is delivering pure silence; likely rebound to a dead device")
                    return .deadStream
                }
            } else {
                flat = 0
            }
            let score: Float
            do {
                score = try detector.process(frame.samples)
            } catch {
                failures += 1
                if failures == 1 || failures % 100 == 0 { log("wake: a frame could not be scored (\(error)); \(failures) so far") }
                score = 0
            }
            if Double(score) >= settings.threshold {
                log("wake score=\(String(format: "%.2f", score))")
                return .hard(clip: ring.flatMap { $0 })
            }
            guard settings.soft > 0, Double(score) >= settings.soft, let confirm,
                  lastSoft.map({ now() - $0 > Self.softInterval }) ?? true else {
                continue
            }
            lastSoft = now()
            var extra: [[Int16]] = []
            while extra.count < Self.softExtraFrames, let more = await iterator.next(isolation: #isolation) { extra.append(more.samples) }
            guard extra.count == Self.softExtraFrames else { return .ended }
            let clip = (ring + extra).flatMap { $0 }
            guard let heard = await confirm(clip) else {
                log("wake: soft wake confirm failed (score \(String(format: "%.2f", score)))")
                continue
            }
            if !heard.isEmpty && WakePhrases.containsWakeWord(heard) {
                log("wake: soft wake confirmed (score \(String(format: "%.2f", score)), \(heard.count) chars)")
                return .soft(text: heard, clip: clip)
            }
            try detector.reset()
        }
        return .ended
    }

    /// `int(np.abs(pcm).max()) == 0`, with int16's `abs(-32768) == -32768`.
    static func isFlat(_ samples: [Int16]) -> Bool {
        guard !samples.isEmpty else { return false }
        var top = Int16.min
        for s in samples { top = max(top, s == .min ? .min : abs(s)) }
        return top == 0
    }
}

extension WakeWatcher {
    /// The soft tier's confirmation through M9a's transcriber (Python's
    /// `_apply_corrections(whisper_transcribe(recognizer, clip).lower().strip())`): the clip goes
    /// in as 1280-sample frames, and the kept text, already corrected, comes back lowercased and
    /// stripped. Python lowercases before correcting; the corrections match without regard to
    /// case, so the order changes nothing the wake test or the command sees. Nothing heard is "",
    /// a transcriber that cannot run is nil.
    public static func confirming(with transcriber: Transcriber,
                                  vocabulary: @escaping @Sendable () async -> [String]) -> Confirm {
        { clip in
            let n = MicFrame.sampleCount
            let (frames, feed) = AsyncStream.makeStream(of: MicFrame.self)
            var index: UInt64 = 0
            for start in stride(from: 0, through: clip.count - n, by: n) {
                feed.yield(MicFrame(samples: Array(clip[start..<start + n]), index: index))
                index += 1
            }
            feed.finish()
            switch await transcriber.transcribe(frames, vocabulary: await vocabulary(), preview: { _ in }) {
            case .text(let text, _): return Py.strip(Py.lower(text))
            case .nothing: return ""
            case .unavailable, .cancelled: return nil
            }
        }
    }
}
