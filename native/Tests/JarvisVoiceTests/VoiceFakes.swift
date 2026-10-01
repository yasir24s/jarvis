import Foundation
import Synchronization
@testable import JarvisVoice

// Fakes for the transport, the player, `say` and the engines. The default `swift test` never
// starts the real helper, never loads a model and never plays audio.

/// A folder of its own under the temporary directory, removed by `remove()`.
struct TempFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "jarvis-voice-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path(percentEncoded: false))) ?? []).sorted()
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// What a fake helper does with one request.
enum FakeHelperAction: Sendable {
    /// Writes the samples to <out>/<id>.f32 and answers ok.
    case speak([Float])
    /// Writes the samples but claims another count.
    case speakClaiming([Float], claimed: Int)
    /// Answers ok with a file somewhere else.
    case speakOutside(String)
    /// Answers ok false.
    case fail(String)
    /// Exits mid-request.
    case crash
    /// Never answers.
    case silent
}

/// One fake helper process.
final class FakeHelperConnection: VoiceHelperConnection {
    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let outDirectory: URL
    private let script: @Sendable (String, String) -> FakeHelperAction
    private let state = Mutex(State())

    struct State {
        var requests: [[String: String]] = []
        var closedGracefully = false
        var terminated = false
        var exited = false
    }

    init(outDirectory: URL, script: @escaping @Sendable (String, String) -> FakeHelperAction) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.outDirectory = outDirectory
        self.script = script
    }

    var requests: [[String: String]] { state.withLock { $0.requests } }
    var closedGracefully: Bool { state.withLock { $0.closedGracefully } }
    var terminated: Bool { state.withLock { $0.terminated } }

    func send(_ line: String) throws {
        let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
        guard let request = object as? [String: String], let id = request["id"], let text = request["text"] else {
            throw CocoaError(.coderInvalidValue)
        }
        let alive = state.withLock { state -> Bool in
            guard !state.exited else { return false }
            state.requests.append(request)
            return true
        }
        guard alive else { throw CocoaError(.fileWriteUnknown) }
        switch script(id, text) {
        case .speak(let samples):
            try reply(id: id, samples: samples, claimed: samples.count)
        case .speakClaiming(let samples, let claimed):
            try reply(id: id, samples: samples, claimed: claimed)
        case .speakOutside(let path):
            yield(["id": id, "ok": true, "path": path, "samples": 1, "rate": 24000, "gen_ms": 1, "footprint_mb": 1])
        case .fail(let message):
            yield(["id": id, "ok": false, "error": message])
        case .crash:
            exit()
        case .silent:
            break
        }
    }

    func close(grace: Duration) async {
        state.withLock { $0.closedGracefully = true }
        exit()
    }

    func terminate() {
        state.withLock { $0.terminated = true }
        exit()
    }

    /// The helper's own exit: idle, or a crash between requests.
    func exit() {
        state.withLock { $0.exited = true }
        continuation.finish()
    }

    /// Writes a line as the helper would.
    func yieldLine(_ line: String) {
        continuation.yield(line)
    }

    private func reply(id: String, samples: [Float], claimed: Int) throws {
        let file = outDirectory.appending(path: "\(id).f32", directoryHint: .notDirectory)
        try samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
        yield(["id": id, "ok": true, "path": file.path(percentEncoded: false), "samples": claimed, "rate": 24000,
               "gen_ms": 1234, "footprint_mb": 1050])
    }

    private func yield(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        continuation.yield(String(decoding: data, as: UTF8.self))
    }
}

/// Starts fake helpers. Each launch runs `script` for its requests.
final class FakeLauncher: VoiceHelperLauncher {
    let outDirectory: URL
    private let state: Mutex<State>

    struct State {
        var installed = true
        var launchFails = false
        var connections: [FakeHelperConnection] = []
        var script: @Sendable (Int, String, String) -> FakeHelperAction
    }

    init(outDirectory: URL, script: @escaping @Sendable (_ launch: Int, _ id: String, _ text: String) -> FakeHelperAction) {
        self.outDirectory = outDirectory
        state = Mutex(State(script: script))
    }

    var connections: [FakeHelperConnection] { state.withLock { $0.connections } }
    var launches: Int { state.withLock { $0.connections.count } }
    var requests: [[String: String]] { connections.flatMap(\.requests) }

    func setInstalled(_ installed: Bool) { state.withLock { $0.installed = installed } }
    func setLaunchFails(_ fails: Bool) { state.withLock { $0.launchFails = fails } }
    func setScript(_ script: @escaping @Sendable (Int, String, String) -> FakeHelperAction) {
        state.withLock { $0.script = script }
    }

    func isInstalled() -> Bool { state.withLock { $0.installed } }

    func launch() throws -> any VoiceHelperConnection {
        try state.withLock { state in
            if state.launchFails { throw CocoaError(.executableNotLoadable) }
            let number = state.connections.count + 1
            let script = state.script
            let connection = FakeHelperConnection(outDirectory: outDirectory) { id, text in script(number, id, text) }
            state.connections.append(connection)
            return connection
        }
    }
}

/// A clock the tests move by hand.
final class ManualClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    var now: ContinuousClock.Instant { instant.withLock { $0 } }

    func advance(by duration: Duration) {
        instant.withLock { $0 = $0.advanced(by: duration) }
    }
}

/// Records what it is asked to play. With `hold`, each play waits for `finish()`, a stop or a
/// cancellation, so a test can see what happens while audio plays.
actor FakePlayer: SpeechPlayer {
    private let hold: Bool
    private(set) var played: [Int] = []          // sample counts, in order
    private(set) var stops = 0
    private var waits: [PlaybackWait] = []

    init(hold: Bool = false) {
        self.hold = hold
    }

    func play(_ chunk: PCMChunk) async throws {
        played.append(chunk.samples.count)
        guard hold else { return }
        let wait = PlaybackWait()
        waits.append(wait)
        await withTaskCancellationHandler {
            await withCheckedContinuation { wait.set($0) }
        } onCancel: {
            wait.resume()
        }
        // A cancelled play leaves the list too, so `finish()` ends the play that is still waiting.
        waits.removeAll { $0 === wait }
    }

    /// Ends the oldest play still waiting.
    func finish() {
        guard !waits.isEmpty else { return }
        waits.removeFirst().resume()
    }

    func stop() {
        stops += 1
        for wait in waits { wait.resume() }
        waits.removeAll()
    }

    var waiting: Int { waits.count }
}

/// An engine that answers from a script, and records what it was asked.
actor FakeEngine: SpeechEngine {
    nonisolated let id: EngineID
    private let respond: @Sendable (String) async throws -> [Float]
    private(set) var asked: [String] = []

    init(_ id: EngineID, respond: @escaping @Sendable (String) async throws -> [Float]) {
        self.id = id
        self.respond = respond
    }

    func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        asked.append(sentence)
        let respond = self.respond
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let samples = try await respond(sentence)
                    continuation.yield(PCMChunk(samples: samples, sampleRate: 24_000))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func release() async {}
}

/// Collects log lines.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] { lines.withLock { $0 } }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

/// Polls `condition` every 5 ms until it holds or `limit` passes (SuspendingClock).
func eventually(_ limit: Duration = .seconds(5), _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = SuspendingClock()
    let deadline = clock.now.advanced(by: limit)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}
