import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// M11 part 1: the one engine (plan M08-M13 §3.3). A fake engine stands in for AVAudioEngine, so
/// no test opens the microphone or plays a sound; the offline tests render the real graph to
/// buffers.
@Suite("M11 audio hub")
struct AudioHubTests {
    /// What voice processing delivered on a MacBook Pro: 7 channels at 96 kHz.
    static let processedFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 96_000, interleaved: false,
        channelLayout: AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 7)!)
    static let rawFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// `seconds` of input in `format`, cut into 2048-frame buffers: channel 0 carries a 440 Hz sine
    /// at 0.5, and every other channel a 1 kHz sine at 0.5.
    static func input(_ format: AVAudioFormat, seconds: Double) -> [AVAudioPCMBuffer] {
        let rate = format.sampleRate
        let total = Int(rate * seconds)
        var out: [AVAudioPCMBuffer] = []
        var n = 0
        while n < total {
            let count = min(2048, total - n)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            b.frameLength = AVAudioFrameCount(count)
            for ch in 0..<Int(format.channelCount) {
                let hz = ch == 0 ? 440.0 : 1000.0
                let p = b.floatChannelData![ch]
                for i in 0..<count { p[i] = 0.5 * Float(sin(2 * Double.pi * hz * Double(n + i) / rate)) }
            }
            out.append(b)
            n += count
        }
        return out
    }

    final class Lines: @unchecked Sendable {
        private let lines = Mutex<[String]>([])
        func add(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    static func hub(_ engine: FakeHubEngine, voiceProcessing: Bool = true, lines: Lines = Lines()) -> AudioHub {
        AudioHub(engine: engine, voiceProcessing: voiceProcessing, log: { lines.add($0) })
    }

    static let speech = HubAudio(channels: [[Float](repeating: 0.1, count: 2400)], sampleRate: 24_000)

    @Test("JARVIS_AEC=0 turns voice processing off; anything else leaves it on")
    func environment() {
        #expect(AudioHub.voiceProcessing(environment: [:]))
        #expect(AudioHub.voiceProcessing(environment: ["JARVIS_AEC": "1"]))
        #expect(!AudioHub.voiceProcessing(environment: ["JARVIS_AEC": "0"]))
    }

    @Test("speaking needs no microphone: the engine starts output only, and nothing is rebuilt")
    func speakingOnly() async throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        try await hub.play(Self.speech, on: .speech, limit: .seconds(5))
        #expect(engine.builds.isEmpty)
        #expect(engine.isRunning)
        #expect(engine.scheduled.map(\.player) == [.speech])
        #expect(hub.currentMode == .output)
        #expect(!hub.isInputOpen)
    }

    @Test("the first input opens the microphone with voice processing, and the last one closes it")
    func openAndClose() throws {
        let engine = FakeHubEngine()
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let a = HubMicInput(hub: hub)
        let b = HubMicInput(hub: hub)
        let format = try a.inputFormat()
        #expect(format.channelCount == 7 && format.sampleRate == 96_000)
        #expect(engine.builds == [.duplex(voiceProcessing: true)])
        #expect(engine.isRunning)
        _ = try b.inputFormat()
        #expect(engine.builds.count == 1)
        a.stop()
        #expect(hub.currentMode == .duplex(voiceProcessing: true))
        b.stop()
        #expect(engine.builds == [.duplex(voiceProcessing: true), .output])
        // Output only, the engine waits for the next part: nothing holds the microphone.
        #expect(!engine.isRunning)
        #expect(!hub.isInputOpen)
        b.stop()
        #expect(engine.builds.count == 2)
        #expect(lines.all.contains { $0.hasPrefix("audio: microphone open, voice processing on, 7 ch 96000 Hz") })
        #expect(lines.all.contains { $0.hasPrefix("audio: output only (the microphone closed)") })
    }

    @Test("with JARVIS_AEC=0 the microphone opens without voice processing")
    func withoutVoiceProcessing() throws {
        let engine = FakeHubEngine(duplexFormat: Self.rawFormat)
        let hub = Self.hub(engine, voiceProcessing: false)
        let input = HubMicInput(hub: hub)
        let format = try input.inputFormat()
        #expect(format.channelCount == 1 && format.sampleRate == 48_000)
        #expect(engine.builds == [.duplex(voiceProcessing: false)])
        input.stop()
    }

    @Test("every open MicCapture gets every buffer, as channel 0 of the 7-channel input at 16 kHz")
    func fanOut() async throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        let first = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let second = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let a = await first.frames()
        let b = await second.frames()
        let readA = Task { await a.reduce(into: [MicFrame]()) { $0.append($1) } }
        let readB = Task { await b.reduce(into: [MicFrame]()) { $0.append($1) } }
        try await first.start()
        try await second.start()
        #expect(engine.builds.count == 1)
        for buffer in Self.input(Self.processedFormat, seconds: 1) { engine.push(buffer) }
        await first.stop()
        await second.stop()
        #expect(engine.builds.last == .output)
        let framesA = await readA.value
        let framesB = await readB.value
        #expect(framesA.count == 12)
        #expect(framesA.map(\.samples) == framesB.map(\.samples))
        let samples = framesA.flatMap(\.samples)
        // Channel 0's 440 Hz, not the other channels' 1 kHz, and not a mix (a mix of seven would
        // not keep channel 0's level).
        #expect(abs(MicCaptureTests.zeroCrossings(samples) - 880 * samples.count / 16_000) <= 6)
        let peak = samples.dropFirst(200).map { abs(Int($0)) }.max() ?? 0
        #expect(abs(Double(peak) - 0.5 * 32767) < 0.03 * 32767, "peak \(peak)")
    }

    @Test("buffers in a new format after a device change are converted from it")
    func formatChange() async throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        let mic = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let frames = await mic.frames()
        let read = Task { await frames.reduce(into: [MicFrame]()) { $0.append($1) } }
        try await mic.start()
        for buffer in Self.input(Self.processedFormat, seconds: 0.5) { engine.push(buffer) }
        for buffer in Self.input(Self.rawFormat, seconds: 0.5) { engine.push(buffer) }
        await mic.stop()
        let samples = await read.value.flatMap(\.samples)
        // A second of audio is 12 frames; the first converter's held-back samples may cost one.
        #expect(samples.count >= 11 * MicFrame.sampleCount, "\(samples.count) samples")
        #expect(abs(MicCaptureTests.zeroCrossings(samples) - 880 * samples.count / 16_000) <= 10)
    }

    @Test("opening the microphone cuts the part being spoken short, and says so")
    func rebuildCutsSpeech() async throws {
        let engine = FakeHubEngine(playsAtOnce: false)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let playing = Task { try await hub.play(Self.speech, on: .speech, limit: .seconds(30)) }
        for _ in 0..<500 where engine.scheduled.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(engine.scheduled.count == 1)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        try await playing.value
        #expect(lines.all.contains("audio: rebuilding the engine cut 1 part of speech short"))
        input.stop()
    }

    @Test("stop ends the part being spoken and stops its player")
    func stopSpeech() async throws {
        let engine = FakeHubEngine(playsAtOnce: false)
        let hub = Self.hub(engine)
        let playing = Task { try await hub.play(Self.speech, on: .speech, limit: .seconds(30)) }
        for _ in 0..<500 where engine.scheduled.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        hub.stop(.speech)
        try await playing.value
        #expect(engine.stoppedPlayers == [.speech])
    }

    @Test("a microphone that will not start leaves the hub output only, and speech still plays")
    func cannotStart() async throws {
        let engine = FakeHubEngine()
        engine.failDuplexStart = true
        let hub = Self.hub(engine)
        let input = HubMicInput(hub: hub)
        #expect(throws: MicError.self) { try input.inputFormat() }
        #expect(engine.builds == [.duplex(voiceProcessing: true), .output])
        #expect(!hub.isInputOpen)
        try await hub.play(Self.speech, on: .speech, limit: .seconds(5))
        #expect(engine.scheduled.count == 1)
    }

    @Test("a device change rebuilds an engine it stopped, and leaves one still running as built alone")
    func deviceChange() throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        // The notifications a start sets off: the engine runs as built, nothing to do.
        hub.reconcile(force: false, reason: "test", attempt: 0)
        #expect(engine.builds.count == 1)
        // The engine stopped itself when the device changed: rebuilt in the same mode, restarted.
        engine.stopByItself()
        hub.reconcile(force: false, reason: "test", attempt: 0)
        #expect(engine.builds == [.duplex(voiceProcessing: true), .duplex(voiceProcessing: true)])
        #expect(engine.isRunning)
        // Still running, but the input's format moved: rebuilt.
        engine.moveInput(to: Self.rawFormat)
        hub.reconcile(force: false, reason: "test", attempt: 0)
        #expect(engine.builds.count == 3)
        // A new default input: rebuilt even though it runs.
        hub.reconcile(force: true, reason: "test", attempt: 0)
        #expect(engine.builds.count == 4)
        input.stop()
        #expect(engine.builds.last == .output)
        // Output only, a new default input changes nothing.
        hub.reconcile(force: true, reason: "test", attempt: 0)
        #expect(engine.builds.count == 5)
    }

    @Test("output only, a device change that stopped the engine rebuilds it, and the next part starts it")
    func outputDeviceChange() async throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        try await hub.play(Self.speech, on: .speech, limit: .seconds(5))
        engine.stopByItself()
        hub.reconcile(force: false, reason: "test", attempt: 0)
        #expect(engine.builds == [.output])
        #expect(!engine.isRunning)
        try await hub.play(Self.speech, on: .speech, limit: .seconds(5))
        #expect(engine.isRunning)
    }

    @Test("the engine's device-change notice reaches the hub, which rebuilds after it settles")
    func notice() async throws {
        let engine = FakeHubEngine()
        let hub = Self.hub(engine)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        engine.stopByItself()
        engine.deviceChanges.fire(force: false)
        for _ in 0..<300 where engine.builds.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.builds.count == 2)
        #expect(engine.isRunning)
        hub.rebind(reason: "250 silent frames")
        for _ in 0..<300 where engine.builds.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(engine.builds.count == 3)
        input.stop()
    }

    // MARK: the real graph, offline

    @Test("the effect player plays a chime at its own level, on both channels")
    func effectOffline() async throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let hub = try AudioHub(offline: output)
        let tone = (0..<24_000).map { Float(0.25 * sin(2 * Double.pi * 1000 * Double($0) / 48_000)) }
        let playing = Task { try await hub.play(HubAudio(channels: [tone], sampleRate: 48_000), on: .effect,
                                                limit: .seconds(30)) }
        var out: [[Float]] = [[], []]
        var waits = 0
        while out[0].count < 24_000 {
            let next = try hub.renderOffline(frames: SystemHubEngine.offlineFrames)
            guard !next.isEmpty else {
                waits += 1
                try #require(waits < 2000, "the hub never started its engine")
                try await Task.sleep(for: .milliseconds(1))
                continue
            }
            for c in out.indices { out[c] += next[c] }
        }
        hub.stop(.effect)
        try await playing.value
        #expect(out[0] == out[1])
        let peak = out[0].map { abs($0) }.max() ?? 0
        #expect(abs(peak - 0.25) < 0.001, "peak \(peak)")
    }

    @Test("the offline engine has no microphone")
    func offlineHasNoInput() throws {
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let hub = try AudioHub(offline: output)
        #expect(throws: MicError.self) { try HubMicInput(hub: hub).inputFormat() }
        #expect(hub.currentMode == .output)
    }
}

