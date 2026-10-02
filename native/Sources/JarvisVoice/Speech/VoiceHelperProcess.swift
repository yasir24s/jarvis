import AVFAudio
import Foundation

/// The jarvis-voice helper JARVIS.app carries in `Contents/Helpers/` (build-app.sh) and the voice
/// assets `native/scripts/install-voice-assets.sh` puts in `~/Library/Application Support/JARVIS/voice/`.
/// The arguments are D-54's: MLX's cache capped at 512 MB, F5 at 4 steps, and an exit after
/// 5 idle minutes, which hands the helper's memory back to the system. D-54 had 8 steps; the
/// user chose 4 on 2026-10-01, when one 5.8 s sentence took 7.7 s at 4 against 18.0 s at 8
/// with the words exact at both. A `cfg` of 0 garbled the words, so cfg keeps its default.
/// The speed is the `voiceSpeed` setting (P5): at F5's own speed of 1 the clone spoke about 140
/// words a minute, under conversation's 155 to 165. V1 part 4 asked for 1.25 and measured two
/// lines in twelve takes each way: at 1.25 (183 and 203 words a minute) five of the twelve
/// lost or changed words ("I take a liberty", "So I read your messages") and "On it, sir."
/// came out "Honestly."; at 1.2 (176 and 195) all twelve and all ten acknowledgements were
/// transcribed right, so the default is 1.2. The app reads the setting for each reply
/// (U1 part 5): when it changed since the last reply SpeechQueue releases the helper, which the
/// next request starts again with the new `--speed`.
public struct VoiceHelperSetup: VoiceHelperLauncher {
    /// What the helper loads from `assets` (install-voice-assets.sh copies exactly these).
    public static let assetFiles = [
        "f5/model.safetensors", "f5/vocab.txt", "vocos/model.safetensors", "vocos/config.json",
        "reference/reference.wav", "reference/reference.txt",
    ]
    public static let cacheLimitMB = 512
    public static let steps = 4
    public static let idleExitSeconds = 300
    /// Where `voiceSpeed` is read from: SpeechQueue's suite.
    public static let speedKey = "voiceSpeed"
    public static let defaultSpeed = 1.2
    public static let speedRange = 0.8...1.4
    /// V1 part 3: which reference the clone speaks with, from SpeechQueue's suite. Unset, or
    /// "default", is the installed `reference/`; another name is `references/<name>/`, which
    /// install-voice-assets.sh installs ("dry", "dry-wpe"). A name that is not installed speaks
    /// with the default.
    public static let referenceKey = "voiceReference"
    public static let defaultReference = "default"

