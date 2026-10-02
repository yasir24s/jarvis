import AVFAudio
import Foundation

/// 80 ms of 16 kHz mono 16-bit audio: the frame every listener reads (plan M08-M13 §3.3).
public struct MicFrame: Sendable, Equatable {
    /// `OWW_FRAME_SAMPLES` (J:1073), and the `CHUNK` Python's microphone read (J:5497-5504).
    public static let sampleCount = 1280
    /// `MIC_RATE` (J:70).
    public static let sampleRate = 16_000.0

    public let samples: [Int16]
    /// Counts frames from 0 for each time the mic opens.
    public let index: UInt64
    /// The host time of the tap buffer that completed this frame.
    public let hostTime: UInt64

    public init(samples: [Int16], index: UInt64, hostTime: UInt64 = 0) {
        self.samples = samples
        self.index = index
        self.hostTime = hostTime
    }

    /// `audioop.rms`: the square root of the mean square, truncated to an integer (§3.4).
    public var rms: Int {
        guard !samples.isEmpty else { return 0 }
        var sumSq = 0.0
        for s in samples { sumSq += Double(s) * Double(s) }
        return Int((sumSq / Double(samples.count)).squareRoot())
    }
}

public enum MicError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The default input device reports no channels or no sample rate.
    case noInputDevice(String)
    /// No converter from the device's format to 16 kHz mono Int16.
    case cannotConvert(String)
    /// The audio engine would not start.
    case cannotStart(String)

    public var description: String {
        switch self {
        case .noInputDevice(let d): "no usable audio input (\(d))"
        case .cannotConvert(let d): "cannot convert the input to 16 kHz mono (\(d))"
        case .cannotStart(let d): "the microphone would not start (\(d))"
        }
    }
}

/// Cuts a run of samples into 1280-sample frames and keeps the remainder for the next call.
struct FrameSlicer {
    private var pending: [Int16] = []
    private(set) var nextIndex: UInt64 = 0

    init() { pending.reserveCapacity(4 * MicFrame.sampleCount) }

    mutating func append(_ samples: some Collection<Int16>, hostTime: UInt64 = 0) -> [MicFrame] {
        pending.append(contentsOf: samples)
        var frames: [MicFrame] = []
        var start = 0
        while pending.count - start >= MicFrame.sampleCount {
            frames.append(MicFrame(samples: Array(pending[start..<start + MicFrame.sampleCount]),
                                   index: nextIndex, hostTime: hostTime))
            nextIndex += 1
            start += MicFrame.sampleCount
        }
        if start > 0 { pending.removeFirst(start) }
        return frames
    }

    /// Samples waiting for a full frame.
    var remainder: Int { pending.count }
}

/// Converts the input device's buffers to 16 kHz mono Int16. One converter serves a whole
/// session, so the resampler keeps its state from one buffer to the next.
final class MicConverter {
    static let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicFrame.sampleRate,
                                      channels: 1, interleaved: true)!
    private let converter: AVAudioConverter
    private let ratio: Double

    init(from input: AVAudioFormat) throws(MicError) {
        guard input.sampleRate > 0, input.channelCount > 0 else { throw .noInputDevice("\(input)") }
        guard let c = AVAudioConverter(from: input, to: Self.target) else { throw .cannotConvert("\(input)") }
        converter = c
        ratio = MicFrame.sampleRate / input.sampleRate
    }

    /// The buffer's audio at 16 kHz. Empty when the converter fails (the caller logs nothing per
    /// buffer: a failing converter would fail on every one).
    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: capacity) else { return [] }
        let feed = StreamingInput(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in feed.next(outStatus) }
        guard status != .error, let channel = out.int16ChannelData?[0], out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Hands the converter one buffer, then `.noDataNow` rather than `.endOfStream`: the converter
/// keeps the samples it holds back for resampling and carries on with the next buffer.
final class StreamingInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var given = false

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if given {
            status.pointee = .noDataNow
            return nil
        }
        given = true
        status.pointee = .haveData
        return buffer
    }
}

/// The hardware side of `MicCapture`. The app uses `EngineMicInput`; tests use a fake that
/// pushes generated buffers, so no test opens the microphone.
public protocol MicInput: AnyObject {
    /// The format the tap will deliver. Throws when there is no usable input device.
    func inputFormat() throws(MicError) -> AVAudioFormat
    /// Delivers buffers in `inputFormat()` to `tap`, on a thread of the input's choosing, until `stop()`.
    func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError)
    /// Stops delivering and lets the device go.
    func stop()
}

