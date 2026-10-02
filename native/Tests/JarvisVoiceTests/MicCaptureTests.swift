import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// M9 part 1: the tap's conversion to 16 kHz mono Int16, the 1280-sample frames, and the mic
/// opening only between `start()` and `stop()`. A fake input stands in for the device, so no
/// test opens the microphone.
@Suite("M9 mic capture")
struct MicCaptureTests {
    /// `seconds` of a sine at `hz` in the given format, cut into tap-sized buffers.
    static func sine(rate: Double, channels: AVAudioChannelCount = 1, hz: Double = 440, amplitude: Float = 0.5,
                     seconds: Double, bufferFrames: Int = 2048) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let total = Int(rate * seconds)
        var out: [AVAudioPCMBuffer] = []
        var n = 0
        while n < total {
            let count = min(bufferFrames, total - n)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            b.frameLength = AVAudioFrameCount(count)
            for ch in 0..<Int(channels) {
                let p = b.floatChannelData![ch]
                for i in 0..<count { p[i] = amplitude * Float(sin(2 * Double.pi * hz * Double(n + i) / rate)) }
            }
            out.append(b)
            n += count
        }
        return out
    }

    static func zeroCrossings(_ x: [Int16]) -> Int {
        var c = 0
        for i in 1..<x.count where (x[i - 1] < 0) != (x[i] < 0) { c += 1 }
        return c
    }

    @Test("the slicer cuts 1280-sample frames in order and keeps the remainder")
    func slicer() {
        var s = FrameSlicer()
        let input = (0..<3865).map { Int16(truncatingIfNeeded: $0) }
        var frames: [MicFrame] = []
        var at = 0
        for size in [1000, 300, 2560, 5] {
            frames += s.append(input[at..<at + size], hostTime: UInt64(at))
            at += size
        }
        #expect(frames.count == 3)
        #expect(frames.map(\.index) == [0, 1, 2])
        #expect(frames.flatMap(\.samples) == Array(input[0..<3840]))
        #expect(frames.allSatisfy { $0.samples.count == MicFrame.sampleCount })
        #expect(s.remainder == 25)
        #expect(s.append([], hostTime: 0).isEmpty)
    }

    @Test("rms truncates like audioop.rms")
    func rms() {
        #expect(MicFrame(samples: [3, 4], index: 0).rms == 3)          // sqrt(12.5) = 3.54
        #expect(MicFrame(samples: [-32768, 32767], index: 0).rms == 32767)
        #expect(MicFrame(samples: [], index: 0).rms == 0)
        #expect(MicFrame(samples: [Int16](repeating: 1000, count: 1280), index: 0).rms == 1000)
    }

    @Test("48 kHz float becomes 16 kHz Int16 with the same pitch and level", arguments: [48_000.0, 44_100.0])
    func converts(rate: Double) throws {
        let buffers = Self.sine(rate: rate, seconds: 1)
        let converter = try MicConverter(from: buffers[0].format)
        let out = buffers.flatMap { converter.convert($0) }
        // The resampler holds a few samples back; the rest of the second comes through.
        #expect(out.count > 15_900 && out.count <= 16_000, "\(out.count) samples")
        let crossings = Self.zeroCrossings(out)
        #expect(abs(crossings - 880) <= 4, "\(crossings) zero crossings for 440 Hz")
        let peak = out.dropFirst(200).map { abs(Int($0)) }.max() ?? 0
        #expect(abs(Double(peak) - 0.5 * 32767) < 0.03 * 32767, "peak \(peak)")
    }

    @Test("a stereo input comes out as one channel at 16 kHz")
    func stereo() throws {
        let buffers = Self.sine(rate: 48_000, channels: 2, seconds: 0.5)
        let converter = try MicConverter(from: buffers[0].format)
        let out = buffers.flatMap { converter.convert($0) }
        #expect(out.count > 7_900 && out.count <= 8_000, "\(out.count) samples")
        #expect(abs(Self.zeroCrossings(out) - 440) <= 4)
    }

    @Test("a device with no channels is refused before anything starts")
    func noDevice() async {
        let fake = FakeMicInput(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                                failFormat: true)
        let mic = MicCapture(makeInput: { fake })
        await #expect(throws: MicError.self) { try await mic.start() }
        #expect(await mic.isOpen == false)
        #expect(fake.starts == 0)
    }

    @Test("the mic is open only between start and stop, and every subscriber gets every frame")
    func session() async throws {
        let fake = FakeMicInput(format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        let mic = MicCapture(makeInput: { fake })
        #expect(await mic.isOpen == false)
        #expect(fake.starts == 0 && fake.running == false)

        let a = await mic.frames()
        let b = await mic.frames()
        let readA = Task { await a.reduce(into: [MicFrame]()) { $0.append($1) } }
        let readB = Task { await b.reduce(into: [MicFrame]()) { $0.append($1) } }
        try await mic.start()
        #expect(await mic.isOpen)
        #expect(fake.running)
        for buffer in Self.sine(rate: 48_000, seconds: 1) { fake.push(buffer) }
        await mic.stop()
        #expect(await mic.isOpen == false)
        #expect(fake.running == false && fake.stops == 1)

        let framesA = await readA.value
        let framesB = await readB.value
        // 1 s at 16 kHz is 12.5 frames; the half frame waits for audio that never comes.
        #expect(framesA.count == 12)
        #expect(framesA == framesB)
        #expect(framesA.map(\.index) == Array(0..<12))

        // A second session opens the device again and counts frames from 0.
        let c = await mic.frames()
        let readC = Task { await c.reduce(into: [MicFrame]()) { $0.append($1) } }
        try await mic.start()
        try await mic.start()                     // already open: no second device
        #expect(fake.starts == 2)
        for buffer in Self.sine(rate: 48_000, seconds: 0.2) { fake.push(buffer) }
        await mic.stop()
        await mic.stop()                          // already closed: nothing to do
        #expect(fake.stops == 2)
        let framesC = await readC.value
        #expect(framesC.map(\.index) == [0, 1])
    }

    @Test("a subscriber whose reader is cancelled is dropped")
    func unsubscribe() async throws {
        let fake = FakeMicInput(format: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!)
        let mic = MicCapture(makeInput: { fake })
        let stream = await mic.frames()
        #expect(await mic.subscriberCount == 1)
        let reader = Task { for await _ in stream {} }
        reader.cancel()
        await reader.value
        for _ in 0..<100 where await mic.subscriberCount != 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await mic.subscriberCount == 0)
    }
}

/// Stands in for the device: `push` hands the tap a buffer, as the engine's thread would.
final class FakeMicInput: MicInput, @unchecked Sendable {
    private struct State {
        var tap: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
        var starts = 0
        var stops = 0
    }
    private let state = Mutex(State())
    private let format: AVAudioFormat
    private let failFormat: Bool

    init(format: AVAudioFormat, failFormat: Bool = false) {
        self.format = format
        self.failFormat = failFormat
    }

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var running: Bool { state.withLock { $0.tap != nil } }

    func inputFormat() throws(MicError) -> AVAudioFormat {
        if failFormat { throw .noInputDevice("fake: no channels") }
        return format
    }

    func start(tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
        state.withLock {
            $0.tap = tap
            $0.starts += 1
        }
    }

    func stop() {
        state.withLock {
            $0.tap = nil
            $0.stops += 1
        }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        state.withLock { $0.tap }?(buffer, 0)
    }
}