/// Stands in for AVAudioEngine under the hub: it records what the hub asks of it, and `push`
/// hands the input tap a buffer, as the engine's thread would.
final class FakeHubEngine: HubEngine, @unchecked Sendable {
    private struct State {
        var builds: [HubMode] = []
        var mode = HubMode.output
        var running = false
        var tap: (@Sendable (AVAudioPCMBuffer, UInt64) -> Void)?
        var builtFormat: AVAudioFormat?
        var currentFormat: AVAudioFormat?
        var scheduled: [(player: HubPlayer, frames: Int)] = []
        var stoppedPlayers: [HubPlayer] = []
        var failDuplexStart = false
    }
    private let state = Mutex(State())
    let deviceChanges = DeviceChangeRelay()
    private let duplexFormat: AVAudioFormat
    private let playsAtOnce: Bool

    init(duplexFormat: AVAudioFormat = AudioHubTests.processedFormat, playsAtOnce: Bool = true) {
        self.duplexFormat = duplexFormat
        self.playsAtOnce = playsAtOnce
    }

    var builds: [HubMode] { state.withLock { $0.builds } }
    var scheduled: [(player: HubPlayer, frames: Int)] { state.withLock { $0.scheduled } }
    var stoppedPlayers: [HubPlayer] { state.withLock { $0.stoppedPlayers } }
    var failDuplexStart: Bool {
        get { state.withLock { $0.failDuplexStart } }
        set { state.withLock { $0.failDuplexStart = newValue } }
    }

