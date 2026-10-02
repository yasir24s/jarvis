import Foundation

/// Barge-in's rule (J:675-718, plan §3.6), without the devices: a run of `framesNeeded` voiced
/// 80 ms frames (800 ms) is handed over for the voice check; an unvoiced frame resets the run, and
/// so does a check that does not match.
public struct BargeInRun: Sendable {
    /// `BARGE_IN_MS // 80`.
    public static let framesNeeded = 800 / 80

    private var run = 0
    private var buffer: [Int16] = []

    public init() {}

    /// One frame and whether the VAD heard a voice in it. The clip to check when the run is long
    /// enough; the caller calls `reset()` when it does not match.
    public mutating func feed(_ frame: [Int16], voiced: Bool) -> [Int16]? {
        guard voiced else {
            reset()
            return nil
        }
        run += 1
        buffer += frame
        return run >= Self.framesNeeded ? buffer : nil
    }

    public mutating func reset() {
        run = 0
        buffer.removeAll(keepingCapacity: true)
    }
}

/// `_barge_in_watch` (J:691-718): while he speaks, listens for the user talking over him.
///
/// - Only with `JARVIS_BARGE_IN` not "0" (`BARGE_IN_ENABLED`), a voiceprint enrolled, and the
///   microphone open: the app checks these before `watch`.
/// - A frame is voiced when any of its four 20 ms subframes is speech to WebRTC VAD in mode 3
///   (the most aggressive), checked in order and stopping at the first, as Python's `any` does.
/// - Ten voiced frames in a row go to `matchesForBargeIn`, which fails closed: no voiceprint, too
///   little speech or no match all mean "do not interrupt". His own voice, leaking into the
///   microphone past the echo cancelling, is not the user's, so the check is the last guard.
/// - The audio is not replayed into the next listen (Python parity).
public actor BargeInWatcher {
    /// `BARGE_IN_ENABLED`: `JARVIS_BARGE_IN` not "0".
    public static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["JARVIS_BARGE_IN"] != "0"
    }

    static let subframe = 320

    private let makeVAD: @Sendable () throws -> WebRTCVAD
    private let speaker: any SpeakerVerifying
    private let log: @Sendable (String) -> Void
    private var vad: WebRTCVAD?
    private var vadFailed = false

    /// - makeVAD: py-webrtcvad's Vad(3) from the vendored module; built on the first watch.
    public init(makeVAD: @escaping @Sendable () throws -> WebRTCVAD, speaker: any SpeakerVerifying,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeVAD = makeVAD
        self.speaker = speaker
        self.log = log
    }

    /// Reads `frames` until they end, the task is cancelled (his speech ended), or the user's
    /// voice talks over him: true then.
    public func watch(_ frames: AsyncStream<MicFrame>) async -> Bool {
        guard let vad = loadVAD() else { return false }
        var run = BargeInRun()
        for await frame in frames {
            if Task.isCancelled { return false }
            guard let clip = run.feed(frame.samples, voiced: Self.voiced(frame.samples, vad: vad)) else { continue }
            if await speaker.matchesForBargeIn(clip) {
                log("barge-in: the user spoke over him (\(clip.count / MicFrame.sampleCount) frames)")
                return true
            }
            run.reset()
        }
        return false
    }

    /// `any(vad.is_speech(frame[i:i + sub], 16000) for i in range(0, len(frame) - sub + 1, sub))`.
    static func voiced(_ samples: [Int16], vad: WebRTCVAD) -> Bool {
        stride(from: 0, through: samples.count - subframe, by: subframe).contains { start in
            (try? vad.isSpeech(samples[start..<start + subframe])) ?? false
        }
    }

    private func loadVAD() -> WebRTCVAD? {
        if let vad { return vad }
        guard !vadFailed else { return nil }
        do {
            let made = try makeVAD()
            vad = made
            return made
        } catch {
            vadFailed = true
            log("barge-in: webrtcvad would not load (\(error)); barge-in is off")
            return nil
        }
    }
}
