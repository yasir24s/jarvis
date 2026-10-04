import Foundation

// M8 voice out (plan: M08-M13 §3.2, as D-54 changed it). The voice is the F5-TTS clone, run by
// the jarvis-voice helper process (F5Engine); macOS `say` is the fallback (SayEngine). The plan's
// ElevenLabs and Piper engines are not built: D-54 chose the clone instead. V6: Qwen3-TTS, streamed
// by the jarvis-voice-qwen helper (QwenEngine), is the voice, with F5 as its fallback (VoiceSelector).

/// The engines this milestone has.
public enum EngineID: String, Sendable {
    case qwen, f5, say
}

/// Why an engine gave up on a sentence, so the queue used `say` (§3.2's reasons that apply).
public enum FallbackReason: String, Sendable {
    /// No answer within the per-request timeout.
    case timeout
    /// The engine is off: not installed, or resting after failures in a row.
    case disabled
    /// Anything else: an error reply, a crash, an unreadable result.
    case error
}

/// Mono audio.
public struct PCMChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    /// V8: on the first piece of a request to the voice, when the request was made. A stream that
    /// joins several requests (a reply spoken as it is written) sets it, so `DeliveryMeter` does
    /// not count the time the voice sat idle waiting for the brain's next sentence.
    public var requestedAt: ContinuousClock.Instant?

    public init(samples: [Float], sampleRate: Double, requestedAt: ContinuousClock.Instant? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.requestedAt = requestedAt
    }
}

public struct SynthesisContext: Sendable {
    public let turnID: UUID
    public let previousRequestIDs: [String]

    public init(turnID: UUID, previousRequestIDs: [String] = []) {
        self.turnID = turnID
        self.previousRequestIDs = previousRequestIDs
    }
}

/// Thrown before the first chunk, so the caller can fall back (§3.2).
public struct SpeechEngineError: Error, Sendable, CustomStringConvertible {
    public let reason: FallbackReason
    public let detail: String

    public init(_ reason: FallbackReason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }

    public var description: String { "\(reason.rawValue): \(detail)" }
}

public protocol SpeechEngine: Actor {
    var id: EngineID { get }
    /// Streams audio for ONE sentence (or one group of sentences). Throws SpeechEngineError
    /// before the first chunk, and the caller falls back; after the first chunk, errors end it.
    func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, Error>
    /// Drops models and processes (idle, or quit).
    func release() async
    /// V1 part 5: gets ready for a request that is coming (the user is typing): starts a process
    /// and loads a model, without waiting for either. Engines with nothing to start do nothing.
    func warm() async
    /// V6: whether the next reply comes as pieces to play as they arrive (Qwen), rather than as
    /// one piece per part. SpeechQueue then plays it as one stream, never split (V5 is moot).
    func streaming() async -> Bool
    /// V6: about how long `text` will sound, in seconds, for a streamed reply's captions (the HUD
    /// needs a length before the audio has all come); nil when the engine cannot tell.
    func expectedSeconds(for text: String) async -> Double?
}

extension SpeechEngine {
    public func warm() async {}
    public func streaming() async -> Bool { false }
    public func expectedSeconds(for text: String) async -> Double? { nil }
}