    func build(_ mode: HubMode, tap: @escaping @Sendable (AVAudioPCMBuffer, UInt64) -> Void) throws(MicError) {
        let format = duplexFormat
        state.withLock {
            $0.running = false
            $0.builds.append(mode)
            $0.mode = mode
            $0.tap = mode.hasInput ? tap : nil
            $0.builtFormat = mode.hasInput ? format : nil
            $0.currentFormat = $0.builtFormat
        }
    }

    var isRunning: Bool { state.withLock { $0.running } }

    func start() throws(MicError) {
        let fail = state.withLock { $0.failDuplexStart && $0.mode.hasInput }
        if fail { throw .cannotStart("fake: will not start") }
        state.withLock { $0.running = true }
    }

    func stop() {
        state.withLock { $0.running = false }
    }

    var inputFormat: AVAudioFormat? { state.withLock { $0.builtFormat } }
    var currentInputFormat: AVAudioFormat? { state.withLock { $0.currentFormat } }

    func format(of player: HubPlayer) -> AVAudioFormat {
        player == .speech ? SystemHubEngine.speechFormat : SystemHubEngine.effectFormat
    }

    func schedule(_ buffer: AVAudioPCMBuffer, on player: HubPlayer, played: @escaping @Sendable () -> Void) {
        let frames = Int(buffer.frameLength)
        state.withLock { $0.scheduled.append((player, frames)) }
        if playsAtOnce { played() }
    }

    func stop(_ player: HubPlayer) {
        state.withLock { $0.stoppedPlayers.append(player) }
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        state.withLock { $0.tap }?(buffer, 0)
    }

    /// The engine stops itself, as AVAudioEngine does when a device changes.
    func stopByItself() {
        state.withLock { $0.running = false }
    }

    /// The input's format moves under the running engine.
    func moveInput(to format: AVAudioFormat) {
        state.withLock { $0.currentFormat = format }
    }
}
