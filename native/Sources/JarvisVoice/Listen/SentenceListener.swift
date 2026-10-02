import Foundation
import JarvisCore

/// The hands-free loop's one read position on the microphone's frames. Python reads one stream
/// with wait_for_wake_word and recognizer.listen in turn; so does the loop, through this.
public actor FrameSource {
    private var iterator: AsyncStream<MicFrame>.AsyncIterator
    private var held: [MicFrame] = []
    private var cutoff: UInt64 = 0

    public init(_ frames: AsyncStream<MicFrame>) {
        iterator = frames.makeAsyncIterator()
    }

    /// The next frame; nil once the microphone has closed. Frames captured before the last
    /// `dropStale` are skipped.
    public func next() async -> MicFrame? {
        while true {
            let frame: MicFrame?
            if !held.isEmpty {
                frame = held.removeFirst()
            } else {
                // AsyncStream's iterator shares its stream's state, so the copy reads the same
                // frames. One reader at a time: the loop reads in turn, as Python does.
                var reading = iterator
                frame = await reading.next(isolation: #isolation)
                iterator = reading
            }
            guard let frame else { return nil }
            // A frame with no capture time (a test's) is never stale.
            if frame.hostTime != 0 && frame.hostTime < cutoff { continue }
            return frame
        }
    }

    /// What the microphone heard before now goes unread: the time he spoke, or a turn ran, while
    /// nothing listened. Python's next listen reads a stream that has moved on (PyAudio keeps only
    /// the latest audio when nobody reads); the barge-in audio is not replayed either.
    public func dropStale(before hostTime: UInt64 = mach_absolute_time()) {
        cutoff = hostTime
        held.removeAll { $0.hostTime != 0 && $0.hostTime < hostTime }
    }

    /// Puts frames back to be read again first (a stream that is read on elsewhere, as the wake
    /// watcher's soft tier's clip is not).
    public func unread(_ frames: [MicFrame]) {
        held.insert(contentsOf: frames, at: 0)
    }

    /// The frames as an AsyncSequence, for `WakeWatcher.wait`.
    public nonisolated var frames: Frames { Frames(source: self) }

    public struct Frames: AsyncSequence, Sendable {
        public typealias Element = MicFrame
        public typealias Failure = Never
        let source: FrameSource

        public struct AsyncIterator: AsyncIteratorProtocol {
            public typealias Failure = Never
            let source: FrameSource
            public mutating func next() async -> MicFrame? { await source.next() }
        }

        public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(source: source) }
    }
}

