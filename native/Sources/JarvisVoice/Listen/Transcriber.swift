import Foundation
import JarvisCore

/// One final result from the recogniser. `confidence` is the duration-weighted mean of its runs'
/// `transcriptionConfidence` (plan M08-M13 §3.4); nil when no run carries one.
public struct RecognizedSegment: Sendable, Equatable {
    public var text: String
    public var confidence: Double?

    public init(text: String, confidence: Double?) {
        self.text = text
        self.confidence = confidence
    }
}

/// Why the recogniser cannot transcribe. Logged; nothing is downloaded.
public enum TranscriberError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `SpeechTranscriber.isAvailable` is false on this Mac.
    case unavailable
    /// No on-device model for the locale.
    case unsupportedLocale(String)
    /// The locale's model is supported but not installed (`AssetInventory` status).
    case assetMissing(String)
    /// The analyzer failed: no audio format, or it would not start or finish.
    case failed(String)

    public var description: String {
        switch self {
        case .unavailable: "on-device speech recognition is not available"
        case .unsupportedLocale(let l): "no on-device speech model for \(l)"
        case .assetMissing(let s): "the speech model is not installed (\(s)); not downloading it"
        case .failed(let d): "speech recognition failed (\(d))"
        }
    }
}

/// One utterance being transcribed.
public protocol RecognitionSession: Sendable {
    /// Hands the recogniser one frame of audio.
    func append(_ frame: MicFrame) async
    /// No more audio: finishes the analysis and returns the final results in order.
    func finish() async throws -> [RecognizedSegment]
    /// Drops the utterance.
    func cancel() async
}

/// The recogniser behind `Transcriber`: Apple's on-device SpeechTranscriber in the app
/// (`AppleSpeechRecognizer`), a fake in tests, so no test needs the model or a permission.
public protocol SpeechRecognizing: Sendable {
    /// nil when it can transcribe; else why not.
    func readiness() async -> TranscriberError?
    /// Starts an utterance. `preview` gets the live text (the final results so far, then the
    /// volatile one) each time it changes.
    func begin(contextualStrings: [String],
               preview: @escaping @Sendable (String) -> Void) async throws -> any RecognitionSession
}

/// The hallucination guard (§3.4), standing in for Whisper's `no_speech_prob > 0.6 or
/// avg_logprob < -1.2` (J:946-952): a final result under `STT_MIN_CONF` is dropped.
public enum ConfidenceGuard {
    /// `STT_MIN_CONF`, calibrated on the gated live check (`TranscriberLiveTests`, 2026-10-02,
    /// macOS 27.2, en_GB). Speech made with `say` (Daniel) read 0.939, 0.987 and 0.969 clean, and
    /// 0.674 to 0.994 with white noise from 20 dB SNR down to 0 dB (three runs; at 0 dB "Jarvis"
    /// came back as "Java" once and "Zander" once, at 0.688 and 0.674). White noise alone made the
    /// model hallucinate "Yeah, it's - it's - it's ..." at 0.048 (about -20 dBFS, unseeded) and at
    /// 0.042 and 0.037 (-10 dBFS, seeds 1 and 4); silence, hum, a chord melody and the other noise
    /// clips gave no result at all; a fragment cut off mid-word where a session ended read 0.27
    /// (`ListeningMeasureTests`). 0.3 drops the hallucinations and the clipped fragment and keeps
    /// every whole sentence, with room above it, and is Whisper's own floor (`avg_logprob < -1.2`,
    /// J:946) read as a probability: exp(-1.2) = 0.30. The user's own voice through the Mac's
    /// microphone is not measured yet; each utterance's log line gives its confidence for that.
    public static let defaultMinimum = 0.3

    /// `JARVIS_STT_MIN_CONF` (the plan's proposed name) when it parses as a number in 0...1.
    public static func minimum(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        guard let raw = environment["JARVIS_STT_MIN_CONF"], let v = Double(raw.trimmingCharacters(in: .whitespaces)),
              v.isFinite, (0...1).contains(v) else { return defaultMinimum }
        return v
    }

    /// The results kept and dropped. A result without a confidence is kept: there is nothing to
    /// judge it by.
    public static func filter(_ segments: [RecognizedSegment],
                              minimum: Double) -> (kept: [RecognizedSegment], dropped: [RecognizedSegment]) {
        var kept: [RecognizedSegment] = []
        var dropped: [RecognizedSegment] = []
        for s in segments {
            if let c = s.confidence, c < minimum { dropped.append(s) } else { kept.append(s) }
        }
        return (kept, dropped)
    }

    /// `" ".join(kept).strip()` (J:954).
    public static func join(_ kept: [RecognizedSegment]) -> String {
        Py.strip(kept.map(\.text).joined(separator: " "))
    }

