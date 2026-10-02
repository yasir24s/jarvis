import Foundation

/// M10 part 4: the setup window's voice takes. Each is recorded as Python's
/// `recognizer.record(source, duration=4)` records one (J:5236) and checked as `enroll_voice`
/// checks it: a take counts when over 12800 samples (0.8 s) of it are voice after preprocessing.
public enum EnrolmentTake {
    /// `record(duration=4)`: each chunk read adds its length (1280 / 16000 s) to the elapsed
    /// time, and the chunk that takes it past 4 s is dropped. Summed in floating point the 50th
    /// step is 4.000000000000002, so a take keeps 49 frames: 62720 samples, 3.92 s (golden suite
    /// m10_enrol_record runs the real `Recognizer.record`).
    public static let duration = 4.0
    public static let frames: Int = {
        let perBuffer = Double(MicFrame.sampleCount) / MicFrame.sampleRate
        var elapsed = 0.0, read = 0
        while true {
            elapsed += perBuffer
            if elapsed > duration { break }
            read += 1
        }
        return read
    }()
    public static var samples: Int { frames * MicFrame.sampleCount }
}

/// How a take sounds to enroll_voice.
public enum TakeQuality: Equatable, Sendable {
    /// Enough voice: enroll_voice would keep it.
    case good(voicedSamples: Int)
    /// Too little voice after the silences are trimmed: record it again.
    case tooLittleVoice(voicedSamples: Int)

    public var isGood: Bool { if case .good = self { true } else { false } }

    /// The voiced length after preprocessing, the samples enroll_voice measures.
    public var voicedSamples: Int {
        switch self {
        case .good(let n), .tooLittleVoice(let n): n
        }
    }

    /// The check, on a take's samples: `len(preprocess_wav(take)) > 16000 * 0.8`.
    public static func of(_ take: [Int16], encoder: SpeakerEncoder) async throws -> TakeQuality {
        let voiced = try await encoder.preprocess(take).count
        return voiced > Voiceprint.minimumTake ? .good(voicedSamples: voiced) : .tooLittleVoice(voicedSamples: voiced)
    }
}

/// A take did not finish.
public enum TakeError: Error, Equatable, CustomStringConvertible {
    /// The microphone would not open.
    case microphone(MicError)
    /// The microphone's frames stopped before the take was whole (the device went away).
    case interrupted(frames: Int)

    public var description: String {
        switch self {
        case .microphone(let error): "the microphone did not open (\(error))"
        case .interrupted(let frames): "the microphone stopped after \(frames) of \(EnrolmentTake.frames) frames"
        }
    }
}

/// Records takes through a MicCapture of its own, apart from push-to-talk's, so neither stops
/// the other's stream. Each take subscribes, opens the microphone, reads `EnrolmentTake.frames`
/// frames and closes it, so nothing holds the microphone between takes. Cancelling the task
/// ends the take and closes the microphone; so does a device that stops sending frames, after
/// `timeout`.
public actor TakeRecorder {
    private let makeInput: @Sendable () -> any MicInput
    private let timeout: Duration
    private let log: @Sendable (String) -> Void

    /// - makeInput: the microphone through the app's one `AudioHub` (`HubMicInput`); tests pass a fake.
    /// - timeout: how long a take may take before the microphone is closed: the take's 3.92 s
    ///   and 3 s to spare.
    public init(makeInput: @escaping @Sendable () -> any MicInput = { HubMicInput() },
                timeout: Duration = .seconds(7), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.makeInput = makeInput
        self.timeout = timeout
        self.log = log
    }

    /// One take. `level` gets each frame's meter level (0...1) as it arrives.
    public func record(level: @escaping @Sendable (Double) -> Void) async throws -> [Int16] {
        let mic = MicCapture(makeInput: makeInput, log: log)
        let stream = await mic.frames()
        do {
            try await mic.start()
        } catch {
            throw TakeError.microphone(error)
        }
        let limit = timeout
        let watchdog = Task {
            try? await Task.sleep(for: limit)
            if !Task.isCancelled { await mic.stop() }
        }
        defer { watchdog.cancel() }
        var samples: [Int16] = []
        samples.reserveCapacity(EnrolmentTake.samples)
        var read = 0
        for await frame in stream {
            samples.append(contentsOf: frame.samples)
            read += 1
            level(frame.level)
            if read == EnrolmentTake.frames { break }
        }
        await mic.stop()
        try Task.checkCancellation()
        guard read == EnrolmentTake.frames else { throw TakeError.interrupted(frames: read) }
        return samples
    }
}

/// Records one take: `TakeRecorder` in the app, a fake in the setup window's tests.
public protocol TakeRecording: Sendable {
    func record(level: @escaping @Sendable (Double) -> Void) async throws -> [Int16]
}

extension TakeRecorder: TakeRecording {}

/// What the setup window's voice step asks of the voiceprint: `Voiceprint` in the app, a fake in
/// the window's tests, so they need neither ORT nor a microphone.
public protocol VoiceEnrolling: Sendable {
    var isEnrolled: Bool { get async }
    /// The take check (`TakeQuality.of`).
    func quality(of take: [Int16]) async throws -> TakeQuality
    /// `enroll(takes:)`: embeds, saves (keeping the old file as .previous) and loads the new one.
    func enroll(takes: [[Int16]]) async throws -> Voiceprint.EnrollOutcome
}

extension Voiceprint: VoiceEnrolling {
    public func quality(of take: [Int16]) async throws -> TakeQuality {
        try await TakeQuality.of(take, encoder: encoder)
    }
}
