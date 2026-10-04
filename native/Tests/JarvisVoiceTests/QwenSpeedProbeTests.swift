import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import JarvisVoice

/// The speed-up probe, with JARVIS_QWEN_SPEED=1: the real jarvis-voice-qwen helper through
/// QwenEngine, SpeechQueue and the real EnginePlayer, its engine rendering offline in step with the
/// wall clock (a play head that moves in real time), so the file holds what the speakers would have
/// played, gaps included. Nothing reaches a device. JARVIS_QWEN_SPEED_DELAY_MS holds each piece
/// back that long before QwenEngine sees it, so generation runs slower than playback.
///
/// JARVIS_QWEN_HELPER, JARVIS_VOICE_ASSETS, JARVIS_QWEN_LIVE_LINES as QwenLiveTests.
/// JARVIS_QWEN_SPEED_WAV_DIR  each line as played is written there as <name>.wav (24 kHz)
@Suite("Qwen speed probe (JARVIS_QWEN_SPEED=1)")
struct QwenSpeedProbeTests {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["JARVIS_QWEN_SPEED"] == "1"

    @Test(.enabled(if: QwenSpeedProbeTests.enabled, "set JARVIS_QWEN_SPEED=1 to run the real helper"))
    func eachLineAsTheSpeakersWouldPlayIt() async throws {
        let out = try TempFolder()
        let logs = try TempFolder()
        defer {
            out.remove()
            logs.remove()
        }
        let setup = QwenHelperSetup(
            executable: Self.environment["JARVIS_QWEN_HELPER"].map { URL(fileURLWithPath: $0) } ?? QwenLiveTests.defaultHelper,
            assets: Self.environment["JARVIS_VOICE_ASSETS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? VoiceHelperSetup.installedAssets,
            outDirectory: out.url, log: logs.url.appending(path: "jarvis-voice-qwen.log"))
        try #require(setup.isInstalled())
        let delay = Int(Self.environment["JARVIS_QWEN_SPEED_DELAY_MS"] ?? "0") ?? 0
        var lines: [(String, String)] = [("short", "Good evening, sir.")]
        if let path = Self.environment["JARVIS_QWEN_LIVE_LINES"] {
            lines = try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").compactMap {
                let fields = $0.split(separator: "\t", maxSplits: 1)
                return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
            }
        }
        let qwen = QwenEngine(launcher: SlowLauncher(base: setup, delay: .milliseconds(delay)))
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: EnginePlayer.sampleRate, channels: 2))
        let engine = try EnginePlayer(offline: output)
        let player = TeePlayer(base: engine)
        let log = LogLines()
        let queue = SpeechQueue(engine: qwen, fallback: SayEngine(), player: player,
                                helperFootprintMB: { qwen.lastFootprintMB },
                                log: { line in
                                    log.append(line)
                                    print("speed probe: \(line)")
                                })
        await qwen.warm()
        for (name, text) in lines {
            player.reset()
            // The play head: renders what is due by the wall clock, 5 ms at a time, and stops the
            // player once the stream has ended and a second of silence has followed.
            let played = Mutex<[Float]>([])
            let head = Task {
                let start = ContinuousClock.now
                var rendered = 0
                var quiet = 0
                while !Task.isCancelled {
                    let due = Int((ContinuousClock.now - start) / .seconds(1) * EnginePlayer.sampleRate)
                    while rendered < due {
                        let frames = AVAudioFrameCount(min(Int(EnginePlayer.offlineFrames), due - rendered))
                        let next = try await engine.renderOffline(frames: frames)
                        if next.isEmpty { rendered = due; break }   // the engine has not started yet
                        played.withLock { $0 += next[0] }
                        rendered += next[0].count
                        quiet = next[0].allSatisfy { abs($0) < 1e-7 } ? quiet + next[0].count : 0
                    }
                    if player.ended, quiet > Int(EnginePlayer.sampleRate) {
                        await engine.stop()
                        return
                    }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            await queue.say(text, turn: UUID())
            await queue.idle()
            head.cancel()
            _ = try? await head.value
            var heard = played.withLock { $0 }
            if let last = heard.lastIndex(where: { abs($0) >= 1e-7 }) { heard.removeSubrange((last + 1)...) }
            let pieces = player.pieces
            // What EnginePlayer.playStream hands the hub, worked out again from the same pieces.
            let level = LoudnessStream(sampleRate: EnginePlayer.sampleRate, lift: EnginePlayer.outputLiftDB, prior: nil)
            var preroll = PreRoll(sampleRate: EnginePlayer.sampleRate)
            var expected: [Float] = []
            for piece in pieces { expected += preroll.take(level.push(piece.samples)) }
            let rest = level.finish()
            expected += preroll.flush() + rest
            // Exact only for the first line: later ones start from the gain and pre-roll the
            // player kept, which this does not see.
            let check = SilenceOnlyMatch.compare(played: heard, expected: expected)
            var pauses: [Int] = []
            var run = 0
            let start = heard.firstIndex { $0 != 0 } ?? 0
            for x in heard[start...] {
                if x == 0 { run += 1 } else { if run >= 24 { pauses.append(run) }; run = 0 }
            }
            let report = await player.lastStream()
            let first = pieces.first?.at
            let arrivals = pieces.map { p in
                String(format: "%.2f:%d", first.map { (p.at - $0) / .seconds(1) } ?? 0, p.samples.count)
            }
            print("speed probe: \(name) delay \(delay) ms: \(pieces.count) pieces, "
                  + "\(pieces.reduce(0) { $0 + $1.samples.count }) samples in, \(expected.count) to play; "
                  + String(format: "played %.2f s; ", Double(heard.count) / EnginePlayer.sampleRate) + check.summary
                  + String(format: "; zero runs of 1 ms or more after the start: %d, %.0f ms", pauses.count,
                           Double(pauses.reduce(0, +)) / EnginePlayer.sampleRate * 1000)
                  + "; report \(report.map { "\($0)" } ?? "none")")
            print("speed probe: \(name) arrivals (s:samples) " + arrivals.joined(separator: " "))
            if name == lines.first?.0 { #expect(check.matched == expected.count, "every sample played once, in order") }
            if let dir = Self.environment["JARVIS_QWEN_SPEED_WAV_DIR"] {
                try VoiceLiveTests.writeWAV(heard, to: URL(fileURLWithPath: dir).appending(path: "\(name).wav"))
            }
        }
        await qwen.release()
        if let text = try? String(contentsOf: setup.log!, encoding: .utf8) {
            print("speed probe: helper stderr:\n\(text)")
        }
    }
}

/// The real helper, with each piece's line held back `delay` (one after the other) before
/// QwenEngine reads it: generation as a hot, loaded Mac runs it.
struct SlowLauncher: QwenHelperLauncher {
    let base: QwenHelperSetup
    let delay: Duration
    var outDirectory: URL { base.outDirectory }
    func isInstalled() -> Bool { base.isInstalled() }
    var arguments: [String] { base.arguments }
    var rate: Double { base.rate }
    func launch(arguments: [String]) throws -> any VoiceHelperConnection {
        SlowConnection(base: try base.launch(arguments: arguments), delay: delay)
    }
}

struct SlowConnection: VoiceHelperConnection {
    let base: any VoiceHelperConnection
    let delay: Duration
    var lines: AsyncStream<String> {
        let source = base.lines
        let delay = self.delay
        return AsyncStream { continuation in
            let task = Task {
                for await line in source {
                    if delay > .zero, line.contains("\"chunk\"") { try? await Task.sleep(for: delay) }
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func send(_ line: String) throws { try base.send(line) }
    func close(grace: Duration) async { await base.close(grace: grace) }
    func terminate() { base.terminate() }
}

/// Passes a stream on to `base` and keeps each piece, and when it came.
final class TeePlayer: SpeechPlayer, @unchecked Sendable {
    let base: EnginePlayer
    private let state = Mutex<(pieces: [(at: ContinuousClock.Instant, samples: [Float])], ended: Bool)>(([], false))
    init(base: EnginePlayer) { self.base = base }
    var pieces: [(at: ContinuousClock.Instant, samples: [Float])] { state.withLock { $0.pieces } }
    var ended: Bool { state.withLock { $0.ended } }
    func reset() { state.withLock { $0 = ([], false) } }
    func play(_ chunk: PCMChunk) async throws { try await base.play(chunk) }
    func stop() async { await base.stop() }
    func lastStream() async -> StreamReport? { await base.lastStream() }
    func playStream(_ pieces: AsyncThrowingStream<PCMChunk, any Error>, expectedSeconds: Double) async throws {
        let (tee, out) = AsyncThrowingStream<PCMChunk, any Error>.makeStream()
        let pump = Task {
            do {
                for try await piece in pieces {
                    self.state.withLock { $0.pieces.append((ContinuousClock.now, piece.samples)) }
                    out.yield(piece)
                }
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
            self.state.withLock { $0.ended = true }
        }
        defer { pump.cancel() }
        try await base.playStream(tee, expectedSeconds: expectedSeconds)
    }
}