    public let executable: URL
    public let assets: URL
    public let outDirectory: URL
    /// The helper's stderr is appended here; nil discards it.
    public let log: URL?
    /// F5's speed: 1 is the reference's own pace. Read each time it is asked for, so each launch
    /// of the helper (`arguments`) gets the setting as it is then.
    public var speed: Double { speedSource() }
    private let speedSource: @Sendable () -> Double
    /// The reference the helper speaks with: the setting as it is now, if that reference is
    /// installed, else `defaultReference`. Read at each launch, like the speed.
    public var reference: String { Self.installed(referenceSource(), assets: assets) }
    private let referenceSource: @Sendable () -> String

    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?, speed: Double = VoiceHelperSetup.defaultSpeed) {
        self.init(executable: executable, assets: assets, outDirectory: outDirectory, log: log, speed: { speed })
    }

    /// `speed` and `reference` are asked at every launch of the helper.
    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?, speed: @escaping @Sendable () -> Double,
                reference: @escaping @Sendable () -> String = { VoiceHelperSetup.defaultReference }) {
        self.executable = executable
        self.assets = assets
        self.outDirectory = outDirectory
        self.log = log
        self.speedSource = speed
        self.referenceSource = reference
    }

    /// `voiceReference` from the app's defaults, read afresh at each call.
    public static let referenceFromDefaults: @Sendable () -> String = {
        reference(in: UserDefaults(suiteName: SpeechQueue.defaultsSuite))
    }

    /// `voiceReference` from `defaults`, or `defaultReference` when it is unset or empty.
    public static func reference(in defaults: UserDefaults?) -> String {
        let name = defaults?.string(forKey: referenceKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? defaultReference : name
    }

    /// The folder of reference `name`: `reference/` for the default, else `references/<name>/`.
    public static func referenceFolder(_ name: String, assets: URL) -> URL {
        name == defaultReference
            ? assets.appending(path: "reference", directoryHint: .isDirectory)
            : assets.appending(path: "references/\(name)", directoryHint: .isDirectory)
    }

    /// `name` when it is a plain name (a-z, 0-9, -) whose folder holds reference.wav and
    /// reference.txt, else `defaultReference`.
    static func installed(_ name: String, assets: URL) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-".unicodeScalars)
        let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { allowed.contains($0) }
        guard plain, name != defaultReference else { return defaultReference }
        let folder = referenceFolder(name, assets: assets)
        let present = ["reference.wav", "reference.txt"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false))
        }
        return present ? name : defaultReference
    }

    /// `voiceSpeed` from the app's defaults (SpeechQueue's suite), read afresh at each call.
    public static let speedFromDefaults: @Sendable () -> Double = {
        speed(in: UserDefaults(suiteName: SpeechQueue.defaultsSuite))
    }

    /// `voiceSpeed` from the app's defaults, clamped to `speedRange`, or `defaultSpeed` when it is
    /// unset or not a number.
    public static func speed(in defaults: UserDefaults?) -> Double {
        guard let value = (defaults?.object(forKey: speedKey) as? NSNumber)?.doubleValue, value.isFinite else {
            return defaultSpeed
        }
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    /// The app's own helper, the installed assets, a folder of the user's temporary directory, and
    /// the `voiceSpeed` and `voiceReference` settings in `defaults` as they are at each launch of
    /// the helper.
    public static func inApp(bundle: Bundle = .main, log: URL?,
                             defaults: UserDefaults? = UserDefaults(suiteName: SpeechQueue.defaultsSuite)) -> VoiceHelperSetup {
        let shared = SharedDefaults(defaults: defaults)
        return VoiceHelperSetup(
            executable: bundle.bundleURL.appending(path: "Contents/Helpers/jarvis-voice", directoryHint: .notDirectory),
            assets: installedAssets,
            outDirectory: FileManager.default.temporaryDirectory.appending(path: "jarvis-voice", directoryHint: .isDirectory),
            log: log,
            speed: { speed(in: shared.defaults) },
            reference: { reference(in: shared.defaults) })
    }

    /// UserDefaults is thread-safe (Apple documents it so) but is not marked Sendable.
    private struct SharedDefaults: @unchecked Sendable {
        let defaults: UserDefaults?
    }

    /// `~/Library/Application Support/JARVIS/voice/`.
    public static var installedAssets: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "JARVIS/voice", directoryHint: .isDirectory)
    }

    public var arguments: [String] {
        let reference = self.reference
        return ["--assets", assets.path(percentEncoded: false), "--out-dir", outDirectory.path(percentEncoded: false),
                "--cache-limit-mb", String(Self.cacheLimitMB), "--steps", String(Self.steps),
                "--speed", String(speed), "--idle-exit", String(Self.idleExitSeconds)]
            + (reference == Self.defaultReference
                ? [] : ["--reference", Self.referenceFolder(reference, assets: assets).path(percentEncoded: false)])
    }

    /// F5's frames for `text` by the helper's own rule (`Voice.frames`): the reference's frames
    /// (its samples over a hop of 256), plus its frames per UTF-8 byte of reference text times
    /// the text's bytes, over the speed, which for another reference than the default is paced
    /// as the helper paces it (`pacedSpeed`). nil when a reference cannot be read.
    public func frames(forSpokenText text: String) -> Int? {
        let name = reference
        guard let shape = Self.shape(of: Self.referenceFolder(name, assets: assets)) else { return nil }
        var speed = self.speed
        if name != Self.defaultReference {
            guard let home = Self.shape(of: Self.referenceFolder(Self.defaultReference, assets: assets)) else { return nil }
            speed = Self.pacedSpeed(speed, frames: shape.samples / 256, bytes: shape.textBytes,
                                    homeFrames: home.samples / 256, homeBytes: home.textBytes)
        }
        return Self.frames(referenceSamples: shape.samples, referenceTextBytes: shape.textBytes,
                           textBytes: text.utf8.count, speed: speed)
    }

    /// A reference's samples and the UTF-8 bytes of its trimmed text, as the helper reads them.
    static func shape(of folder: URL) -> (samples: Int, textBytes: Int)? {
        guard let samples = try? AVAudioFile(forReading: folder.appending(path: "reference.wav")).length,
              let words = try? String(contentsOf: folder.appending(path: "reference.txt"), encoding: .utf8)
        else { return nil }
        return (Int(samples), words.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count)
    }

    /// The helper's `paced`: `speed` for a reference of `frames` frames and `bytes` bytes of text,
    /// so its text gets the frames per byte the default reference's would, and `voiceSpeed`
    /// means the same pace whichever reference speaks. The same expression as the helper's, so
    /// the frame counts match to the frame.
    public static func pacedSpeed(_ speed: Double, frames: Int, bytes: Int, homeFrames: Int, homeBytes: Int) -> Double {
        speed * (Double(frames) / Double(max(1, bytes))) / (Double(homeFrames) / Double(max(1, homeBytes)))
    }

    public static func frames(referenceSamples: Int, referenceTextBytes: Int, textBytes: Int, speed: Double) -> Int {
        let referenceFrames = referenceSamples / 256
        return referenceFrames
            + Int(Double(referenceFrames) / Double(max(1, referenceTextBytes)) * Double(textBytes) / speed)
    }

    public func isInstalled() -> Bool {
        let files = FileManager.default
        return files.isExecutableFile(atPath: executable.path(percentEncoded: false))
            && Self.assetFiles.allSatisfy { files.fileExists(atPath: assets.appending(path: $0).path(percentEncoded: false)) }
    }

    public func launch() throws -> any VoiceHelperConnection {
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

/// A running helper: requests go to its stdin, replies come from its stdout, one line each.
public final class VoiceHelperProcess: VoiceHelperConnection, @unchecked Sendable {
    public let lines: AsyncStream<String>
    // Process is not Sendable. It is only asked isRunning and its pid after run().
    private let process: Process
    private let input: FileHandle
    private let lock = NSLock()
    private var inputClosed = false

    public init(executable: URL, arguments: [String], log: URL?) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Self.logHandle(log) ?? FileHandle.nullDevice
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let splitter = LineSplitter(continuation)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil   // EOF: the helper has exited
                splitter.finish()
            } else {
                splitter.append(data)
            }
        }
        try process.run()
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        // A helper that has died gives EPIPE on write, not a SIGPIPE that would end JARVIS.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        self.process = process
        self.input = stdin.fileHandleForWriting
        self.lines = lines
    }

    public func send(_ line: String) throws {
        try lock.withLock {
            guard !inputClosed else { throw CocoaError(.fileWriteUnknown) }
            try input.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    public func close(grace: Duration) async {
        closeInput()
        let deadline = ContinuousClock.now.advanced(by: grace)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if process.isRunning { terminate() }
    }

    public func terminate() {
        closeInput()
        let pid = process.processIdentifier
        if pid > 1, process.isRunning { kill(pid, SIGKILL) }
    }

    private func closeInput() {
        lock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            try? input.close()
        }
    }

    private static func logHandle(_ url: URL?) -> FileHandle? {
        guard let url else { return nil }
        let path = url.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
}

/// Splits the helper's stdout on "\n" only. Foundation's line sequences also split on U+2028,
/// U+2029 and U+0085, which a JSON string may hold unescaped.
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let continuation: AsyncStream<String>.Continuation

    init(_ continuation: AsyncStream<String>.Continuation) {
        self.continuation = continuation
    }

    func append(_ data: Data) {
        let complete: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return out
        }
        for line in complete { continuation.yield(line) }
    }

    func finish() {
        let rest: String? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        if let rest { continuation.yield(rest) }
        continuation.finish()
    }
}
