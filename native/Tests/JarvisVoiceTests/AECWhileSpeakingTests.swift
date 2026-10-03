import AVFAudio
import Foundation
import JarvisCore
import Synchronization
import Testing
@testable import JarvisVoice

/// M11b: voice processing only while he speaks. A fake engine stands in for AVAudioEngine, so no
/// test opens the microphone or plays a sound.
@Suite("M11b voice processing while he speaks", .serialized)
struct AECWhileSpeakingTests {
    typealias Lines = AudioHubTests.Lines
    static let plain = AudioHubTests.rawFormat
    static let processed = AudioHubTests.processedFormat
    static let on = HubMode.duplex(voiceProcessing: true)
    static let off = HubMode.duplex(voiceProcessing: false)

    static func hub(_ engine: FakeHubEngine, _ aec: AECPolicy = .whileSpeaking, lines: Lines = Lines()) -> AudioHub {
        AudioHub(engine: engine, aec: aec, log: { lines.add($0) })
    }

    /// Polls `condition` every 10 ms for up to `limit`.
    static func until(_ limit: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("the microphone opens without voice processing; a reply turns it on, and it goes off a second after")
    func onWhileSpeaking() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let input = HubMicInput(hub: hub)
        let format = try input.inputFormat()
        #expect(format.channelCount == 1 && format.sampleRate == 48_000)
        #expect(engine.builds == [Self.off])
        hub.speechWillStart()
        #expect(await Self.until { engine.builds == [Self.off, Self.on] })
        #expect(engine.isRunning)
        hub.speechEnded()
        // The room's tail: still on just after the reply.
        try await Task.sleep(for: .milliseconds(500))
        #expect(engine.builds == [Self.off, Self.on])
        #expect(await Self.until { engine.builds == [Self.off, Self.on, Self.off] })
        #expect(lines.all.contains { $0.contains("voice processing on, 7 ch 96000 Hz (he is about to speak)") })
        #expect(lines.all.contains { $0.contains("voice processing off, 1 ch 48000 Hz (he has finished speaking)") })
        input.stop()
        #expect(engine.builds.last == .output)
    }

