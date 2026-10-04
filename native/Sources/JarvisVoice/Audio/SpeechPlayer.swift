import AVFAudio
import Foundation
import Synchronization

/// Plays speech. `play` returns when the chunk has played, or at once when its task is
/// cancelled or `stop()` is called.
public protocol SpeechPlayer: Sendable {
    func play(_ chunk: PCMChunk) async throws
    func stop() async
    /// A reply has started generating (M11b): get ready to play it.
    func replyStarting() async
    /// Returns once the player is ready for the reply (`AudioHub.speechReady`).
    func replyReady() async
    /// The reply has played, was stopped, or failed. Once for every `replyStarting`.
    func replyEnded() async
    /// V6: plays a reply that comes in pieces (Qwen streams it): each piece as it arrives, straight
    /// after the one before, and returns once the last has played, or at once when its task is
    /// cancelled or `stop()` is called. An error in `pieces` ends it once what came before has
    /// played, and is thrown. `expectedSeconds` is about how long it will be, for the captions.
    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws
    /// How the last `playStream` went: how often the voice fell behind the play head. nil from a
    /// player that does not keep track.
    func lastStream() async -> StreamReport?
}

/// How a streamed reply kept up with its playing (`EnginePlayer.playStream`).
public struct StreamReport: Sendable, Equatable {
    /// Times a piece came after everything before it had played, and the silence that left.
    public var dry: Int
    public var dryMilliseconds: Int
    /// What was held back before anything played, in seconds of audio.
    public var preroll: Double
    /// The last reply's delivery rate the pre-roll was worked out from; nil when there was none.
    public var holdRate: Double?
    /// Seconds of audio the voice delivered per second, from its second piece to its last; nil
    /// when the stream was too short to tell (`DeliveryMeter`).
    public var deliveryRate: Double?

    public init(dry: Int, dryMilliseconds: Int, preroll: Double, holdRate: Double? = nil, deliveryRate: Double?) {
        self.dry = dry
        self.dryMilliseconds = dryMilliseconds
        self.preroll = preroll
        self.holdRate = holdRate
        self.deliveryRate = deliveryRate
    }
}

/// How fast a stream's pieces came, in seconds of audio a second, measured from the second
/// piece's arrival to the last (the first comes after the voice's start-up). A stream that spans
/// a second or more is measured; a shorter one only when it came faster than real time, so a
/// short fast reply still clears the last slow rate and a short slow one says nothing.
struct DeliveryMeter {
    let sampleRate: Double
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?
    private var afterFirst = 0
    private var arrivals = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    mutating func arrived(samples: Int, at instant: ContinuousClock.Instant) {
        arrivals += 1
        if first == nil {
            first = instant
        } else {
            afterFirst += samples
            last = instant
        }
    }

    var rate: Double? {
        guard let first, let last, arrivals >= 3 else { return nil }
        let span = (last - first) / .seconds(1)
        guard span > 0 else { return nil }
        let rate = Double(afterFirst) / sampleRate / span
        return span >= 1 || rate >= 1 ? rate : nil
    }
}

extension SpeechPlayer {
    public func replyStarting() async {}
    public func replyReady() async {}
    public func replyEnded() async {}
    public func lastStream() async -> StreamReport? { nil }

    /// Each piece played whole, one after the other (a player without a stream of its own).
    public func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        for try await piece in pieces {
            try await play(piece)
            if Task.isCancelled { return }
        }
    }
}

