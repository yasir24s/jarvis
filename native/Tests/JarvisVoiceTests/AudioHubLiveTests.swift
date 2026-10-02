import AVFAudio
import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import JarvisVoice

/// M11 part 1 on the real microphone, only with `JARVIS_MIC_LIVE=1`: the hub opens the default
/// input (with voice processing, and with `JARVIS_AEC=0`'s raw input), two MicCaptures read it
/// at once, and closing them lets the device go. Nothing is played. Nothing is kept: only frame
/// counts, levels and timings are printed.
@Suite("M11 audio hub, live (JARVIS_MIC_LIVE=1)", .serialized)
struct AudioHubLiveTests {
    static let enabled = ProcessInfo.processInfo.environment["JARVIS_MIC_LIVE"] == "1"

    /// Whether any process has the default input device running.
    static func inputRunningSomewhere() -> Bool? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
                                         &device) == noErr else { return nil }
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return nil }
        return running != 0
    }

    @Test(.enabled(if: AudioHubLiveTests.enabled, "set JARVIS_MIC_LIVE=1 to open the real microphone"),
          arguments: [true, false])
    func realMicrophone(voiceProcessing: Bool) async throws {
        let lines = AudioHubTests.Lines()
        let hub = AudioHub(voiceProcessing: voiceProcessing, log: { lines.add($0) })
        let before = Self.inputRunningSomewhere()
        let first = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let second = MicCapture(makeInput: { HubMicInput(hub: hub) })
        let a = await first.frames()
        let b = await second.frames()
        let readA = Task { await a.reduce(into: [MicFrame]()) { $0.append($1) } }
        let readB = Task { await b.reduce(into: [MicFrame]()) { $0.append($1) } }
        let opening = ContinuousClock.now
        try await first.start()
        let opened = ContinuousClock.now - opening
        try await second.start()
        // The raw buffers too, before any conversion: digital silence here means the process has
        // no microphone access (macOS then delivers zeros).
        let raw = HubMicInput(hub: hub)
        _ = try raw.inputFormat()
        let rawCounts = RawCounts()
        try raw.start { buffer, _ in rawCounts.add(buffer) }
        #expect(hub.currentMode == .duplex(voiceProcessing: voiceProcessing))
        let during = Self.inputRunningSomewhere()
        try await Task.sleep(for: .seconds(2))
        raw.stop()
        await first.stop()
        try await Task.sleep(for: .milliseconds(500))
        await second.stop()
        #expect(hub.currentMode == .output)
        try await Task.sleep(for: .milliseconds(500))
        let after = Self.inputRunningSomewhere()
        let framesA = await readA.value
        let framesB = await readB.value
        let rms = framesA.map(\.rms)
        print("M11 live mic (voice processing \(voiceProcessing ? "on" : "off")): opened in "
              + "\(opened.formatted(.units(allowed: [.milliseconds]))); \(framesA.count) and \(framesB.count) frames; "
              + "median rms \(rms.sorted()[rms.count / 2]); input running somewhere before \(String(describing: before)), "
              + "during \(String(describing: during)), after \(String(describing: after))")
        for line in lines.all { print("  \(line)") }
        print("  raw: \(rawCounts.summary); microphone authorization \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
        // 2 s and 2.5 s at 12.5 frames a second, less what the engine takes to start delivering.
        #expect(framesA.count >= 20)
        #expect(framesB.count >= 25)
        #expect(rms.filter { $0 > 0 }.count >= framesA.count / 2)
        #expect(during == true)
        #expect(after == before)
    }
}

/// Counts the raw input's samples, and how many are not exactly zero.
final class RawCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var samples = 0
    private var nonzero = 0
    private var peak: Float = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        guard let p = buffer.floatChannelData?[0] else { return }
        var n = 0
        var top: Float = 0
        for i in 0..<Int(buffer.frameLength) where p[i] != 0 {
            n += 1
            top = max(top, abs(p[i]))
        }
        lock.lock()
        samples += Int(buffer.frameLength)
        nonzero += n
        peak = max(peak, top)
        lock.unlock()
    }

    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "\(samples) samples, \(nonzero) not zero, peak \(peak)"
    }
}