    @Test("a reply that starts within the tail keeps voice processing on")
    func nextReplyInTheTail() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let hub = Self.hub(engine)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        hub.speechWillStart()
        #expect(await Self.until { engine.builds.last == Self.on })
        hub.speechEnded()
        try await Task.sleep(for: .milliseconds(600))
        hub.speechWillStart()
        try await Task.sleep(for: .milliseconds(900))
        #expect(engine.builds == [Self.off, Self.on])
        hub.speechEnded()
        #expect(await Self.until { engine.builds == [Self.off, Self.on, Self.off] })
        input.stop()
    }

    @Test("no switch while anything plays: it waits for the audio to end, and cuts nothing")
    func neverWhilePlaying() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain, playsAtOnce: false)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        // An acknowledgement plays; a reply starts generating meanwhile.
        let ack = Task { try await hub.play(AudioHubTests.speech, on: .speech, limit: .seconds(10)) }
        #expect(await Self.until { engine.scheduled.count == 1 })
        hub.speechWillStart()
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.builds == [Self.off])
        engine.finishPlaying()
        try await ack.value
        #expect(await Self.until { engine.builds == [Self.off, Self.on] })
        // The reply plays; it ends, and a chime starts within the tail: off waits for it.
        let reply = Task { try await hub.play(AudioHubTests.speech, on: .speech, limit: .seconds(10)) }
        #expect(await Self.until { engine.scheduled.count == 2 })
        engine.finishPlaying()
        try await reply.value
        hub.speechEnded()
        let chime = Task { try await hub.play(AudioHubTests.speech, on: .speech, limit: .seconds(10)) }
        #expect(await Self.until { engine.scheduled.count == 3 })
        try await Task.sleep(for: .milliseconds(1500))
        #expect(engine.builds == [Self.off, Self.on])
        engine.finishPlaying()
        try await chime.value
        #expect(await Self.until { engine.builds == [Self.off, Self.on, Self.off] })
        #expect(!lines.all.contains { $0.contains("cut") })
        input.stop()
    }

    @Test("a reply that finished generating first waits for the switch, and says how long")
    func readyWaits() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        engine.buildDelay = 0.4
        let began = ContinuousClock.now
        hub.speechWillStart()
        await hub.speechReady()
        #expect(ContinuousClock.now - began >= .milliseconds(350))
        #expect(engine.mode == Self.on)
        #expect(lines.all.contains { $0.hasPrefix("audio: the reply waited") && $0.hasSuffix("processing switch") })
        engine.buildDelay = 0
        hub.speechEnded()
        input.stop()
    }

    @Test("with nothing listening a reply switches nothing, and speechReady returns at once")
    func nothingListening() async {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        hub.speechWillStart()
        await hub.speechReady()
        hub.speechEnded()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.builds.isEmpty)
        #expect(!lines.all.contains { $0.contains("waited") })
    }

    @Test("JARVIS_AEC=1 keeps voice processing on, and 0 never turns it on, whatever he says")
    func fixedPolicies() async throws {
        for (aec, mode) in [(AECPolicy.always, Self.on), (.never, Self.off)] {
            let engine = FakeHubEngine(plainFormat: Self.plain)
            let hub = Self.hub(engine, aec)
            let input = HubMicInput(hub: hub)
            _ = try input.inputFormat()
            hub.speechWillStart()
            await hub.speechReady()
            hub.speechEnded()
            try await Task.sleep(for: .milliseconds(1200))
            #expect(engine.builds == [mode], "\(aec)")
            input.stop()
        }
    }

    @Test("a failed switch leaves the microphone working as it was, and is not retried until the next reply")
    func failedSwitch() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        engine.failVoiceProcessing = true
        hub.speechWillStart()
        #expect(await Self.until { lines.all.contains { $0.contains("cannot switch voice processing on") } })
        #expect(await Self.until { engine.isRunning })
        engine.failVoiceProcessing = false
        await hub.speechReady()   // nothing pending: the failed mode is not tried again
        #expect(!lines.all.contains { $0.contains("waited") })
        #expect(Array(engine.builds.prefix(3)) == [Self.off, Self.on, Self.off])
        #expect(hub.currentMode == Self.off)
        hub.speechEnded()
        input.stop()
    }

    @Test("the microphone gap across a switch is measured from the buffers' host times")
    func gapIsMeasured() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let mic = MicCapture(makeInput: { HubMicInput(hub: hub) })
        _ = await mic.frames()
        try await mic.start()
        let before = AudioHubTests.input(Self.plain, seconds: 0.05)[0]
        engine.push(before, hostTime: mach_absolute_time())
        hub.speechWillStart()
        #expect(await Self.until { engine.mode == Self.on })
        try await Task.sleep(for: .milliseconds(200))
        engine.push(AudioHubTests.input(Self.processed, seconds: 0.05)[0], hostTime: mach_absolute_time())
        let line = try #require(lines.all.first { $0.contains("the microphone missed") })
        let ms = try #require(Int(line.split(separator: " ")[4]))
        // 200 ms of waiting, less the 2048 frames (42.7 ms) the first buffer held.
        #expect(ms >= 150 && ms < 1000, "\(line)")
        hub.speechEnded()
        await mic.stop()
    }

    // MARK: through the speech queue

    /// A reply through SpeechQueue and EnginePlayer on a hub with a fake engine.
    @Test("a reply turns voice processing on before it plays and keeps it on to the end; an acknowledgement does not")
    func throughTheQueue() async throws {
        let engine = FakeHubEngine(plainFormat: Self.plain, playsAtOnce: false)
        let lines = Lines()
        let hub = Self.hub(engine, lines: lines)
        let input = HubMicInput(hub: hub)
        _ = try input.inputFormat()
        engine.buildDelay = 0.3
        let voice = FakeEngine(.f5, respond: { _ in [Float](repeating: 0.1, count: 2400) })
        let queue = SpeechQueue(engine: voice, fallback: FakeEngine(.say, respond: { _ in [] }),
                                player: EnginePlayer(hub: hub), log: { lines.add($0) })
        // An acknowledgement alone: no switch.
        await queue.acknowledge(PCMChunk(samples: [Float](repeating: 0.2, count: 2400), sampleRate: 24_000),
                                line: "On it.", sentAt: .now)
        #expect(await Self.until { engine.scheduled.count == 1 })
        engine.finishPlaying()
        await queue.idle()
        try await Task.sleep(for: .milliseconds(1200))
        #expect(engine.builds == [Self.off])
        // A reply: generated faster than the switch, so it waits for voice processing.
        await queue.say("Here is the answer.", turn: UUID())
        #expect(await Self.until { engine.scheduled.count == 2 })
        #expect(engine.scheduledModes.last == Self.on)
        #expect(lines.all.contains { $0.hasPrefix("audio: the reply waited") })
        try await Task.sleep(for: .milliseconds(1300))
        #expect(engine.builds == [Self.off, Self.on], "nothing switches while the reply plays")
        engine.finishPlaying()
        await queue.idle()
        #expect(await Self.until { engine.builds == [Self.off, Self.on, Self.off] })
        #expect(!lines.all.contains { $0.contains("cut") })
        input.stop()
    }

    // MARK: the wake word near a switch

    /// The microphone's missed sound across a switch, measured on a MacBook Pro with
    /// `--selftest-listen <s> switch` (M11b, two runs): 833 to 1523 ms when voice processing goes
    /// on (9 switches), 457 to 661 ms when it goes off (8). These are the worst seen, rounded up.
    static let gapOn = 1.55
    static let gapOff = 0.7

    /// `pcm` (16 kHz) as float buffers in `format` (48 or 96 kHz, an exact multiple), linearly
    /// interpolated, channel 0 carrying it and every other channel the same.
    static func buffers(_ pcm: ArraySlice<Int16>, _ format: AVAudioFormat) -> [AVAudioPCMBuffer] {
        let factor = Int(format.sampleRate / 16_000)
        let samples = Array(pcm).map { Float($0) / 32768 }
        var up = [Float](repeating: 0, count: samples.count * factor)
        for i in 0..<samples.count {
            let a = samples[i], b = i + 1 < samples.count ? samples[i + 1] : samples[i]
            for k in 0..<factor { up[i * factor + k] = a + (b - a) * Float(k) / Float(factor) }
        }
        var out: [AVAudioPCMBuffer] = []
        var n = 0
        while n < up.count {
            let count = min(2048, up.count - n)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            b.frameLength = AVAudioFrameCount(count)
            for ch in 0..<Int(format.channelCount) {
                up.withUnsafeBufferPointer { b.floatChannelData![ch].update(from: $0.baseAddress! + n, count: count) }
            }
            out.append(b)
            n += count
        }
        return out
    }

    /// The clip through the hub and MicCapture, with a switch (voice processing `toOn`) at
    /// `gapStart` seconds into it and `gap` seconds of sound lost to it; the wake word's top score.
    static func scoreAcrossSwitch(_ clip: [Int16], gapStart: Double?, gap: Double, toOn: Bool,
                                  detector: WakeWordDetector) async throws -> Float {
        let engine = FakeHubEngine(plainFormat: plain)
        let hub = Self.hub(engine)
        if !toOn { hub.speechWillStart() }   // the microphone opens with voice processing
        let mic = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let frames = await mic.frames()
        let collect = Task { await frames.reduce(into: [MicFrame]()) { $0.append($1) } }
        try await mic.start()
        let first = toOn ? plain : processed
        let second = toOn ? processed : plain
        let cut = gapStart.map { min(clip.count, Int($0 * 16_000)) } ?? clip.count
        for b in buffers(clip[0..<cut], first) { engine.push(b) }
        if gapStart != nil {
            if toOn { hub.speechWillStart() } else { hub.speechEnded() }
            let target: HubMode = .duplex(voiceProcessing: toOn)
            _ = await until(.seconds(3)) { engine.mode == target }
            let resume = min(clip.count, cut + Int(gap * 16_000))
            for b in buffers(clip[resume...], second) { engine.push(b) }
        }
        await mic.stop()
        let got = await collect.value
        try detector.reset()
        var top: Float = 0
        for frame in got {
            top = max(top, try detector.process(frame.samples))
            await Task.yield()
        }
        return top
    }

    /// Where the speech is in a clip: the first and last sample louder than -30 dBFS.
    static func speech(_ clip: [Int16]) -> (onset: Double, end: Double) {
        let loud = clip.indices.filter { abs(Int(clip[$0])) > 1036 }
        return (Double(loud.first ?? 0) / 16_000, Double(loud.last ?? 0) / 16_000)
    }

    @Test("a wake word half a second from a switch, with the measured gap",
          arguments: ["wake_hey_daniel_200", "wake_hey_samantha_200", "wake_time_daniel_200"])
    func wakeNearSwitch(_ name: String) async throws {
        // Two more seconds of the clip's own noise floor before it, room for a whole gap.
        let raw = try WakeCorpus.clip(name)
        let floor = Array(raw[0..<8000])
        let clip = floor + floor + floor + floor + raw
        let detector = try WakeModels.detector(WakeSeed())
        let (onset, end) = Self.speech(clip)
        let baseline = try await Self.scoreAcrossSwitch(clip, gapStart: nil, gap: 0, toOn: true, detector: detector)
        #expect(baseline >= 0.5, "\(name) without a switch: \(baseline)")
        var report = ["\(name): speech \(String(format: "%.2f", onset))-\(String(format: "%.2f", end)) s, "
                      + "no switch \(String(format: "%.3f", baseline))"]
        for (toOn, gap) in [(true, Self.gapOn), (false, Self.gapOff)] {
            let label = toOn ? "on" : "off"
            // The switch ends 0.5 s before he speaks, starts 0.5 s before, or starts 0.5 s after.
            let cases: [(String, Double, Bool?)] = [
                ("switch done 0.5 s before", onset - 0.5 - gap, true),
                ("switch starts 0.5 s before", onset - 0.5, nil),
                ("switch starts 0.5 s after", end + 0.5, true),
            ]
            for (what, start, mustFire) in cases where start >= 0 {
                let top = try await Self.scoreAcrossSwitch(clip, gapStart: start, gap: gap, toOn: toOn,
                                                           detector: detector)
                report.append("  \(label) (\(Int(gap * 1000)) ms gap), \(what): \(String(format: "%.3f", top))"
                              + (top >= 0.5 ? " caught" : " MISSED"))
                if mustFire == true { #expect(top >= 0.5, "\(name) \(label) \(what): \(top)") }
            }
        }
        print("M11b wake near switch\n" + report.joined(separator: "\n"))
    }
}