/// `listen_sentence` (J:990-1004, plan §3.4): one utterance, ended at what sounds like the end of
/// a sentence, with the energy endpointing of the Recognizer jarvis.py listens with.
///
/// - The utterance is `recognizer.listen(source, timeout, phrase_time_limit=PHRASE_LIMIT)`
///   (`EnergyEndpointer`), transcribed. The transcriber hears the frames as they come: from the
///   phrase's start (with the buffers kept before it), holding quiet ones back until the phrase
///   either goes on or ends, so it hears exactly the clip Python would hand Whisper.
/// - The text is lowercased and stripped. When it stops mid-thought (`_INCOMPLETE_TAIL_RE`, "remind
///   me to", a trailing "and") one more utterance is listened for within 2.2 s and appended.
/// - The clip returned is the first utterance's, for the speaker check and the tone.
/// - No phrase within `timeout` throws `.timedOut` (WaitTimeoutError); a closed microphone throws
///   `.ended`.
public actor SentenceListener {
    public struct Heard: Sendable, Equatable {
        public let text: String
        public let clip: [Int16]

        public init(text: String, clip: [Int16]) {
            self.text = text
            self.clip = clip
        }
    }

    public enum Failure: Error, Sendable, Equatable {
        /// WaitTimeoutError.
        case timedOut
        /// The frames stopped: the microphone closed.
        case ended
    }

    /// Transcribes one utterance's frames, read until the stream finishes: the text, "" for
    /// nothing heard. M9a's Transcriber in the app (it applies the corrections).
    public typealias Transcribe = @Sendable (AsyncStream<MicFrame>) async -> String

    /// `PHRASE_LIMIT` (J:72).
    public static let phraseLimit = 12.0
    /// listen_sentence's continuation timeout.
    public static let continuation = 2.2
    /// `adjust_for_ambient_noise(source, duration=2)` and the cap after it (J:5545-5547).
    public static let calibration = 2.0
    public static let calibrationCap = 3000.0

    /// `SENT_PAUSE` (J:984): `JARVIS_PAUSE`, default 0.9.
    public static func pause(environment: [String: String] = ProcessInfo.processInfo.environment,
                             log: (String) -> Void = { _ in }) -> Double {
        guard let raw = environment["JARVIS_PAUSE"] else { return 0.9 }
        if let value = PythonFloat.parse(raw) { return value }
        log("listen: JARVIS_PAUSE=\(raw.debugDescription) is not a number Python's float() reads; using 0.9")
        return 0.9
    }

    private var endpointer: EnergyEndpointer
    private let transcribe: Transcribe
    private let log: @Sendable (String) -> Void

    public init(pause: Double = SentenceListener.pause(), transcribe: @escaping Transcribe,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        endpointer = EnergyEndpointer(pauseThreshold: pause)
        self.transcribe = transcribe
        self.log = log
    }

    /// The Recognizer's energy threshold now.
    public var energyThreshold: Double { endpointer.energyThreshold }

    /// `adjust_for_ambient_noise(source, 2)`, then the 3000 cap. False when the microphone closed.
    public func calibrate(_ source: FrameSource, seconds: Double = SentenceListener.calibration) async -> Bool {
        for _ in 0..<endpointer.calibrationBuffers(duration: seconds) {
            guard let frame = await source.next() else { return false }
            endpointer.calibrate(frame.samples)
        }
        endpointer.energyThreshold = min(endpointer.energyThreshold, Self.calibrationCap)
        log("listen: calibrated, threshold \(Int(endpointer.energyThreshold.rounded()))")
        return true
    }

    /// `listen_sentence(recognizer, source, timeout, online)`.
    public func listen(_ source: FrameSource, timeout: Double) async throws(Failure) -> Heard {
        let first = try await utterance(source, timeout: timeout)
        var text = first.text
        if !text.isEmpty && WakePhrases.endsMidSentence(text) {
            do {
                let rest = try await utterance(source, timeout: Self.continuation).text
                if !rest.isEmpty {
                    log("listen: sentence continued (\(text.count) + \(rest.count) chars)")
                    text += " " + rest
                }
            } catch .timedOut {
                // Nothing more within 2.2 s: the sentence stands.
            }
        }
        return Heard(text: text, clip: first.clip)
    }

    /// One `recognizer.listen`, transcribed: the text lowercased and stripped, and the clip.
    func utterance(_ source: FrameSource, timeout: Double) async throws(Failure) -> Heard {
        endpointer.begin(timeout: timeout, phraseTimeLimit: Self.phraseLimit)
        var session: Session?
        var quiet: [MicFrame] = []
        defer { session?.cancel() }
        while true {
            switch endpointer.next() {
            case .timedOut:
                throw .timedOut
            case .ended(let clip):
                // The phrase limit: every quiet frame so far is in the clip.
                for frame in quiet { session?.feed(frame) }
                let text = await session?.finish() ?? ""
                session = nil
                return Heard(text: Py.strip(Py.lower(text)), clip: clip)
            case .read:
                guard let frame = await source.next() else { throw .ended }
                switch endpointer.feed(frame.samples) {
                case .waiting:
                    break
                case .started:
                    session?.cancel()
                    let started = Session(transcribe: transcribe)
                    let n = endpointer.retained.count
                    for (k, samples) in endpointer.retained.enumerated() {
                        started.feed(MicFrame(samples: samples, index: frame.index &- UInt64(n - 1 - k),
                                              hostTime: frame.hostTime))
                    }
                    session = started
                    quiet.removeAll()
                case .inPhrase(let loud):
                    if loud {
                        for held in quiet { session?.feed(held) }
                        quiet.removeAll()
                        session?.feed(frame)
                    } else {
                        quiet.append(frame)
                    }
                case .discarded:
                    session?.cancel()
                    session = nil
                    quiet.removeAll()
                case .ended(let clip):
                    // The clip keeps the first `nonSpeakingBufferCount` quiet frames of the pause.
                    quiet.append(frame)
                    for held in quiet.prefix(endpointer.nonSpeakingBufferCount) { session?.feed(held) }
                    let text = await session?.finish() ?? ""
                    session = nil
                    return Heard(text: Py.strip(Py.lower(text)), clip: clip)
                }
            }
        }
    }

    /// One utterance's transcription, fed as the frames come.
    private final class Session: @unchecked Sendable {
        private let continuation: AsyncStream<MicFrame>.Continuation
        private let task: Task<String, Never>

        init(transcribe: @escaping Transcribe) {
            let (stream, continuation) = AsyncStream.makeStream(of: MicFrame.self)
            self.continuation = continuation
            task = Task { await transcribe(stream) }
        }

        func feed(_ frame: MicFrame) { continuation.yield(frame) }

        func finish() async -> String {
            continuation.finish()
            return await task.value
        }

        /// Cancels first, so the transcription sees the cancellation when its frames end.
        func cancel() {
            task.cancel()
            continuation.finish()
        }
    }
}