    /// The duration-weighted mean of (duration, confidence) runs; the plain mean when every
    /// duration is zero; nil with no runs.
    public static func weightedMean(_ runs: [(duration: Double, confidence: Double)]) -> Double? {
        guard !runs.isEmpty else { return nil }
        let total = runs.reduce(0) { $0 + max(0, $1.duration) }
        if total > 0 {
            return runs.reduce(0) { $0 + max(0, $1.duration) * $1.confidence } / total
        }
        return runs.reduce(0) { $0 + $1.confidence } / Double(runs.count)
    }
}

/// What one utterance came to.
public enum TranscriptOutcome: Sendable, Equatable {
    /// The kept text after Corrections. `dropped` results were under the guard.
    case text(String, dropped: Int)
    /// Nothing kept: no speech came back, or every result was dropped (`dropped` of them).
    case nothing(dropped: Int)
    /// The recogniser could not run.
    case unavailable(TranscriberError)
    /// Cancelled before the end.
    case cancelled
}

/// On-device transcription for push-to-talk (§3.4). It reads frames until the stream ends (the
/// mic closes when the user lets go), takes the final results, drops those under the guard (each
/// bumps `stt_segments_dropped`, as J:952 does), joins the rest and applies the corrections, the
/// one choke point `_apply_corrections` is in Python (J:974).
public actor Transcriber {
    /// `STT_LANG` (J:91): `JARVIS_STT_LANG`, default en-GB.
    public static func locale(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["JARVIS_STT_LANG"] ?? "en-GB"
    }

    private let recognizer: any SpeechRecognizing
    private let minimum: Double
    private let research: any ResearchCounting
    private let corrections: @Sendable (String) async -> String
    private let log: @Sendable (String) -> Void
    private var ready = false

    public init(recognizer: any SpeechRecognizing, minimumConfidence: Double = ConfidenceGuard.minimum(),
                research: any ResearchCounting, corrections: @escaping @Sendable (String) async -> String,
                log: @escaping @Sendable (String) -> Void) {
        self.recognizer = recognizer
        self.minimum = minimumConfidence
        self.research = research
        self.corrections = corrections
        self.log = log
    }

    /// Transcribes `frames` until the stream finishes. Volatile text goes to `preview`; only the
    /// outcome is final. When the recogniser cannot run, the frames are still read to the end, so
    /// the mic's stream is never left full.
    public func transcribe(_ frames: AsyncStream<MicFrame>, vocabulary: [String],
                           preview: @escaping @Sendable (String) -> Void) async -> TranscriptOutcome {
        if !ready {
            if let reason = await recognizer.readiness() {
                log("speech: \(reason)")
                for await _ in frames {}
                return .unavailable(reason)
            }
            ready = true
        }
        let session: any RecognitionSession
        do {
            session = try await recognizer.begin(contextualStrings: vocabulary, preview: preview)
        } catch {
            let reason = (error as? TranscriberError) ?? .failed("\(error)")
            log("speech: \(reason)")
            for await _ in frames {}
            return .unavailable(reason)
        }
        var count = 0
        for await frame in frames {
            if Task.isCancelled { break }
            await session.append(frame)
            count += 1
        }
        if Task.isCancelled {
            await session.cancel()
            return .cancelled
        }
        if count == 0 {
            // Let go before a whole frame arrived: nothing to transcribe.
            await session.cancel()
            return .nothing(dropped: 0)
        }
        let segments: [RecognizedSegment]
        do {
            segments = try await session.finish()
        } catch {
            if Task.isCancelled { return .cancelled }
            let reason = (error as? TranscriberError) ?? .failed("\(error)")
            log("speech: \(reason)")
            return .unavailable(reason)
        }
        let (kept, dropped) = ConfidenceGuard.filter(segments, minimum: minimum)
        log(Self.summary(segments, dropped: dropped.count))
        for d in dropped {
            // J:949-951 logs the words; native logs no user text, only the measure and the length.
            log("STT dropped low-confidence segment (confidence \(String(format: "%.2f", d.confidence ?? 0)), "
                + "\(d.text.count) chars)")
            research.bump(ResearchKey.sttSegmentsDropped, by: 1)
        }
        let joined = ConfidenceGuard.join(kept)
        guard !joined.isEmpty else { return .nothing(dropped: dropped.count) }
        let text = Py.strip(await corrections(joined))
        return text.isEmpty ? .nothing(dropped: dropped.count) : .text(text, dropped: dropped.count)
    }

    /// One line per utterance, numbers only: how many results, how many dropped, and their
    /// confidences, so the floor can be checked against the user's own voice.
    static func summary(_ segments: [RecognizedSegment], dropped: Int) -> String {
        let confidences = segments.map { $0.confidence.map { String(format: "%.2f", $0) } ?? "none" }
        return "speech: \(segments.count) result\(segments.count == 1 ? "" : "s"), \(dropped) dropped"
            + (confidences.isEmpty ? "" : ", confidence \(confidences.joined(separator: " "))")
    }
}
