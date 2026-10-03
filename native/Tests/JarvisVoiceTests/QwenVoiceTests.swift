import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

// V6: Qwen3-TTS as the voice, streamed, with F5 behind it. Every test here uses fakes: no helper
// starts, no model loads, nothing plays.

/// A fake jarvis-voice-qwen: answers each request with `pieces` (one file and line each), then
/// `done`, unless the script says otherwise. With `gated`, each piece after the first waits for
/// `release()`, so a test can act mid-stream.
final class FakeQwenConnection: VoiceHelperConnection {
    enum Script: Sendable {
        case pieces([[Float]])
        case fail(String)
        case crash
        case silent
    }

    let lines: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let outDirectory: URL
    private let script: Script
    private let gated: Bool
    private let state = Mutex(State())

    struct State {
        var requests: [String] = []
        var commands: [String] = []
        var cancelled: [String] = []
        var gates: [CheckedContinuation<Void, Never>] = []
        var open = 0
        var exited = false
        var closed = false
    }

    init(outDirectory: URL, script: Script, gated: Bool) {
        (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.outDirectory = outDirectory
        self.script = script
        self.gated = gated
    }

    var requests: [String] { state.withLock { $0.requests } }
    var commands: [String] { state.withLock { $0.commands } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    var closed: Bool { state.withLock { $0.closed } }

    func send(_ line: String) throws {
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else {
            throw CocoaError(.coderInvalidValue)
        }
        guard !state.withLock({ $0.exited }) else { throw CocoaError(.fileWriteUnknown) }
        if let cmd = object["cmd"] {
            state.withLock {
                $0.commands.append(cmd)
                if cmd == "cancel", let id = object["id"] { $0.cancelled.append(id) }
            }
            if cmd != "cancel" { yield(["cmd": cmd, "ok": true, "loaded": true, "footprint_mb": 3000]) }
            return
        }
        guard let id = object["id"], let text = object["text"] else { throw CocoaError(.coderInvalidValue) }
        state.withLock { $0.requests.append(text) }
        switch script {
        case .pieces(let pieces):
            Task { await self.stream(id, pieces) }
        case .fail(let message):
            yield(["id": id, "ok": false, "error": message])
        case .crash:
            exit()
        case .silent:
            break
        }
    }

    private func stream(_ id: String, _ pieces: [[Float]]) async {
        for (n, samples) in pieces.enumerated() {
            if n > 0, gated { await gate() }
            let file = outDirectory.appending(path: "\(id)-\(n + 1).f32", directoryHint: .notDirectory)
            try? samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: file)
            yield(["id": id, "ok": true, "chunk": n + 1, "path": file.path(percentEncoded: false),
                   "samples": samples.count, "rate": 24000])
        }
        if gated { await gate() }
        let cancelledIt = state.withLock { $0.cancelled.contains(id) }
        if cancelledIt {
            yield(["id": id, "ok": false, "cancelled": true, "error": "cancelled"])
        } else {
            yield(["id": id, "ok": true, "done": true, "chunks": pieces.count,
                   "samples": pieces.reduce(0) { $0 + $1.count }, "rate": 24000, "footprint_mb": 3100])
        }
    }

    private func gate() async {
        await withCheckedContinuation { continuation in
            let now = state.withLock { state -> Bool in
                if state.open > 0 {
                    state.open -= 1
                    return true
                }
                state.gates.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Lets the next gated piece (or the closing line) through.
    func release() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if state.gates.isEmpty {
                state.open += 1
                return nil
            }
            return state.gates.removeFirst()
        }
        waiter?.resume()
    }

    func close(grace: Duration) async {
        state.withLock { $0.closed = true }
        exit()
    }

    func terminate() { exit() }

    func exit() {
        state.withLock { $0.exited = true }
        continuation.finish()
    }

    private func yield(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        continuation.yield(String(decoding: data, as: UTF8.self))
    }
}

final class FakeQwenLauncher: QwenHelperLauncher {
    let outDirectory: URL
    private let state: Mutex<State>

    struct State {
        var installed = true
        var launchFails = false
        var rate = 1.5
        var script: FakeQwenConnection.Script
        var gated = false
        var launched: [FakeQwenConnection] = []
        var arguments: [[String]] = []
    }

    init(outDirectory: URL, script: FakeQwenConnection.Script, gated: Bool = false) {
        self.outDirectory = outDirectory
        state = Mutex(State(script: script, gated: gated))
    }

    var launched: [FakeQwenConnection] { state.withLock { $0.launched } }
    var launchArguments: [[String]] { state.withLock { $0.arguments } }
    func setInstalled(_ installed: Bool) { state.withLock { $0.installed = installed } }
    func setLaunchFails(_ fails: Bool) { state.withLock { $0.launchFails = fails } }
    func setRate(_ rate: Double) { state.withLock { $0.rate = rate } }

    var rate: Double { state.withLock { $0.rate } }
    var arguments: [String] { ["--rate", String(rate)] }
    func isInstalled() -> Bool { state.withLock { $0.installed } }

    func launch(arguments: [String]) throws -> any VoiceHelperConnection {
        try state.withLock { state in
            if state.launchFails { throw CocoaError(.executableNotLoadable) }
            let connection = FakeQwenConnection(outDirectory: outDirectory, script: state.script, gated: state.gated)
            state.launched.append(connection)
            state.arguments.append(arguments)
            return connection
        }
    }
}

/// An engine that streams a script of pieces and says it streams.
actor FakeStreamEngine: SpeechEngine {
    nonisolated let id: EngineID
    private let pieces: [[Float]]
    private let failFirst: Bool
    private(set) var asked: [String] = []
    private(set) var terminated = 0
    private var gates: [CheckedContinuation<Void, Never>] = []
    private var open = 0

    init(_ id: EngineID = .qwen, pieces: [[Float]], failFirst: Bool = false) {
        self.id = id
        self.pieces = pieces
        self.failFirst = failFirst
    }

    func streaming() async -> Bool { true }
    func expectedSeconds(for text: String) async -> Double? { 4.5 }

    func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        asked.append(sentence)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let pieces = self.pieces, failFirst = self.failFirst
        let task = Task {
            if failFirst {
                continuation.finish(throwing: SpeechEngineError(.error, "cannot start the Qwen helper"))
                return
            }
            for (n, samples) in pieces.enumerated() {
                if n > 0 { await self.gate() }
                if Task.isCancelled { break }
                continuation.yield(PCMChunk(samples: samples, sampleRate: 24_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            Task { await self.ended() }
        }
        return stream
    }

    private func ended() {
        terminated += 1
        for gate in gates { gate.resume() }
        gates.removeAll()
    }

    private func gate() async {
        if open > 0 {
            open -= 1
            return
        }
        await withCheckedContinuation { gates.append($0) }
    }

    /// Lets the next piece through.
    func next() {
        if gates.isEmpty { open += 1 } else { gates.removeFirst().resume() }
    }

    func release() async {}
}

/// Records the player's calls; a stream's pieces are recorded as they are taken.
actor StreamRecordingPlayer: SpeechPlayer {
    let events = LogLines()
    private var stopped = false

    func play(_ chunk: PCMChunk) async throws {
        events.append("play \(chunk.samples.count)")
    }

    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        events.append("stream \(expectedSeconds)")
        for try await piece in pieces {
            events.append("piece \(piece.samples.count)")
            if Task.isCancelled || stopped { break }
        }
        events.append("stream ended")
    }

    func stop() {
        stopped = true
        events.append("stop")
    }

    func replyStarting() { events.append("replyStarting") }
    func replyReady() { events.append("replyReady") }
    func replyEnded() { events.append("replyEnded") }
}

@Suite("V6 Qwen voice")
struct QwenVoiceTests {
    static func pieces(_ sizes: [Int]) -> [[Float]] {
        sizes.map { [Float](repeating: 0.05, count: $0) }
    }

    // MARK: - Settings

    @Test func theEngineSettingIsQwenUnlessF5() throws {
        let defaults = try #require(UserDefaults(suiteName: "jarvis-qwen-tests-\(UUID().uuidString)"))
        #expect(VoiceEngineChoice.choice(in: defaults) == .qwen)
        defaults.set("f5", forKey: VoiceEngineChoice.key)
        #expect(VoiceEngineChoice.choice(in: defaults) == .f5)
        defaults.set(" F5 ", forKey: VoiceEngineChoice.key)
        #expect(VoiceEngineChoice.choice(in: defaults) == .f5)
        defaults.set("eleven", forKey: VoiceEngineChoice.key)
        #expect(VoiceEngineChoice.choice(in: defaults) == .qwen)
        #expect(VoiceEngineChoice.choice(in: nil) == .qwen)
    }

    @Test func theRateIsOneAndAHalfUnlessSet() throws {
        let defaults = try #require(UserDefaults(suiteName: "jarvis-qwen-tests-\(UUID().uuidString)"))
        #expect(QwenHelperSetup.rate(in: defaults) == 1.5)
        defaults.set(1.25, forKey: QwenHelperSetup.rateKey)
        #expect(QwenHelperSetup.rate(in: defaults) == 1.25)
        defaults.set(3.0, forKey: QwenHelperSetup.rateKey)
        #expect(QwenHelperSetup.rate(in: defaults) == 1.5)
        defaults.set("fast", forKey: QwenHelperSetup.rateKey)
        #expect(QwenHelperSetup.rate(in: defaults) == 1.5)
    }

    @Test func theHelperIsLaunchedWithTheModelTheDryReferenceAndTheRate() throws {
        let assets = URL(fileURLWithPath: "/tmp/voice-assets", isDirectory: true)
        let setup = QwenHelperSetup(executable: URL(fileURLWithPath: "/tmp/jarvis-voice-qwen"), assets: assets,
                                    outDirectory: URL(fileURLWithPath: "/tmp/out", isDirectory: true), log: nil,
                                    rate: { 1.25 })
        let arguments = setup.arguments
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
        }
        #expect(value("--model") == "/tmp/voice-assets/qwen3/")
        #expect(value("--reference") == "/tmp/voice-assets/references/dry/")
        #expect(value("--rate") == "1.25")
        #expect(value("--interval") == "0.32")
        #expect(value("--cache-limit-mb") == "512")
        #expect(setup.isInstalled() == false)   // nothing is on disk there
    }

    @Test func theAcknowledgementSetFollowsTheEngine() {
        #expect(Acknowledgement.set(for: .qwen, f5Reference: "dry-short") == "qwen-dry")
        #expect(Acknowledgement.set(for: .f5, f5Reference: "dry-short") == "dry-short")
        #expect(Acknowledgement.set(for: .f5, f5Reference: "default") == "default")
    }

    // MARK: - QwenEngine

    @Test func piecesArriveInOrderAndTheirFilesAreDeleted() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([100, 200, 300])))
        let engine = QwenEngine(launcher: launcher)
        var sizes: [Int] = []
        for try await piece in await engine.synthesize("Good evening, sir.", context: SynthesisContext(turnID: UUID())) {
            sizes.append(piece.samples.count)
        }
        #expect(sizes == [100, 200, 300])
        #expect(folder.files.isEmpty)
        #expect(launcher.launched.count == 1)
        #expect(engine.lastFootprintMB == 3100)
        #expect(await engine.streaming())
    }

    @Test func endingTheStreamCancelsTheGenerationInTheHelper() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([100, 200, 300])),
                                        gated: true)
        let engine = QwenEngine(launcher: launcher)
        let stream = await engine.synthesize("Good evening, sir.", context: SynthesisContext(turnID: UUID()))
        let consumer = Task {
            var count = 0
            for try await _ in stream { count += 1 }
            return count
        }
        #expect(await eventually { launcher.launched.first?.requests.count == 1 })
        let helper = try #require(launcher.launched.first)
        try await Task.sleep(for: .milliseconds(50))   // the first piece is taken
        consumer.cancel()
        #expect(await eventually { helper.cancelled.count == 1 })
        // The pieces the helper still sends are deleted unread.
        helper.release()
        helper.release()
        helper.release()
        #expect(await eventually { folder.files.isEmpty })
        _ = try? await consumer.value
    }

    @Test func aFailureBeforeTheFirstPieceThrows() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .fail("model missing"))
        let engine = QwenEngine(launcher: launcher)
        await #expect(throws: SpeechEngineError.self) {
            for try await _ in await engine.synthesize("Hello.", context: SynthesisContext(turnID: UUID())) {}
        }
        launcher.setInstalled(false)
        #expect(engine.isAvailable == false)
    }

    @Test func aNewRateStartsANewHelper() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let launcher = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([10])))
        let engine = QwenEngine(launcher: launcher)
        for try await _ in await engine.synthesize("One.", context: SynthesisContext(turnID: UUID())) {}
        for try await _ in await engine.synthesize("Two.", context: SynthesisContext(turnID: UUID())) {}
        #expect(launcher.launched.count == 1)
        launcher.setRate(1.25)
        for try await _ in await engine.synthesize("Three.", context: SynthesisContext(turnID: UUID())) {}
        #expect(launcher.launched.count == 2)
        #expect(launcher.launchArguments.last == ["--rate", "1.25"])
        #expect(launcher.launched[0].closed)
    }

    // MARK: - VoiceSelector

    static func selector(qwen: FakeQwenLauncher, f5: FakeLauncher, choice: VoiceEngineChoice = .qwen,
                         log: LogLines) -> (VoiceSelector, QwenEngine, F5Engine) {
        let qwenEngine = QwenEngine(launcher: qwen)
        let f5Engine = F5Engine(launcher: f5)
        let selector = VoiceSelector(qwen: qwenEngine, f5: f5Engine, choice: { choice }, log: { log.append($0) })
        return (selector, qwenEngine, f5Engine)
    }

    static func collect(_ selector: VoiceSelector, _ text: String) async throws -> [Int] {
        var sizes: [Int] = []
        for try await piece in await selector.synthesize(text, context: SynthesisContext(turnID: UUID())) {
            sizes.append(piece.samples.count)
        }
        return sizes
    }

    @Test func qwenSpeaksAndTheF5HelperIsReleased() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let qwen = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([5, 6])))
        let f5 = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([Float](repeating: 0, count: 50)) }
        let log = LogLines()
        let choice = ChoiceBox(.f5)
        let f5Engine = F5Engine(launcher: f5)
        let selector = VoiceSelector(qwen: QwenEngine(launcher: qwen), f5: f5Engine, choice: { choice.value },
                                     log: { log.append($0) })
        // F5 first, so its helper is running.
        #expect(await selector.streaming() == false)
        #expect(try await Self.collect(selector, "One.") == [50])
        #expect(await f5Engine.isConnected)
        // Now Qwen: F5's helper goes before Qwen speaks.
        choice.set(.qwen)
        #expect(await selector.streaming())
        #expect(try await Self.collect(selector, "Two.") == [5, 6])
        #expect(await f5Engine.isConnected == false)
        #expect(await selector.id == .qwen)
    }

    @Test func withQwenMissingF5SpeaksAndTheLogSaysWhy() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let qwen = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([5])))
        qwen.setInstalled(false)
        let f5 = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([Float](repeating: 0, count: 50)) }
        let log = LogLines()
        let (selector, _, _) = Self.selector(qwen: qwen, f5: f5, log: log)
        #expect(selector.current == .f5)
        #expect(await selector.streaming() == false)
        #expect(try await Self.collect(selector, "One.") == [50])
        #expect(try await Self.collect(selector, "Two.") == [50])
        #expect(log.all.filter { $0.contains("Qwen is not available") }.count == 1)
        #expect(qwen.launched.isEmpty)
    }

    @Test func aQwenHelperThatCannotStartHandsTheReplyToF5() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let qwen = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([5])))
        qwen.setLaunchFails(true)
        let f5 = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([Float](repeating: 0, count: 50)) }
        let log = LogLines()
        let (selector, _, _) = Self.selector(qwen: qwen, f5: f5, log: log)
        #expect(try await Self.collect(selector, "One.") == [50])
        #expect(log.all.contains { $0.contains("Qwen failed") && $0.contains("F5 speaks this reply") })
        #expect(await selector.id == .f5)
    }

    @Test func choosingF5ReleasesQwen() async throws {
        let folder = try TempFolder()
        defer { folder.remove() }
        let qwen = FakeQwenLauncher(outDirectory: folder.url, script: .pieces(Self.pieces([5])))
        let f5 = FakeLauncher(outDirectory: folder.url) { _, _, _ in .speak([Float](repeating: 0, count: 50)) }
        let log = LogLines()
        let qwenEngine = QwenEngine(launcher: qwen)
        let f5Engine = F5Engine(launcher: f5)
        let box = ChoiceBox(.qwen)
        let selector = VoiceSelector(qwen: qwenEngine, f5: f5Engine, choice: { box.value }, log: { log.append($0) })
        #expect(try await Self.collect(selector, "One.") == [5])
        #expect(await qwenEngine.isConnected)
        box.set(.f5)
        #expect(try await Self.collect(selector, "Two.") == [50])
        #expect(await qwenEngine.isConnected == false)
        #expect(qwen.launched.first?.closed == true)
    }

    // MARK: - SpeechQueue with a stream

    @Test func aStreamedReplyIsWrappedOnceAndPlayedInOrder() async throws {
        let engine = FakeStreamEngine(pieces: Self.pieces([100, 200, 300]))
        let player = StreamRecordingPlayer()
        let queue = SpeechQueue(engine: engine, fallback: FakeEngine(.say) { _ in [1] }, player: player,
                                speakEarly: { true }, sentences: SpeakEarlyTests.sentences, log: { _ in })
        let gateOpener = Task {
            for _ in 0..<2 {
                try? await Task.sleep(for: .milliseconds(20))
                await engine.next()
            }
        }
        await queue.say(SpeakEarlyTests.reply, turn: UUID())
        await queue.idle()
        await gateOpener.value
        let events = player.events.all
        #expect(events == ["replyStarting", "replyReady", "stream 4.5", "piece 100", "piece 200", "piece 300",
                           "stream ended", "replyEnded"])
        // Speak First Sentence Early is moot: the reply went whole.
        #expect(await engine.asked == [SpeakEarlyTests.reply])
    }

    @Test func stopMidStreamEndsTheReplyOnceAndTheGeneration() async throws {
        let engine = FakeStreamEngine(pieces: Self.pieces([100, 200, 300]))
        let player = StreamRecordingPlayer()
        let queue = SpeechQueue(engine: engine, fallback: FakeEngine(.say) { _ in [1] }, player: player,
                                log: { _ in })
        await queue.say("Good evening, sir.", turn: UUID())
        #expect(await eventually { player.events.all.contains("piece 100") })
        await queue.cancelAll()
        #expect(await eventually { await engine.terminated >= 1 })
        let events = player.events.all
        #expect(events.filter { $0 == "replyStarting" }.count == 1)
        #expect(events.filter { $0 == "replyEnded" }.count == 1)
        #expect(!events.contains("piece 300"))
        #expect(events.contains("stop"))
    }

    @Test func aStreamThatFailsBeforeItsFirstPieceIsSpokenBySay() async throws {
        let engine = FakeStreamEngine(pieces: [], failFirst: true)
        let player = StreamRecordingPlayer()
        let say = FakeEngine(.say) { _ in [Float](repeating: 0, count: 77) }
        let log = LogLines()
        let queue = SpeechQueue(engine: engine, fallback: say, player: player, log: { log.append($0) })
        await queue.say("Good evening, sir.", turn: UUID())
        await queue.idle()
        #expect(player.events.all == ["replyStarting", "replyReady", "play 77", "replyEnded"])
        #expect(log.all.contains { $0.contains("Qwen failed") && $0.contains("say speaks instead") })
        #expect(log.all.contains { $0.contains("say spoke 1 part(s)") })
    }

    @Test func theReplyWaitsForTheAcknowledgement() async throws {
        let engine = FakeStreamEngine(pieces: Self.pieces([100]))
        let player = StreamRecordingPlayer()
        let queue = SpeechQueue(engine: engine, fallback: FakeEngine(.say) { _ in [1] }, player: player,
                                log: { _ in })
        await queue.acknowledge(PCMChunk(samples: [Float](repeating: 0, count: 12), sampleRate: 24_000),
                                line: "Right away, sir.", sentAt: .now)
        await queue.say("Good evening, sir.", turn: UUID())
        await queue.idle()
        let events = player.events.all
        let ack = try #require(events.firstIndex(of: "play 12"))
        let ready = try #require(events.firstIndex(of: "replyReady"))
        #expect(ack < ready)
        #expect(events.last == "replyEnded")
    }

    // MARK: - Loudness on a stream

    /// Speech-like noise: bursts with quiet gaps, at a level of its own per burst.
    static func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        func random() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
        }
        let n = Int(seconds * 24_000)
        return (0..<n).map { i in
            let word = (i / 7200) % 3 != 2   // 0.2 s words, every third a gap
            let level: Float = word ? 0.05 + 0.04 * Float((i / 7200) % 4) : 0.002
            return random() * level
        }
    }

    /// The stream through LoudnessStream in Qwen-sized pieces.
    static func streamed(_ input: [Float], prior: Float?) -> (out: [Float], gain: Float?) {
        let level = LoudnessStream(sampleRate: 24_000, prior: prior)
        var out: [Float] = []
        var start = 0
        while start < input.count {
            let end = min(start + 5_120, input.count)   // about Qwen's pieces at 1.5x
            out += level.push(Array(input[start..<end]))
            start = end
        }
        out += level.finish()
        return (out, level.gain)
    }

    /// A stream lands within a dB of the target on its own, where its first pieces are too short to
    /// measure well (this signal's words also start quiet and grow louder), and within 0.3 dB of the
    /// whole-part chain with the prior the reply before it ended on. Its peaks stay under the ceiling.
    @Test func aStreamComesOutAtTheTargetLoudnessUnderTheCeiling() {
        let input = Self.speechLike(seconds: 4, seed: 7)
        let (cold, gain) = Self.streamed(input, prior: nil)
        #expect(cold.count == input.count)
        let coldLUFS = Loudness.integrated([cold], sampleRate: 24_000) ?? -100
        #expect(abs(coldLUFS - Loudness.targetLUFS) < 1, "measured \(coldLUFS) LUFS")
        // The next reply in the same voice starts from the gain this one ended on.
        let second = Self.speechLike(seconds: 4, seed: 8)
        let (out, _) = Self.streamed(second, prior: gain)
        let lufs = Loudness.integrated([out], sampleRate: 24_000) ?? -100
        let ceiling = Float(pow(10, Loudness.peakCeilingDBFS / 20))
        #expect(Loudness.samplePeak(cold) <= ceiling)
        #expect(Loudness.samplePeak(out) <= ceiling)
        let whole = Loudness.normalized(second, sampleRate: 24_000)
        let wholeLUFS = Loudness.integrated([whole], sampleRate: 24_000) ?? -100
        #expect(abs(lufs - wholeLUFS) < 0.3, "stream \(lufs), whole \(wholeLUFS)")
    }

    @Test func aStreamOfOnePieceIsTheWholePartChain() {
        let input = Self.speechLike(seconds: 1, seed: 3)
        // One piece (F5's reply, when F5 stands in for Qwen) comes out exactly as the whole-part
        // chain plays it: the first piece waits for a second that never comes.
        let level = LoudnessStream(sampleRate: 24_000, lift: 3)
        #expect(level.push(input).isEmpty)
        #expect(level.finish() == Loudness.normalized(input, sampleRate: 24_000, lift: 3))
        #expect(LoudnessStream(sampleRate: 24_000).finish().isEmpty)
    }
}

