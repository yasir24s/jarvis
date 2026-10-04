import Foundation
import Synchronization

/// V6: which clone speaks, the `voiceEngine` setting in SpeechQueue's suite: `qwen` (Qwen3-TTS,
/// the user's choice by ear, 2026-10-03) or `f5`. Unset or anything else is `qwen`.
public enum VoiceEngineChoice: String, Sendable {
    case qwen, f5

    public static let key = "voiceEngine"
    public static let preferred = VoiceEngineChoice.qwen

    public static func choice(in defaults: UserDefaults?) -> VoiceEngineChoice {
        let raw = defaults?.string(forKey: key)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return VoiceEngineChoice(rawValue: raw) ?? preferred
    }
}

/// Starts jarvis-voice-qwen helpers. `arguments` are read afresh for each launch.
public protocol QwenHelperLauncher: Sendable {
    var outDirectory: URL { get }
    /// Whether the helper, the model and the reference are on disk. Qwen is unavailable without them.
    func isInstalled() -> Bool
    /// The helper's arguments as the settings are now. A running helper whose arguments differ is
    /// replaced before the next request, so a new `voiceRate` holds from the next reply.
    var arguments: [String] { get }
    func launch(arguments: [String]) throws -> any VoiceHelperConnection
    /// The voice's rate (1.5 is half as fast again), for `QwenEngine.expectedSeconds`.
    var rate: Double { get }
}

/// The jarvis-voice-qwen helper JARVIS.app carries in `Contents/Helpers/qwen/` (build-app.sh: a
/// folder of its own, since its mlx-swift_Cmlx.bundle is MLX 0.31.4's, and F5's beside
/// jarvis-voice is 0.29.1's), the model install-voice-assets.sh puts in
/// `~/Library/Application Support/JARVIS/voice/qwen3/`, and the long dry reference
/// (`references/dry/`, 4.66 s, with its transcript), the user's choice by ear, 2026-10-03, over
/// `dry-short`. The rate is the `voiceRate` setting, 1.5 when unset: Qwen at 1.5x with the pitch
/// kept is the speed the user chose. MLX's cache is capped at 512 MB as for F5, and the helper
/// exits after 10 idle minutes.
public struct QwenHelperSetup: QwenHelperLauncher {
    /// The model's files under `qwen3/` (install-voice-assets.sh copies exactly these).
    public static let modelFiles = [
        "config.json", "generation_config.json", "model.safetensors", "model.safetensors.index.json",
        "preprocessor_config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt",
        "speech_tokenizer/config.json", "speech_tokenizer/configuration.json",
        "speech_tokenizer/preprocessor_config.json", "speech_tokenizer/model.safetensors",
    ]
    public static let modelFolder = "qwen3"
    /// The reference Qwen clones, under `references/`.
    public static let reference = "dry"
    /// Where Qwen's acknowledgements are rendered: `acknowledgements/qwen-dry/`.
    public static let acknowledgementSet = "qwen-\(reference)"
    public static let cacheLimitMB = 512
    public static let idleExitSeconds = 600
    /// Seconds of audio (before the rate) between streamed pieces: 0.32 s gave the first audio
    /// after 0.25 to 0.38 s warm in the scratch test.
    public static let interval = 0.32
    /// `voiceRate`: the rate Qwen speaks at, pitch kept. Unset or invalid is `defaultRate`.
    public static let rateKey = "voiceRate"
    public static let defaultRate = 1.5
    public static let rateRange = 0.5...2.0