/// An AVAudioEngine of its own with a tap on the input node. It is a separate engine from the
/// speech player's (`EnginePlayer`), which never touches its input node, so V1's output path is
/// unchanged. No voice processing yet: push-to-talk stops his speech before it listens.
/// The engine is created on `inputFormat()` and released on `stop()`, so nothing holds the
/// microphone between sessions.
public final class EngineMicInput: MicInput {
    /// The plan's tap size (§3.3): about 43 ms at 48 kHz.
    static let tapFrames: AVAudioFrameCount = 2048
    private var engine: AVAudioEngine?

    public init() {}

    public func inputFormat() throws(MicError) -> AVAudioFormat {
        let e = engine ?? AVAudioEngine()
        engine = e
        let format = e.inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            engine = nil
            throw .noInputDevice("\(format)")
        }
        return format
    }

    public func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
        let format = try inputFormat()
        guard let e = engine else { throw .noInputDevice("no engine") }
        e.inputNode.installTap(onBus: 0, bufferSize: Self.tapFrames, format: format) { buffer, when in
            tap(buffer, when.hostTime)
        }
        e.prepare()
        do {
            try e.start()
        } catch {
            e.inputNode.removeTap(onBus: 0)
            engine = nil
            throw .cannotStart("\(error)")
        }
    }

    public func stop() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        engine = nil
    }
}

/// The tap's own state: touched only from the tap's thread, one buffer at a time.
private final class TapState: @unchecked Sendable {
    private let converter: MicConverter
    private var slicer = FrameSlicer()
    private let out: AsyncStream<MicFrame>.Continuation

    init(converter: MicConverter, out: AsyncStream<MicFrame>.Continuation) {
        self.converter = converter
        self.out = out
    }

    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        for frame in slicer.append(converter.convert(buffer), hostTime: hostTime) { out.yield(frame) }
    }
}

/// Microphone capture for every listener (§3.3's MicPipeline): the input's buffers, converted to
/// 16 kHz mono Int16 and cut into 1280-sample frames, go out to each subscriber's `AsyncStream`.
/// The mic opens on `start()` and closes on `stop()`; it is never open otherwise.
///
/// The tap only converts, slices and yields to one stream; a task on this actor hands each frame
/// to the subscribers, so the tap neither locks nor waits on anything of ours.
public actor MicCapture {
    /// Frames a subscriber can fall behind by before the oldest are dropped: about 5 s (§3.3).
    public static let bufferedFrames = 64

    private let makeInput: @Sendable () -> any MicInput
    private let log: @Sendable (String) -> Void
    private var input: (any MicInput)?
    private var hub: AsyncStream<MicFrame>.Continuation?
    private var pump: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<MicFrame>.Continuation] = [:]

    public init(makeInput: @escaping @Sendable () -> any MicInput = { EngineMicInput() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeInput = makeInput
        self.log = log
    }

    public var isOpen: Bool { input != nil }

    var subscriberCount: Int { subscribers.count }

    /// Frames from now until the mic closes; the stream finishes at `stop()`. Subscribe before
    /// `start()` to get every frame.
    public func frames() -> AsyncStream<MicFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: MicFrame.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedFrames))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id) }
        }
        return stream
    }

    /// Opens the microphone. Does nothing when it is already open.
    public func start() throws(MicError) {
        guard input == nil else { return }
        let device = makeInput()
        let format = try device.inputFormat()
        let converter = try MicConverter(from: format)
        let (stream, continuation) = AsyncStream.makeStream(of: MicFrame.self,
                                                            bufferingPolicy: .bufferingNewest(Self.bufferedFrames))
        let state = TapState(converter: converter, out: continuation)
        do {
            try device.start { buffer, hostTime in state.process(buffer, hostTime: hostTime) }
        } catch {
            continuation.finish()
            throw error
        }
        input = device
        hub = continuation
        pump = Task { await self.fanOut(stream) }
        log("mic: open, \(Int(format.sampleRate)) Hz \(format.channelCount) ch -> 16000 Hz mono")
    }

    /// Closes the microphone. Frames already converted still reach the subscribers, then every
    /// subscriber's stream finishes.
    public func stop() async {
        guard let device = input else { return }
        input = nil
        device.stop()
        hub?.finish()
        hub = nil
        let p = pump
        pump = nil
        await p?.value
        for c in subscribers.values { c.finish() }
        subscribers.removeAll()
        log("mic: closed")
    }

    private func fanOut(_ stream: AsyncStream<MicFrame>) async {
        for await frame in stream {
            for c in subscribers.values { c.yield(frame) }
        }
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }
}