/// His speech on `AudioHub`'s speech player (M11 part 1: the one engine, so voice processing
/// hears him and cancels him from the microphone), fed 24 kHz float32 buffers; the main mixer
/// converts them to the output device's rate. While nothing listens the hub is output only, so
/// playing asks for no microphone access.
///
/// Every part goes through `Loudness.expanded` (V1 part 3: the quiet tail after each word drops
/// by up to 12 dB), gets the gain `Loudness.gain` gives it, so the output reads
/// `Loudness.targetLUFS`, then `Loudness.limited` keeps its peaks at or below
/// `Loudness.peakCeilingDBFS`.
/// The node takes two equal channels, not the mono part itself. Rendered offline, the main mixer
/// played a mono node 3.01 dB down on each channel when its output ran at 44.1 kHz, and at full
/// level at the other rates tried (16 to 96 kHz); two equal channels played at full level at every
/// one. Two equal channels read 3.01 dB louder than the mono part (BS.1770 adds the channels'
/// power), which `outputLiftDB` takes off the gain.
public actor EnginePlayer: SpeechPlayer {
    public static let sampleRate = 24_000.0
    /// How much louder the output reads than the mono part: 10 log10(2) dB, for two equal channels.
    static let outputLiftDB = 10 * log10(2.0)
    /// How long past a chunk's own length `play` waits for its completion callback. A device change
    /// can drop scheduled buffers without calling back.
    static let completionSlack = Duration.seconds(2)

    private let hub: AudioHub
    /// V6: the gain the last streamed reply ended on, the next one's starting point.
    private var streamGain: Float?
    /// How fast the last streamed reply was delivered, the next one's pre-roll (`PreRoll.hold`).
    private var deliveryRate: Double?
    private var report: StreamReport?
    /// A gap shorter than this, worked out from when each piece was queued, is not counted: the
    /// estimate leaves out the output's own latency.
    static let dryThreshold = Duration.milliseconds(10)

    public init(hub: AudioHub = .shared) {
        self.hub = hub
    }

    /// For tests: the same player on a hub whose engine is in offline manual rendering mode,
    /// rendering to `output`, so nothing reaches a device and `renderOffline` pulls what it plays.
    /// Offline, AVAudioPlayerNode never calls back `.dataPlayedBack`, so a `play` ends with
    /// `stop()` (or the watchdog).
    init(offline output: AVAudioFormat) throws {
        hub = try AudioHub(offline: output)
    }

    public func play(_ chunk: PCMChunk) async throws {
        guard !chunk.samples.isEmpty, !Task.isCancelled else { return }
        guard chunk.sampleRate == Self.sampleRate else {
            throw SpeechEngineError(.error, "the player takes 24 kHz audio, not \(chunk.sampleRate) Hz")
        }
        let part = Loudness.normalized(chunk.samples, sampleRate: Self.sampleRate, lift: Self.outputLiftDB)
        let limit = Duration.seconds(Double(chunk.samples.count) / Self.sampleRate) + Self.completionSlack
        try await hub.play(HubAudio(channels: [part, part], sampleRate: Self.sampleRate), on: .speech, limit: limit)
    }

    /// V6: the pieces go through one `LoudnessStream` (the same expander, gain and limiter as a
    /// whole part, worked out as the reply arrives) and are queued on the speech player as they
    /// come, so they play back to back while the next is generated. Its gain starts from the one the
    /// last streamed reply ended on (`LoudnessStream.prior`), and nothing plays until `PreRoll` has
    /// 0.2 s in hand, so the reply does not open with a blip and a gap; more when the last reply
    /// was delivered slower than it played (`PreRoll.hold(expected:deliveryRate:)`). A piece
    /// that arrives after the one before has finished playing leaves a pause, never a click and
    /// never a change of speed: generation fell behind. `lastStream` counts those pauses.
    public func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        let level = LoudnessStream(sampleRate: Self.sampleRate, lift: Self.outputLiftDB, prior: streamGain)
        defer { if let gain = level.gain { streamGain = gain } }
        let hold = PreRoll.hold(expected: expectedSeconds, deliveryRate: deliveryRate)
        var preroll = PreRoll(sampleRate: Self.sampleRate, seconds: hold)
        var queued: [(wait: PlaybackWait, seconds: Double)] = []
        var failure: (any Error)?
        // Where the play head will be once what is queued has played, and the pauses so far.
        var playEnd: ContinuousClock.Instant?
        var dry = 0
        var dryTime = Duration.zero
        var meter = DeliveryMeter(sampleRate: Self.sampleRate)
        let holdRate = hold > PreRoll.seconds ? deliveryRate : nil
        defer {
            let rate = meter.rate
            if !Task.isCancelled, let rate { deliveryRate = rate }
            report = StreamReport(dry: dry, dryMilliseconds: Int((dryTime / .milliseconds(1)).rounded()),
                                  preroll: hold, holdRate: holdRate, deliveryRate: rate)
        }
        func enqueue(_ samples: [Float]) throws {
            guard !samples.isEmpty, !Task.isCancelled else { return }
            let wait = try hub.enqueue(HubAudio(channels: [samples, samples], sampleRate: Self.sampleRate), on: .speech)
            let seconds = Double(samples.count) / Self.sampleRate
            queued.append((wait, seconds))
            let now = ContinuousClock.now
            if let end = playEnd, now - end >= Self.dryThreshold {
                dry += 1
                dryTime += now - end
            }
            playEnd = max(playEnd ?? now, now) + .seconds(seconds)
        }
        do {
            for try await piece in pieces {
                guard !Task.isCancelled else { break }
                guard piece.sampleRate == Self.sampleRate else {
                    throw SpeechEngineError(.error, "the player takes 24 kHz audio, not \(piece.sampleRate) Hz")
                }
                meter.arrived(samples: piece.samples.count, at: .now)
                try enqueue(preroll.take(level.push(piece.samples)))
            }
        } catch {
            failure = error
        }
        if Task.isCancelled {
            hub.stop(.speech)
            return
        }
        do {
            let rest = level.finish()
            try enqueue(preroll.flush() + rest)
        } catch {
            failure = failure ?? error
        }
        // Each wait gets the time of everything queued up to it, and the slack.
        var ahead = 0.0
        for item in queued {
            ahead += item.seconds
            await hub.played(item.wait, on: .speech, limit: .seconds(ahead) + Self.completionSlack)
            if Task.isCancelled { return }
        }
        if let failure { throw failure }
    }

    public func stop() {
        hub.stop(.speech)
    }

    public func lastStream() async -> StreamReport? {
        report
    }

    /// Voice processing comes on while the reply generates (`AudioHub.speechWillStart`).
    public func replyStarting() {
        hub.speechWillStart()
    }

    public func replyReady() async {
        await hub.speechReady()
    }

    public func replyEnded() {
        hub.speechEnded()
    }

    static let offlineFrames = SystemHubEngine.offlineFrames

    /// For tests: the next `frames` (at most `offlineFrames`) of an offline engine's output, one
    /// array per channel; nothing while no `play` has started the engine.
    func renderOffline(frames: AVAudioFrameCount) throws -> [[Float]] {
        try hub.renderOffline(frames: frames)
    }
}

/// One `play` call's wait, resumed exactly once: by the completion callback, `stop()`, the
/// task's cancellation or the watchdog, whichever comes first.
final class PlaybackWait: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Void, Never>?, done: Bool)>((nil, false))

    func set(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow = state.withLock { state -> Bool in
            if state.done { return true }
            state.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func resume() {
        let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.done = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }
}
