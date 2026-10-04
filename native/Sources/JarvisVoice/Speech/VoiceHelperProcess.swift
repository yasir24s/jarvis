import AVFAudio
import Foundation

/// The jarvis-voice helper JARVIS.app carries in `Contents/Helpers/` (build-app.sh) and the voice
/// assets `native/scripts/install-voice-assets.sh` puts in `~/Library/Application Support/JARVIS/voice/`.
/// The arguments are D-54's: MLX's cache capped at 512 MB, F5 at 8 steps for the dry references
/// (`dry-short`, `dry`, `dry-wpe`) and 4 for the installed default (V2, below), and an exit after
/// 10 idle minutes (V1 part 5; D-54 had 5), which hands the helper's memory back to the system.
/// The helper also clears MLX's cache after each reply. D-54 had 8 steps; the
/// user chose 4 on 2026-10-01, when one 5.8 s sentence took 7.7 s at 4 against 18.0 s at 8
/// with the words exact at both. A `cfg` of 0 garbled the words, so cfg keeps its default.
/// V2: the voice is the `dry` reference at 8 steps, the user's choice by ear, 2026-10-02, over
/// V1's transcription-based default (the installed `reference/` at 4 steps). Of four renders of
/// one sentence the user picked dry at 8; dry and dry-wpe at 4 sounded corrupted and the default
/// at 4 echoey. The steps are the `voiceSteps` setting (whole numbers 2 to 32), read at each
/// launch like the speed; unset or invalid they are 8 for `dry` and `dry-wpe` and 4 for the
/// installed default, so no dry reference runs at 4 by default. Without `references/dry/`
/// installed the voice speaks with the installed default, at 4. V3: the default is `dry-short`,
/// the first 1.62 s of `dry` ("I loved creating that, and I had a"), the user's choice by ear,
/// 2026-10-03: about 6 s faster per reply, because F5 processes the reference on every reply, with
/// every word exact in transcription. Without `references/dry-short/` the voice falls back to
/// `dry` (8 steps), then to the installed default (4). SpeechQueue releases the helper
/// for a new speed or reference, not for new steps: those apply at the next launch.
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
    public static let idleExitSeconds = 600
    /// V2: where `voiceSteps` is read from: SpeechQueue's suite. Whole numbers in `stepsRange`;
    /// unset or anything else (a fraction, a number outside the range, text) is the reference's
    /// own default (`defaultSteps(for:)`), not a clamp.
    public static let stepsKey = "voiceSteps"
    public static let stepsRange = 2...32
    /// The steps when `voiceSteps` gives none: 8 for the dry references (a dry cut never runs at 4), 4 for the installed
    /// default `reference/` (and for any other name, which install-voice-assets.sh does not install).
    public static let dryReferences: Set<String> = ["dry-short", "dry", "dry-wpe"]
    public static let dryReferenceSteps = 8
    public static let defaultReferenceSteps = 4
    /// Where `voiceSpeed` is read from: SpeechQueue's suite.
    public static let speedKey = "voiceSpeed"
    public static let defaultSpeed = 1.2
    public static let speedRange = 0.8...1.4
    /// V1 part 3: which reference the clone speaks with, from SpeechQueue's suite. "default" is
    /// the installed `reference/`; another name is `references/<name>/`, which
    /// install-voice-assets.sh installs ("dry-short", "dry", "dry-wpe"). A name that is not installed speaks
    /// with the default. V2: unset (or empty) is `preferredReference`, so an explicit "default"
    /// still speaks with the installed `reference/`.
    public static let referenceKey = "voiceReference"
    public static let defaultReference = "default"
    /// V3: the reference when `voiceReference` is unset: `dry-short`, the user's choice by ear,
    /// 2026-10-03 (V2 had `dry`, 2026-10-02, over V1's transcription-based default). Where
    /// `references/dry-short/` is not installed the voice speaks with `fallbackReference` (`dry`),
    /// and where that is missing too with `defaultReference`; the steps and the acknowledgements
    /// (`acknowledgements/<reference>/`) follow the reference it speaks with.
    public static let preferredReference = "dry-short"
    public static let fallbackReference = "dry"

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
    /// installed, else `defaultReference`. Read at each launch, like the speed. The steps and the
    /// acknowledgement clips follow this one, so after the fallback they follow the default.
    public var reference: String { Self.resolved(referenceSource(), assets: assets) }
    private let referenceSource: @Sendable () -> String
    /// F5's steps: the `voiceSteps` setting as it is now, else the default of the reference in
    /// use (`defaultSteps(for:)`). Read at each launch, like the speed.
    public var steps: Int { steps(for: reference) }
    private let stepsSource: @Sendable () -> Int?

    private func steps(for reference: String) -> Int {
        stepsSource() ?? Self.defaultSteps(for: reference)
    }

    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?, speed: Double = VoiceHelperSetup.defaultSpeed) {
        self.init(executable: executable, assets: assets, outDirectory: outDirectory, log: log, speed: { speed })
    }

    /// `speed`, `reference` and `steps` are asked at every launch of the helper. `steps` gives the
    /// `voiceSteps` setting, or nil for the default of the reference in use.
    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?, speed: @escaping @Sendable () -> Double,
                reference: @escaping @Sendable () -> String = { VoiceHelperSetup.defaultReference },
                steps: @escaping @Sendable () -> Int? = { nil }) {
        self.executable = executable
        self.assets = assets
        self.outDirectory = outDirectory
        self.log = log
        self.speedSource = speed
        self.referenceSource = reference
        self.stepsSource = steps
    }

    /// `voiceReference` from the app's defaults, read afresh at each call.
    public static let referenceFromDefaults: @Sendable () -> String = {
        reference(in: SpeechQueue.sharedDefaults)
    }

    /// `voiceReference` from `defaults`, or `preferredReference` when it is unset or empty. The
    /// installed check comes later (`installed`), so the name may not be installed.
    public static func reference(in defaults: UserDefaults?) -> String {
        let name = defaults?.string(forKey: referenceKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? preferredReference : name
    }

    /// The folder of reference `name`: `reference/` for the default, else `references/<name>/`.
    public static func referenceFolder(_ name: String, assets: URL) -> URL {
        name == defaultReference
            ? assets.appending(path: "reference", directoryHint: .isDirectory)
            : assets.appending(path: "references/\(name)", directoryHint: .isDirectory)
    }

    /// `installed(name)`, except that `preferredReference` not installed falls back to
    /// `fallbackReference` before `defaultReference`.
    static func resolved(_ name: String, assets: URL) -> String {
        let chosen = installed(name, assets: assets)
        if chosen == defaultReference, name == preferredReference {
            return installed(fallbackReference, assets: assets)
        }
        return chosen
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
        speed(in: SpeechQueue.sharedDefaults)
    }

    /// `voiceSpeed` from the app's defaults, clamped to `speedRange`, or `defaultSpeed` when it is
    /// unset or not a number.
    public static func speed(in defaults: UserDefaults?) -> Double {
        guard let value = (defaults?.object(forKey: speedKey) as? NSNumber)?.doubleValue, value.isFinite else {
            return defaultSpeed
        }
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    /// `voiceSteps` from `defaults` when it is a whole number in `stepsRange`; nil when it is unset
    /// or anything else, which leaves the default of the reference in use.
    public static func steps(in defaults: UserDefaults?) -> Int? {
        guard let value = (defaults?.object(forKey: stepsKey) as? NSNumber)?.doubleValue,
              let whole = Int(exactly: value), stepsRange.contains(whole) else { return nil }
        return whole
    }

    /// F5's steps when `voiceSteps` gives none: `dryReferenceSteps` for `dry-short`, `dry` and `dry-wpe`, else
    /// `defaultReferenceSteps`. `reference` is the one in use, after the installed check.
    public static func defaultSteps(for reference: String) -> Int {
        dryReferences.contains(reference) ? dryReferenceSteps : defaultReferenceSteps
    }

    /// The app's own helper, the installed assets (`assets`), a folder of the user's temporary
    /// directory, and the `voiceSpeed`, `voiceReference` and `voiceSteps` settings in `defaults` as
    /// they are at each launch of the helper.
    public static func inApp(bundle: Bundle = .main, log: URL?,
                             defaults: UserDefaults? = SpeechQueue.sharedDefaults,
                             assets: URL = VoiceHelperSetup.installedAssets) -> VoiceHelperSetup {
        let shared = SharedDefaults(defaults: defaults)
        return VoiceHelperSetup(
            executable: bundle.bundleURL.appending(path: "Contents/Helpers/jarvis-voice", directoryHint: .notDirectory),
            assets: assets,
            outDirectory: FileManager.default.temporaryDirectory.appending(path: "jarvis-voice", directoryHint: .isDirectory),
            log: log,
            speed: { speed(in: shared.defaults) },
            reference: { reference(in: shared.defaults) },
            steps: { steps(in: shared.defaults) })
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
        let steps = self.steps(for: reference)
        return ["--assets", assets.path(percentEncoded: false), "--out-dir", outDirectory.path(percentEncoded: false),
                "--cache-limit-mb", String(Self.cacheLimitMB), "--steps", String(steps),
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
