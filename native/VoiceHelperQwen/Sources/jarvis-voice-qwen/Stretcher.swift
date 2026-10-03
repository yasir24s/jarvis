import AVFAudio
import Foundation

/// Speeds a mono stream up (or down) by `rate` with its pitch kept: Apple's AVAudioUnitTimePitch
/// in an offline AVAudioEngine, fed chunk by chunk as the voice is generated. One stretcher is
/// one continuous stream (a reply, or a rendered line): the unit keeps its state across chunks,
/// so the output has no seams where the chunks met.
///
/// The unit pulls its input ahead of the output it makes. `push` only renders while at least
/// `margin` input samples are left over after the block, so the unit never asks for audio that
/// has not been generated yet (which would put a gap of silence into the stream); `finish` pads
/// the end with silence and renders the rest. `starved` counts input requests that could not be
/// met in full before `finish`: 0 means the output is seamless.
final class Stretcher {
    let rate: Double
    let sampleRate: Double
    /// Output frames rendered per call to the engine.
    static let block: AVAudioFrameCount = 512
    /// Input samples kept back while more audio may come: 0.13 s at 24 kHz. At 2048, one request
    /// in a stream fed 960 samples at a time came up short; at 3072 a 7.7 s render fed 100, 480,
    /// 960 and 7680 samples at a time came out identical to the same render stretched whole.
    static let margin = 3072

    private let engine = AVAudioEngine()
    private let timePitch = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private let output: AVAudioPCMBuffer
    private let input: AVAudioPCMBuffer
    private var queued: [Float] = []
    private var queuedStart = 0
    private var finishing = false
    private(set) var starved = 0
    /// Input samples taken in, and output samples handed out, so far.
    private(set) var samplesIn = 0
    private(set) var samplesOut = 0
    /// Output samples still to drop at the start: the unit's own latency.
    private var toSkip = 0

    init(rate: Double, sampleRate: Double) throws {
        self.rate = rate
        self.sampleRate = sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.block),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw StretchError("cannot make \(sampleRate) Hz mono buffers")
        }
        self.format = format
        self.output = output
        self.input = input
        timePitch.rate = Float(rate)
        timePitch.pitch = 0
        engine.attach(timePitch)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: Self.block)
        let ok = engine.inputNode.setManualRenderingInputPCMFormat(format) { [unowned self] frames in
            self.supply(Int(frames))
        }
        guard ok else { throw StretchError("the engine refused its input format") }
        engine.connect(engine.inputNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        try engine.start()
        // The unit's latency, in output samples at this rate: what comes out before the stream's
        // first sample does.
        toSkip = Int((timePitch.latency * sampleRate).rounded())
    }

    deinit {
        engine.stop()
    }

    /// Adds `samples` and returns the output that can be rendered without running out of input.
    func push(_ samples: [Float]) throws -> [Float] {
        queued.append(contentsOf: samples)
        samplesIn += samples.count
        return try render(final: false)
    }

    /// Ends the stream: renders what is left, so that the whole output is `samplesIn / rate` long.
    func finish() throws -> [Float] {
        finishing = true
        return try render(final: true)
    }

    private var available: Int { queued.count - queuedStart }

    private func render(final: Bool) throws -> [Float] {
        var out: [Float] = []
        let need = Int((Double(Self.block) * rate).rounded(.up))
        let total = Int((Double(samplesIn) / rate).rounded())
        while true {
            if final {
                guard samplesOut < total else { break }
            } else {
                guard available >= need + Self.margin else { break }
            }
            output.frameLength = 0
            let status = try engine.renderOffline(Self.block, to: output)
            guard status == .success else {
                throw StretchError("render status \(status.rawValue)")
            }
            let frames = Int(output.frameLength)
            guard frames > 0, let data = output.floatChannelData?[0] else { break }
            var start = 0
            if toSkip > 0 {
                start = min(toSkip, frames)
                toSkip -= start
            }
            var take = frames - start
            if final { take = min(take, total - samplesOut) }
            if take > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: data + start, count: take))
                samplesOut += take
            }
        }
        compact()
        return out
    }

    /// The input block: `frames` samples of the queue, silence past its end once finishing.
    private func supply(_ frames: Int) -> UnsafePointer<AudioBufferList>? {
        let frames = min(frames, Int(input.frameCapacity))
        guard let data = input.floatChannelData?[0] else { return nil }
        let have = min(frames, available)
        if have < frames && !finishing { starved += 1 }
        queued.withUnsafeBufferPointer { q in
            if have > 0 { data.update(from: q.baseAddress! + queuedStart, count: have) }
        }
        if have < frames { (data + have).update(repeating: 0, count: frames - have) }
        queuedStart += have
        input.frameLength = AVAudioFrameCount(frames)
        return UnsafePointer(input.audioBufferList)
    }

    private func compact() {
        if queuedStart > 65_536 {
            queued.removeFirst(queuedStart)
            queuedStart = 0
        }
    }
}

struct StretchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
