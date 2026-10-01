import AVFAudio
import Foundation

/// macOS `say`, the fallback voice: Python's `_system_say` (jarvis.py 774-788) with its voice and
/// rate (`FALLBACK_VOICE` "Daniel", `TTS_RATE` "200"). Python plays through `say` itself; here
/// `say -o` renders an AIFF that goes through the same player as the clone, so Stop Speaking and
/// a new reply cut it off too. `--` ends the options, so a reply starting with "-" is still text.
public actor SayEngine: SpeechEngine {
    public nonisolated let id = EngineID.say
    public static let voice = "Daniel"
    public static let rate = "200"
    public static let sampleRate = 24_000.0

    /// Runs `/usr/bin/say` with these arguments and returns once it has exited 0.
    public typealias Runner = @Sendable ([String]) async throws -> Void
    /// Reads an audio file as 24 kHz mono float32 samples.
    public typealias Reader = @Sendable (URL) throws -> [Float]

    private let directory: URL
    private let runner: Runner
    private let reader: Reader

    public init(directory: URL = FileManager.default.temporaryDirectory,
                runner: @escaping Runner = SayEngine.runSay,
                reader: @escaping Reader = SayEngine.read24k) {
        self.directory = directory
        self.runner = runner
        self.reader = reader
    }

    public static func arguments(text: String, output: URL) -> [String] {
        ["-v", voice, "-r", rate, "-o", output.path(percentEncoded: false), "--", text]
    }

    public func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        let output = directory.appending(path: "jarvis-say-\(UUID().uuidString).aiff", directoryHint: .notDirectory)
        let arguments = Self.arguments(text: sentence, output: output)
        let runner = self.runner
        let reader = self.reader
        return AsyncThrowingStream { continuation in
            let task = Task {
                defer { try? FileManager.default.removeItem(at: output) }
                do {
                    try await runner(arguments)
                    try Task.checkCancellation()
                    let samples = try reader(output)
                    continuation.yield(PCMChunk(samples: samples, sampleRate: Self.sampleRate))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func release() async {}

    // MARK: - The real `say`

    public static let runSay: Runner = { arguments in
        let child = SayChild(arguments)
        let status = try await withTaskCancellationHandler {
            try await child.run()
        } onCancel: {
            child.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else { throw SpeechEngineError(.error, "say exited \(status)") }
    }

    /// The AIFF `say` wrote, converted to 24 kHz mono float32 for the player.
    public static let read24k: Reader = { url in
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard file.length > 0 else { return [] }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SayEngine.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw SpeechEngineError(.error, "cannot convert \(source) to 24 kHz mono")
        }
        try file.read(into: input)
        let capacity = AVAudioFrameCount((Double(input.frameLength) * SayEngine.sampleRate / source.sampleRate).rounded(.up)) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw SpeechEngineError(.error, "cannot allocate \(capacity) frames")
        }
        let feed = OneShotInput(input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            feed.next(inputStatus)
        }
        if status == .error {
            throw conversionError ?? SpeechEngineError(.error, "the AIFF did not convert")
        }
        guard let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Hands the converter the whole file once, then reports the end of the stream.
private final class OneShotInput: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var given = false

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    /// Called by AVAudioConverter on the converting thread, one call at a time.
    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if given {
            status.pointee = .endOfStream
            return nil
        }
        given = true
        status.pointee = .haveData
        return buffer
    }
}

/// One `say` process, shared with the cancellation handler.
private final class SayChild: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var started = false
    private var cancelled = false

    init(_ arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    func run() async throws -> Int32 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try lock.withLock {
                    guard !cancelled else { throw CancellationError() }
                    try process.run()
                    started = true
                }
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if started, process.isRunning { process.terminate() }
        }
    }
}