    public let executable: URL
    public let assets: URL
    public let outDirectory: URL
    public let log: URL?
    private let rateSource: @Sendable () -> Double

    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?,
                rate: @escaping @Sendable () -> Double = { QwenHelperSetup.defaultRate }) {
        self.executable = executable
        self.assets = assets
        self.outDirectory = outDirectory
        self.log = log
        self.rateSource = rate
    }

    public var rate: Double { rateSource() }

    /// `voiceRate` from `defaults`, or `defaultRate` when it is unset, not a number, or outside
    /// `rateRange`.
    public static func rate(in defaults: UserDefaults?) -> Double {
        guard let value = (defaults?.object(forKey: rateKey) as? NSNumber)?.doubleValue, value.isFinite,
              rateRange.contains(value) else { return defaultRate }
        return value
    }

    /// The app's own helper, the installed assets, a folder of the user's temporary directory,
    /// and `voiceRate` in `defaults` as it is at each launch.
    public static func inApp(bundle: Bundle = .main, log: URL?,
                             defaults: UserDefaults? = SpeechQueue.sharedDefaults,
                             assets: URL = VoiceHelperSetup.installedAssets) -> QwenHelperSetup {
        let shared = SharedDefaults(defaults: defaults)
        return QwenHelperSetup(
            executable: bundle.bundleURL.appending(path: "Contents/Helpers/qwen/jarvis-voice-qwen", directoryHint: .notDirectory),
            assets: assets,
            outDirectory: FileManager.default.temporaryDirectory.appending(path: "jarvis-voice-qwen", directoryHint: .isDirectory),
            log: log,
            rate: { rate(in: shared.defaults) })
    }

    /// UserDefaults is thread-safe (Apple documents it so) but is not marked Sendable.
    private struct SharedDefaults: @unchecked Sendable {
        let defaults: UserDefaults?
    }

    public var model: URL { assets.appending(path: Self.modelFolder, directoryHint: .isDirectory) }
    public var referenceFolder: URL { VoiceHelperSetup.referenceFolder(Self.reference, assets: assets) }

    public var arguments: [String] {
        ["--model", model.path(percentEncoded: false),
         "--reference", referenceFolder.path(percentEncoded: false),
         "--out-dir", outDirectory.path(percentEncoded: false),
         "--rate", String(rate), "--interval", String(Self.interval),
         "--cache-limit-mb", String(Self.cacheLimitMB), "--idle-exit", String(Self.idleExitSeconds)]
    }

    public func isInstalled() -> Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: executable.path(percentEncoded: false))
            && Self.modelFiles.allSatisfy { files.fileExists(atPath: model.appending(path: $0).path(percentEncoded: false)) }
            && ["reference.wav", "reference.txt"].allSatisfy {
                files.fileExists(atPath: referenceFolder.appending(path: $0).path(percentEncoded: false))
            }
    }

    public func launch(arguments: [String]) throws -> any VoiceHelperConnection {
        let files = FileManager.default
        try files.createDirectory(at: outDirectory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        // Audio a crashed helper left behind.
        for url in (try? files.contentsOfDirectory(at: outDirectory, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "f32" {
            try? files.removeItem(at: url)
        }
        return try VoiceHelperProcess(executable: executable, arguments: arguments, log: log)
    }
}

/// V6: Qwen3-TTS, generated by the jarvis-voice-qwen helper and streamed: each request's audio
/// comes back as numbered pieces (raw float32 files, read and deleted here), yielded as they
/// arrive, then a `done` line. Ending the stream early (Stop, barge-in, a new reply) sends the
/// helper `{"cmd": "cancel", "id"}`, which stops its generation at the next token; pieces that
/// still come for it are deleted unread.
///
/// Failures before the first piece throw `SpeechEngineError`, so the caller can fall back (to F5,
/// then `say`); after it they end the stream. No first piece within `firstTimeout`, or a gap of
/// more than `gapTimeout` between pieces, ends the helper; the next request starts a fresh one.
/// Two failures in a row rest Qwen for `restPeriod`, as F5.
public actor QwenEngine: SpeechEngine {
    public nonisolated let id = EngineID.qwen
    public static let sampleRate = 24_000.0
    /// The first piece, a cold start included (the model loads in about 3 s).
    public static let defaultFirstTimeout = Duration.seconds(60)
    public static let defaultGapTimeout = Duration.seconds(30)
    public static let restPeriod = Duration.seconds(600)
    /// About how fast the clone speaks before the rate, in characters a second, for the captions.
    /// Qwen's dry clone spoke the user's 127-character test sentence in 7.7 s (16.5 a second)
    /// and a 300-character reply in 14.7 s (20.4) in the scratch test.
    public static let charactersPerSecond = 18.0

    private let launcher: any QwenHelperLauncher
    private let firstTimeout: Duration
    private let gapTimeout: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let shared = Mutex(Shared())

    private struct Shared {
        var restingUntil: ContinuousClock.Instant?
        var lastFootprintMB: Int?
    }

    private var connection: (any VoiceHelperConnection)?
    private var connectionArguments: [String] = []
    private var connectionNumber = 0
    private var loadedConnection: Int?
    /// The requests in flight, by id: where their lines go.
    private var waiting: [String: AsyncStream<HelperStreamLine>.Continuation] = [:]
    private var failuresInARow = 0

    public init(launcher: any QwenHelperLauncher, firstTimeout: Duration = QwenEngine.defaultFirstTimeout,
                gapTimeout: Duration = QwenEngine.defaultGapTimeout,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.launcher = launcher
        self.firstTimeout = firstTimeout
        self.gapTimeout = gapTimeout
        self.now = now
    }

    /// False when the helper, the model or the reference is missing, or while Qwen rests.
    public nonisolated var isAvailable: Bool {
        guard launcher.isInstalled() else { return false }
        guard let until = shared.withLock({ $0.restingUntil }) else { return true }
        return now() >= until
    }

    public nonisolated var lastFootprintMB: Int? {
        shared.withLock { $0.lastFootprintMB }
    }

    var isConnected: Bool { connection != nil }

    public func streaming() async -> Bool { true }

    public func expectedSeconds(for text: String) async -> Double? {
        Double(text.unicodeScalars.count) / (Self.charactersPerSecond * max(0.1, launcher.rate))
    }

    public func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let id = UUID().uuidString
        let task = Task {
            await self.run(id: id, text: sentence, into: continuation)
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await self.abandon(id) }
        }
        return stream
    }

    public func warm() async {
        guard isAvailable else { return }
        if connection != nil, loadedConnection == connectionNumber, connectionArguments == launcher.arguments { return }
        guard let helper = try? connect() else { return }
        loadedConnection = connectionNumber
        try? helper.send(#"{"cmd":"load"}"#)
    }

    public func release() async {
        guard let connection else { return }
        self.connection = nil
        connectionNumber += 1   // its exit is not a crash
        finishAll()
        await connection.close(grace: .seconds(2))
    }

    // MARK: - One request

    private func run(id: String, text: String, into out: AsyncThrowingStream<PCMChunk, any Error>.Continuation) async {
        var pieces = 0
        func fail(_ error: SpeechEngineError) {
            failed()
            out.finish(throwing: error)
        }
        if let until = shared.withLock({ $0.restingUntil }) {
            guard now() >= until else {
                return out.finish(throwing: SpeechEngineError(.disabled, "Qwen is resting after two failures in a row"))
            }
            shared.withLock { $0.restingUntil = nil }
        }
        guard launcher.isInstalled() else {
            return out.finish(throwing: SpeechEngineError(.disabled, "the Qwen helper, model or reference is not installed"))
        }
        let helper: any VoiceHelperConnection
        do {
            helper = try connect()
        } catch {
            return fail(SpeechEngineError(.error, "cannot start the Qwen helper: \(error)"))
        }
        let number = connectionNumber
        let (lines, linesIn) = AsyncStream.makeStream(of: HelperStreamLine.self)
        waiting[id] = linesIn
        do {
            try helper.send(Self.requestLine(id: id, text: SpeechNormaliser.spoken(text)))
        } catch {
            waiting[id] = nil
            return fail(SpeechEngineError(.error, "cannot write to the Qwen helper: \(error)"))
        }
        // A watchdog ends the request when no line comes in time.
        let lastLine = LastLine(now())
        let firstTimeout = self.firstTimeout, gapTimeout = self.gapTimeout, clock = self.now
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                let last = lastLine.state.withLock { $0 }
                let limit = last.any ? gapTimeout : firstTimeout   // after the first line, only gaps count
                if clock() - last.at > limit {
                    await self?.timedOut(id, connection: number, after: limit)
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        for await line in lines {
            lastLine.state.withLock { $0 = (clock(), true) }
            switch line {
            case .piece(let reply):
                do {
                    let samples = try readPCM(reply.path, expected: reply.samples)
                    pieces += 1
                    if pieces == 1, number == connectionNumber { loadedConnection = number }
                    out.yield(PCMChunk(samples: samples, sampleRate: Double(reply.rate ?? Int(Self.sampleRate))))
                } catch {
                    waiting[id] = nil
                    cancelInHelper(id)
                    return fail(SpeechEngineError(.error, "cannot read the Qwen helper's audio: \(error)"))
                }
            case .done:
                waiting[id] = nil
                failuresInARow = 0
                return out.finish()
            case .failed(let message, let cancelled):
                waiting[id] = nil
                if cancelled { return out.finish() }
                return fail(SpeechEngineError(.error, message))
            case .ended(let reason):
                // The helper stopped (crashed or timed out), or the engine was released.
                if case .released = reason { return out.finish(throwing: CancellationError()) }
                if case .timeout(let limit) = reason {
                    return fail(SpeechEngineError(.timeout, "no audio from the Qwen helper in \(limit)"))
                }
                return fail(SpeechEngineError(.error, "the Qwen helper stopped mid-request"))
            }
        }
        // The lines ended without a verdict: the consumer went away (`abandon`).
        out.finish()
    }

    static func requestLine(id: String, text: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "text": text], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func cancelLine(id: String) -> String {
        #"{"cmd":"cancel","id":"\#(id)"}"#
    }

    /// The stream's consumer went away (Stop, barge-in, a new reply): the helper is told to stop.
    private func abandon(_ id: String) {
        guard let lines = waiting.removeValue(forKey: id) else { return }
        lines.finish()
        cancelInHelper(id)
    }

    private func cancelInHelper(_ id: String) {
        try? connection?.send(Self.cancelLine(id: id))
    }

    private func connect() throws -> any VoiceHelperConnection {
        let arguments = launcher.arguments
        if let connection {
            if arguments == connectionArguments { return connection }
            // A setting changed (voiceRate): this helper goes, a new one starts with it.
            self.connection = nil
            connectionNumber += 1
            finishAll()
            Task { await connection.close(grace: .seconds(2)) }
        }
        let helper = try launcher.launch(arguments: arguments)
        connectionNumber += 1
        let number = connectionNumber
        connection = helper
        connectionArguments = arguments
        Task { [weak self] in
            for await line in helper.lines {
                await self?.received(line, connection: number)
            }
            await self?.exited(connection: number)
        }
        return helper
    }

    private func received(_ line: String, connection number: Int) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let reply = try? decoder.decode(HelperStreamReply.self, from: Data(line.utf8)) else { return }
        if let mb = reply.footprintMb {
            shared.withLock { $0.lastFootprintMB = mb }
        }
        guard let id = reply.id, reply.cmd == nil else { return }
        guard let lines = waiting[id] else {
            // A cancelled request's audio: nobody plays it.
            if reply.ok, let path = reply.path, isOurs(path) { try? FileManager.default.removeItem(atPath: path) }
            return
        }
        if !reply.ok {
            lines.yield(.failed(reply.error ?? "the Qwen helper failed", cancelled: reply.cancelled == true))
        } else if reply.done == true {
            lines.yield(.done)
        } else if reply.path != nil {
            lines.yield(.piece(reply))
        }
    }

    private func exited(connection number: Int) {
        guard number == connectionNumber else { return }
        connection = nil
        finishAll(.crashed)
    }

    private func timedOut(_ id: String, connection number: Int, after limit: Duration) {
        guard let lines = waiting.removeValue(forKey: id) else { return }
        lines.yield(.ended(.timeout(limit)))
        lines.finish()
        if number == connectionNumber, let connection {
            self.connection = nil
            connectionNumber += 1
            connection.terminate()
            finishAll(.crashed)
        }
    }

    /// Ends every request in flight.
    private func finishAll(_ reason: HelperStreamLine.EndReason = .released) {
        let pending = waiting
        waiting.removeAll()
        for (_, lines) in pending {
            lines.yield(.ended(reason))
            lines.finish()
        }
    }

    private func failed() {
        failuresInARow += 1
        guard failuresInARow >= 2 else { return }
        failuresInARow = 0
        let until = now().advanced(by: Self.restPeriod)
        shared.withLock { $0.restingUntil = until }
        if let connection {
            self.connection = nil
            connectionNumber += 1
            Task { await connection.close(grace: .seconds(2)) }
        }
    }

    // MARK: - Files

    private func isOurs(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent.hasSuffix(".f32")
            && url.deletingLastPathComponent().standardizedFileURL.path
                == launcher.outDirectory.standardizedFileURL.path
    }

    private func readPCM(_ path: String?, expected: Int?) throws -> [Float] {
        guard let path, isOurs(path) else {
            throw SpeechEngineError(.error, "the helper named a file outside its folder")
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw SpeechEngineError(.error, "\(data.count) bytes is not whole float32 samples")
        }
        var samples = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }   // Apple silicon is little-endian
        if let expected, expected != samples.count {
            throw SpeechEngineError(.error, "the file holds \(samples.count) samples, the reply said \(expected)")
        }
        return samples
    }
}

/// One line of jarvis-voice-qwen's stdout.
struct HelperStreamReply: Decodable, Sendable {
    let id: String?
    let cmd: String?
    let ok: Bool
    let chunk: Int?
    let done: Bool?
    let path: String?
    let samples: Int?
    let rate: Int?
    let firstMs: Int?
    let genMs: Int?
    let footprintMb: Int?
    let cancelled: Bool?
    let error: String?
}

/// What one request hears of the helper.
enum HelperStreamLine: Sendable {
    enum EndReason: Sendable {
        case released, crashed
        case timeout(Duration)
    }

    case piece(HelperStreamReply)
    case done
    case failed(String, cancelled: Bool)
    case ended(EndReason)
}

/// When the helper last answered a request, and whether it has at all.
final class LastLine: Sendable {
    let state: Mutex<(at: ContinuousClock.Instant, any: Bool)>

    init(_ start: ContinuousClock.Instant) {
        state = Mutex((start, false))
    }
}
