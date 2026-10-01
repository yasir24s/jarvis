import AVFAudio
import Foundation
import Synchronization

/// Plays speech. `play` returns when the chunk has played, or at once when its task is
/// cancelled or `stop()` is called.
public protocol SpeechPlayer: Sendable {
    func play(_ chunk: PCMChunk) async throws
    func stop() async
}

/// The one AVAudioEngine with an AVAudioPlayerNode, fed 24 kHz mono float32 buffers; the main
/// mixer converts them to the output device's rate. Output only: the input node is never touched,
/// so playing asks for no microphone access.
public actor EnginePlayer: SpeechPlayer {
    public static let sampleRate = 24_000.0
    /// How long past a chunk's own length `play` waits for its completion callback. A device change
    /// can drop scheduled buffers without calling back.
    static let completionSlack = Duration.seconds(2)

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var attached = false
    private var playing: PlaybackWait?

    public init() {
        // Float32, 24 kHz, mono, deinterleaved: a format AVAudioFormat always accepts.
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1,
                               interleaved: false)!
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
              let channel = buffer.floatChannelData?[0] else {
            throw SpeechEngineError(.error, "cannot allocate \(chunk.samples.count) frames")
        }
        buffer.frameLength = AVAudioFrameCount(chunk.samples.count)
        chunk.samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: $0.count) }

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
