import AVFAudio
import Foundation
import Synchronization

/// Plays speech. `play` returns when the chunk has played, or at once when its task is
/// cancelled or `stop()` is called.
public protocol SpeechPlayer: Sendable {
    func play(_ chunk: PCMChunk) async throws
    func stop() async
}

/// The one AVAudioEngine with an AVAudioPlayerNode, fed 24 kHz float32 buffers; the main mixer
/// converts them to the output device's rate. Output only: the input node is never touched, so
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

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var attached = false
    private var playing: PlaybackWait?

    public init() {
        // Float32, 24 kHz, two channels, deinterleaved: a format AVAudioFormat always accepts.
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2,
                               interleaved: false)!
    }

    /// For tests: the same player with its engine in offline manual rendering mode, rendering to
    /// `output`, so nothing reaches a device and `renderOffline` pulls what it plays. Offline,
    /// AVAudioPlayerNode never calls back `.dataPlayedBack`, so a `play` ends with `stop()` (or the
    /// watchdog).
    init(offline output: AVAudioFormat) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 2,
                               interleaved: false)!
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: Self.offlineFrames)
    }

    public func play(_ chunk: PCMChunk) async throws {
        guard !chunk.samples.isEmpty, !Task.isCancelled else { return }
        guard chunk.sampleRate == Self.sampleRate else {
            throw SpeechEngineError(.error, "the player takes 24 kHz audio, not \(chunk.sampleRate) Hz")
        }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        if !engine.isRunning {
            try engine.start()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.samples.count)),
              let channels = buffer.floatChannelData else {
            throw SpeechEngineError(.error, "cannot allocate \(chunk.samples.count) frames")
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        let part = Loudness.normalized(chunk.samples, sampleRate: Self.sampleRate, lift: Self.outputLiftDB)
        for c in 0..<Int(format.channelCount) {
            part.withUnsafeBufferPointer { channels[c].update(from: $0.baseAddress!, count: $0.count) }
        }

        let wait = PlaybackWait()
        playing = wait
        let limit = Duration.seconds(Double(chunk.samples.count) / Self.sampleRate) + Self.completionSlack
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            wait.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wait.set(continuation)
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in wait.resume() }
                node.play()
            }
        } onCancel: {
            wait.resume()
        }
        watchdog.cancel()
        if playing === wait { playing = nil }
        // A cancelled chunk is silenced here, on the actor, before the caller moves on.
        if Task.isCancelled { node.stop() }
    }

    public func stop() {
        playing?.resume()
        playing = nil
        if attached { node.stop() }
    }

    static let offlineFrames: AVAudioFrameCount = 4096

    /// For tests: the next `frames` (at most `offlineFrames`) of an offline engine's output, one
    /// array per channel; nothing while no `play` has started the engine.
    func renderOffline(frames: AVAudioFrameCount) throws -> [[Float]] {
        guard engine.isRunning else { return [] }
        let output = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: frames),
              let channels = buffer.floatChannelData else {
            throw SpeechEngineError(.error, "cannot allocate \(frames) frames")
        }
        let status = try engine.renderOffline(frames, to: buffer)
        guard status == .success else {
            throw SpeechEngineError(.error, "offline rendering returned \(status.rawValue)")
        }
        return (0..<Int(output.channelCount)).map {
            Array(UnsafeBufferPointer(start: channels[$0], count: Int(buffer.frameLength)))
        }
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