/// A setting a test changes between replies.
final class ChoiceBox: Sendable {
    private let state: Mutex<VoiceEngineChoice>
    init(_ initial: VoiceEngineChoice) { state = Mutex(initial) }
    var value: VoiceEngineChoice { state.withLock { $0 } }
    func set(_ choice: VoiceEngineChoice) { state.withLock { $0 = choice } }
}

@Suite("V6 pre-roll")
struct PreRollTests {
    @Test func nothingPlaysUntilAFifthOfASecondIsInHandThenEverythingDoes() {
        var preroll = PreRoll(sampleRate: 24_000)
        #expect(preroll.take([Float](repeating: 0, count: 240)).isEmpty)
        #expect(preroll.take([Float](repeating: 0, count: 4_000)).isEmpty)
        #expect(preroll.take([Float](repeating: 0, count: 800)).count == 5_040)
        #expect(preroll.take([Float](repeating: 0, count: 10)).count == 10)
        #expect(preroll.flush().isEmpty)
    }

    @Test func aShortReplyPlaysWhenItEnds() {
        var preroll = PreRoll(sampleRate: 24_000)
        #expect(preroll.take([Float](repeating: 0, count: 1_000)).isEmpty)
        #expect(preroll.flush().count == 1_000)
    }
}

@Suite("V6 growing meter")
struct GrowingMeterTests {
    /// Fed in uneven pieces, the meter reads what `Loudness.integrated` and `Loudness.speechLevel`
    /// read on the whole, short of a block and past many.
    @Test(arguments: [3_000, 9_600, 50_000, 144_000])
    func itMatchesTheWholeSignalMeasures(count: Int) throws {
        let signal = Array(QwenVoiceTests.speechLike(seconds: 6, seed: 11).prefix(count))
        var weighted = GrowingMeter(sampleRate: 24_000, kWeighted: true)
        var plain = GrowingMeter(sampleRate: 24_000, kWeighted: false)
        var start = 0
        var size = 37
        while start < signal.count {
            let end = min(start + size, signal.count)
            weighted.append(signal[start..<end])
            plain.append(signal[start..<end])
            start = end
            size = size * 7 % 5_003 + 1
        }
        let lufs = try #require(Loudness.integrated([signal], sampleRate: 24_000))
        let level = try #require(Loudness.speechLevel(signal, sampleRate: 24_000))
        #expect(abs(try #require(weighted.gated(offset: -0.691)) - lufs) < 1e-9)
        #expect(abs(try #require(plain.gated(offset: 0)) - level) < 1e-9)
    }
}
