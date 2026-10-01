import Foundation

/// The jarvis-voice helper JARVIS.app carries in `Contents/Helpers/` (build-app.sh) and the voice
/// assets `native/scripts/install-voice-assets.sh` puts in `~/Library/Application Support/JARVIS/voice/`.
/// The arguments are D-54's: MLX's cache capped at 512 MB, F5's 8 steps, and an exit after
/// 5 idle minutes, which hands the helper's memory back to the system.
public struct VoiceHelperSetup: VoiceHelperLauncher {
    /// What the helper loads from `assets` (install-voice-assets.sh copies exactly these).
    public static let assetFiles = [
        "f5/model.safetensors", "f5/vocab.txt", "vocos/model.safetensors", "vocos/config.json",
        "reference/reference.wav", "reference/reference.txt",
    ]
    public static let cacheLimitMB = 512
    public static let steps = 8
    public static let idleExitSeconds = 300

    public let executable: URL
    public let assets: URL
    public let outDirectory: URL
    /// The helper's stderr is appended here; nil discards it.
    public let log: URL?

    public init(executable: URL, assets: URL, outDirectory: URL, log: URL?) {
        self.executable = executable
        self.assets = assets
        self.outDirectory = outDirectory
        self.log = log
    }

    /// The app's own helper, the installed assets, and a folder of the user's temporary directory.
    public static func inApp(bundle: Bundle = .main, log: URL?) -> VoiceHelperSetup {
        VoiceHelperSetup(
            executable: bundle.bundleURL.appending(path: "Contents/Helpers/jarvis-voice", directoryHint: .notDirectory),
            assets: installedAssets,
            outDirectory: FileManager.default.temporaryDirectory.appending(path: "jarvis-voice", directoryHint: .isDirectory),
            log: log)
    }

    /// `~/Library/Application Support/JARVIS/voice/`.
    public static var installedAssets: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "JARVIS/voice", directoryHint: .isDirectory)
    }

    public var arguments: [String] {
        ["--assets", assets.path(percentEncoded: false), "--out-dir", outDirectory.path(percentEncoded: false),
         "--cache-limit-mb", String(Self.cacheLimitMB), "--steps", String(Self.steps),
         "--idle-exit", String(Self.idleExitSeconds)]
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
