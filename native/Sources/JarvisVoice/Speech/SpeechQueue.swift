import Foundation
import JarvisCore
import Synchronization

/// The only way anything speaks (M8). `say(_:turn:)` takes a finished reply: TextClean, then the
/// clone, with `say` when the clone fails, then the player.
///
/// V1 part 2: every reply is generated whole, never split (P5's split rule and its
/// `voiceChunkChars` limit are gone). The speak policy keeps replies to 600 characters
/// (`SpeakRules.replyLimit`). A reply the clone cannot take in one generation (`tooLong`: F5
/// stops at 4096 frames, the reference included) is spoken by `say`, and the log says why. A new
/// reply cancels whatever is queued or playing; `cancelAll()` stops everything.
///
/// V1 part 1: `acknowledge` plays a rendered acknowledgement the moment a message is sent. The
/// reply after it generates while it plays and starts once it has finished, and does not say a
/// short acknowledgement of its own first (`Acknowledgement.spokenText`).
///
/// V5: with Speak First Sentence Early on (`speakEarly`, read for each reply), a reply of two or
/// more sentences whose first has at least `earlyMinimum` characters is generated in exactly two
/// parts: the first sentence, then the whole rest. The rest generates while the first plays.
/// The player's reply calls, Stop and the acknowledgement wrap both parts as one reply.
public actor SpeechQueue {
    /// The app's defaults suite, where the voice settings are read from.
    public static let defaultsSuite = "com.jarv1s.assistant"
    /// The UserDefaults key of Speak First Sentence Early (V5); off when unset.
    public static let speakEarlyKey = "speakEarly"
    /// The shortest first sentence spoken on its own (V5), in Unicode scalars.
    public static let earlyMinimum = 20

    private let engine: any SpeechEngine
    private let fallback: any SpeechEngine
    private let player: any SpeechPlayer
    /// The voice's speed, read for each reply (U1 part 5); nil never releases the engine.
    private let speed: (@Sendable () -> Double)?
    /// The speed the last reply was spoken at.
    private var lastSpeed: Double?
    /// The voice's reference, read for each reply (V1 part 3); nil never releases the engine.
    private let reference: (@Sendable () -> String)?
    private var lastReference: String?
    /// Why the voice cannot take a reply whole, or nil when it can.
    private let tooLong: @Sendable (String) -> String?
    /// Speak First Sentence Early, read for each reply (V5); nil never splits.
    private let speakEarly: (@Sendable () -> Bool)?
    /// The reply's sentences (the app's `SentenceSplitter`); nil never splits.
    private let sentences: (@Sendable (String) -> [String])?
    private let helperFootprintMB: @Sendable () -> Int?
    private let log: @Sendable (String) -> Void
    private var current: Task<Void, Never>?
    /// The acknowledgement playing, if any; a reply waits for it before its own audio.
    private var acknowledging: Task<Void, Never>?
    /// An acknowledgement was played for the message the next reply answers.
    private var acknowledged = false
    /// The highest stop `cancelAll(through:)` was given. A reply or acknowledgement handed over
    /// with an earlier stop count was asked for before that stop and is dropped, however late
    /// it arrives (Stop Speaking sticks).
    private var cancelledThrough = 0

    /// - engine: the voice (F5Engine); `fallback` speaks a reply it fails (SayEngine).
    /// - speed: `voiceSpeed`, read for each reply: when it changed since the last reply the
    ///   engine is released first, so it starts again at the new speed.
    /// - reference: the reference the voice speaks with (`voiceReference`), read and acted on
    ///   in the same way.
    /// - tooLong: given the cleaned reply, why the voice cannot generate it in one go (F5Engine's
    ///   `tooLong`), or nil. Such a reply goes to `fallback` without asking the voice.
    /// - speakEarly: Speak First Sentence Early (`speakEarlyFromDefaults`), read for each reply.
    /// - sentences: splits a reply into its sentences, for `parts`. Both are needed to split.
    /// - helperFootprintMB: the helper's footprint in its last reply, for the log line.
    public init(engine: any SpeechEngine, fallback: any SpeechEngine, player: any SpeechPlayer,
                speed: (@Sendable () -> Double)? = nil,
                reference: (@Sendable () -> String)? = nil,
                tooLong: @escaping @Sendable (String) -> String? = { _ in nil },
                speakEarly: (@Sendable () -> Bool)? = nil,
                sentences: (@Sendable (String) -> [String])? = nil,
                helperFootprintMB: @escaping @Sendable () -> Int? = { nil },
                log: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.fallback = fallback
        self.player = player
        self.speed = speed
        self.reference = reference
        self.tooLong = tooLong
        self.speakEarly = speakEarly
        self.sentences = sentences
        self.helperFootprintMB = helperFootprintMB
        self.log = log
    }

    /// Plays an acknowledgement clip at once, after stopping whatever is queued or playing (the
    /// last reply, or an acknowledgement before this one). Logs how long after `sentAt`, when
    /// the message was sent, its audio was handed to the player.
    /// - stops: how many stops the caller had made when it asked (`cancelAll(through:)`); nil
    ///   never drops.
    public func acknowledge(_ clip: PCMChunk, line: String, sentAt: ContinuousClock.Instant, stops: Int? = nil) {
        if let stops, stops < cancelledThrough { return }
        let previous = current
        let previousAcknowledgement = acknowledging
        previous?.cancel()
        previousAcknowledgement?.cancel()
        current = nil
        acknowledged = true
        let player = self.player
        let log = self.log
        acknowledging = Task {
            await previous?.value   // the audio before has stopped
            await previousAcknowledgement?.value
            guard !Task.isCancelled else { return }
            log("voice: acknowledgement \"\(line)\" started \(Self.seconds(ContinuousClock.now - sentAt, digits: 2)) s after send")
            do {
                try await player.play(clip)
            } catch {
                log("voice: cannot play (\(error))")
            }
        }
    }

    /// Speaks a finished reply, after cancelling the reply before it. An acknowledgement still
    /// playing finishes first. `stops` as for `acknowledge`: a reply asked for before a later
    /// stop is dropped, and what is in hand goes on.
    public func say(_ text: String, turn: UUID, stops: Int? = nil) {
        if let stops, stops < cancelledThrough { return }
        let started = ContinuousClock.now
        let previous = current
        previous?.cancel()
        let afterAcknowledgement = acknowledged
        acknowledged = false
        guard let cleaned = TextClean.clean(text) else {
            current = nil
            return
        }
        let clean = afterAcknowledgement ? Acknowledgement.spokenText(cleaned) : cleaned
        let acknowledgement = acknowledging
        let speed = self.speed?()
        let reference = self.reference?()
        let restart = (speed != nil && lastSpeed != nil && speed != lastSpeed)
            || (reference != nil && lastReference != nil && reference != lastReference)
        if let speed { lastSpeed = speed }
        if let reference { lastReference = reference }
        let early = speakEarly?() ?? false
        let parts = sentences.map { Self.parts(clean, early: early, sentences: $0) } ?? [clean]
        let overflows = parts.map { tooLong($0) }
        current = Task {
            await previous?.value   // the reply before has stopped its audio
            guard !Task.isCancelled else { return }
            if restart { await self.engine.release() }   // the next request starts it with the new setting
            if await self.engine.streaming() {
                await self.speakStreamed(clean, turn: turn, started: started, after: acknowledgement)
            } else {
                await self.speak(clean, parts: parts, turn: turn, started: started, overflows: overflows,
                                 after: acknowledgement)
            }
        }
    }

    /// V5: what a reply is generated as. With `early` on, a reply of two or more sentences whose
    /// first has at least `earlyMinimum` characters is two parts, the first sentence and the
    /// whole rest; otherwise it is the reply whole.
    public static func parts(_ text: String, early: Bool, sentences: (String) -> [String]) -> [String] {
        guard early else { return [text] }
        let split = sentences(text)
        guard split.count >= 2, let first = split.first, first.unicodeScalars.count >= earlyMinimum,
              let range = text.range(of: first) else { return [text] }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rest.isEmpty else { return [text] }
        return [first, rest]
    }

    /// Speak First Sentence Early as stored in the app's defaults suite: off until switched on.
    public static func speakEarlyFromDefaults() -> Bool {
        speakEarly(in: UserDefaults(suiteName: defaultsSuite))
    }

    public static func speakEarly(in defaults: UserDefaults?) -> Bool {
        defaults?.object(forKey: speakEarlyKey) as? Bool ?? false
    }

    /// V1 part 5: has the voice get ready for a reply that is coming (the user is typing). When
    /// the speed or the reference changed since the last reply nothing is done: that reply
    /// releases the voice first, and a voice warmed now would be released with it.
    public func warm() async {
        let speed = self.speed?()
        let reference = self.reference?()
        let changed = (speed != nil && lastSpeed != nil && speed != lastSpeed)
            || (reference != nil && lastReference != nil && reference != lastReference)
        guard !changed else { return }
        await engine.warm()
    }

    /// Stops everything: the acknowledgement, and the reply being generated or played.
    /// - through: the caller's stop count after this stop; anything handed over later with a
    ///   lower count (asked for before this stop) is dropped. nil drops nothing later.
    public func cancelAll(through stops: Int? = nil) async {
        if let stops { cancelledThrough = max(cancelledThrough, stops) }
        let running = current
        let acknowledgement = acknowledging
        current = nil
        acknowledging = nil
        acknowledged = false
        running?.cancel()
        acknowledgement?.cancel()
        await running?.value
        await acknowledgement?.value
        await player.stop()
    }

    /// Waits for the acknowledgement and the reply in hand to finish (tests, and quit after
    /// `cancelAll`).
    public func idle() async {
        await acknowledging?.value
        await current?.value
    }

    // MARK: - One reply

    private struct Generated: Sendable {
        var chunk: PCMChunk?
        var engine: EngineID?
        var elapsed: Duration
        /// Why the voice gave the reply to the fallback.
        var fallbackReason: String?
    }

    private func speak(_ text: String, parts: [String], turn: UUID, started: ContinuousClock.Instant,
                       overflows: [String?], after acknowledgement: Task<Void, Never>?) async {
        let characters = text.unicodeScalars.count
        for (part, overflow) in zip(parts, overflows) {
            guard let overflow else { continue }
            let what = parts.count == 1 ? "the reply" : "that part"
            log("voice: \(part.unicodeScalars.count) chars do not fit the voice (\(overflow)); say speaks \(what)")
        }
        let context = SynthesisContext(turnID: turn)
        // M11b: voice processing comes on while the reply generates, and goes off after it, once
        // for the whole reply however many parts it has.
        await player.replyStarting()
        var next: Task<Generated, Never>? = generate(parts[0], context, withVoice: overflows[0] == nil)
        var index = 0
        var firstAudio: Duration?
        var ready = false
        var stopped = false
        var generating = Duration.zero
        var sayParts = 0
        var byVoice = false
        while let pending = next {
            next = nil
            let reply = await withTaskCancellationHandler {
                await pending.value
            } onCancel: {
                pending.cancel()
            }
            generating += reply.elapsed
            if reply.engine == .say { sayParts += 1 } else if reply.engine != nil { byVoice = true }
            if Task.isCancelled {
                stopped = true
                break
            }
            // V5: the rest generates while this part plays.
            if index + 1 < parts.count {
                next = generate(parts[index + 1], context, withVoice: overflows[index + 1] == nil)
            }
            index += 1
            if let reason = reply.fallbackReason {
                log("voice: F5 failed (\(reason)); say speaks instead")
            }
            guard let chunk = reply.chunk, !chunk.samples.isEmpty else { continue }
            if !ready {
                await acknowledgement?.value   // generated while it played; heard after it
                if !Task.isCancelled { await player.replyReady() }
                ready = true
            }
            if Task.isCancelled {
                stopped = true
                break
            }
            if firstAudio == nil { firstAudio = ContinuousClock.now - started }
            do {
                try await player.play(chunk)
            } catch {
                log("voice: cannot play (\(error))")
            }
            if Task.isCancelled {
                stopped = true
                break
            }
        }
        if let next {   // stopped while a part played: the part after it is not wanted
            next.cancel()
            _ = await next.value
        }
        await player.replyEnded()
        log(Self.summary(characters: characters, parts: parts.count, firstAudio: firstAudio, generating: generating,
                         helperMB: sayParts > 0 && !byVoice ? nil : helperFootprintMB(), sayParts: sayParts,
                         stopped: stopped))
    }

    // MARK: - One streamed reply (V6)

    /// V6: a reply from a streaming voice (Qwen): generated whole, never split (Speak First
    /// Sentence Early is moot, since the first audio comes within a second anyway), with no
    /// `tooLong` check (a stream has no frame limit), and played piece by piece as it arrives. The
    /// player's reply calls, the acknowledgement and Stop wrap it as they wrap a reply generated in
    /// one go: `replyStarting` before the request, `replyReady` once the first piece is in hand and
    /// the acknowledgement has finished, `replyEnded` once. A voice that fails before its first
    /// piece hands the reply, whole, to the fallback (`say`); one that fails after it ends the reply
    /// there, after what came has played.
    private func speakStreamed(_ text: String, turn: UUID, started: ContinuousClock.Instant,
                               after acknowledgement: Task<Void, Never>?) async {
        let characters = text.unicodeScalars.count
        let context = SynthesisContext(turnID: turn)
        await player.replyStarting()
        let expected = await engine.expectedSeconds(for: text) ?? 0
        let relay = StreamRelay(await engine.synthesize(text, context: context))
        let first = await withTaskCancellationHandler {
            await relay.first()
        } onCancel: {
            relay.cancel()
        }
        var firstAudio: Duration?
        var stopped = false
        var sayParts = 0
        var byVoice = false
        var generating = Duration.zero
        if Task.isCancelled {
            stopped = true
        } else if case .success(true) = first {
            byVoice = true
            await acknowledgement?.value   // generated while it played; heard after it
            if !Task.isCancelled { await player.replyReady() }
            if Task.isCancelled {
                stopped = true
            } else {
                firstAudio = ContinuousClock.now - started
                do {
                    try await player.playStream(relay.pieces, expectedSeconds: expected)
                } catch {
                    if !(Task.isCancelled || error is CancellationError) {
                        log("voice: the voice stopped mid-reply (\(error)); the rest is not spoken")
                    }
                }
                if let report = await player.lastStream() {
                    log(Self.prerollLine(report))
                    if report.dry > 0 { log(Self.dryLine(report)) }
                }
                if Task.isCancelled { stopped = true }
            }
            generating = relay.generating
        } else {
            let voice = await engine.id
            let reason: String
            switch first {
            case .failure(let error): reason = "\(error)"
            default: reason = "no audio"
            }
            log("voice: \(Self.name(voice)) failed (\(reason)); say speaks instead")
            let reply = await generate(text, context, withVoice: false).value
            generating = reply.elapsed
            if reply.engine == .say { sayParts = 1 }
            if let chunk = reply.chunk, !chunk.samples.isEmpty, !Task.isCancelled {
                await acknowledgement?.value
                if !Task.isCancelled { await player.replyReady() }
                if !Task.isCancelled {
                    firstAudio = ContinuousClock.now - started
                    do {
                        try await player.play(chunk)
                    } catch {
                        log("voice: cannot play (\(error))")
                    }
                }
            }
            if Task.isCancelled { stopped = true }
        }
        relay.cancel()   // a stopped reply's generation stops with it
        await player.replyEnded()
        log(Self.summary(characters: characters, parts: 1, firstAudio: firstAudio, generating: generating,
                         helperMB: sayParts > 0 && !byVoice ? nil : helperFootprintMB(), sayParts: sayParts,
                         stopped: stopped))
    }

    private static func name(_ engine: EngineID) -> String {
        switch engine {
        case .qwen: "Qwen"
        case .f5: "F5"
        case .say: "say"
        }
    }

    /// Generates the reply with the voice, or with the fallback when the voice throws or is not
    /// to be asked.
    private func generate(_ text: String, _ context: SynthesisContext, withVoice: Bool) -> Task<Generated, Never> {
        let engine = self.engine
        let fallback = self.fallback
        let log = self.log
        return Task {
            let start = ContinuousClock.now
            var reason: String?
            if withVoice {
                do {
                    let chunk = try await Self.collect(engine.synthesize(text, context: context))
                    return Generated(chunk: chunk, engine: await engine.id, elapsed: ContinuousClock.now - start)
                } catch {
                    if Task.isCancelled || error is CancellationError {
                        return Generated(chunk: nil, engine: nil, elapsed: ContinuousClock.now - start)
                    }
                    reason = "\(error)"
                }
            }
            do {
                let chunk = try await Self.collect(fallback.synthesize(text, context: context))
                return Generated(chunk: chunk, engine: await fallback.id, elapsed: ContinuousClock.now - start,
                                 fallbackReason: reason)
            } catch {
                if !(Task.isCancelled || error is CancellationError) { log("voice: say failed (\(error))") }
                return Generated(chunk: nil, engine: nil, elapsed: ContinuousClock.now - start, fallbackReason: reason)
            }
        }
    }

    /// The whole of one engine stream as one chunk.
    static func collect(_ stream: AsyncThrowingStream<PCMChunk, any Error>) async throws -> PCMChunk {
        var samples: [Float] = []
        var rate = EnginePlayer.sampleRate
        for try await chunk in stream {
            samples += chunk.samples
            rate = chunk.sampleRate
        }
        // A cancelled consumer sees the stream end early, not an error.
        try Task.checkCancellation()
        return PCMChunk(samples: samples, sampleRate: rate)
    }

    /// `voice: <n> chars in 1 part(s); first audio after <s> s; generated in <g> s; helper <MB> MB`
    /// A reply spoken whole is "1 part(s)", as the line has always read; V5's early first
    /// sentence makes it 2. `generated in` is the parts' generation times added up.
    static func summary(characters: Int, parts: Int = 1, firstAudio: Duration?, generating: Duration,
                        helperMB: Int?, sayParts: Int, stopped: Bool) -> String {
        var line = "voice: \(characters) chars in \(parts) part(s); "
        line += firstAudio.map { "first audio after \(seconds($0)) s" } ?? "no audio"
        line += "; generated in \(seconds(generating)) s; helper "
        line += helperMB.map { "\($0) MB" } ?? "n/a"
        if sayParts > 0 { line += "; say spoke \(sayParts) part(s)" }
        if stopped { line += "; stopped" }
        return line
    }

    /// `voice: pre-roll 0.2 s (stream keeping up)`, or `voice: pre-roll 1.4 s (stream slow: x0.80)`
    /// with the last reply's delivery rate it was worked out from.
    static func prerollLine(_ report: StreamReport) -> String {
        let seconds = String(format: "%.1f", report.preroll)
        guard let rate = report.holdRate else { return "voice: pre-roll \(seconds) s (stream keeping up)" }
        return "voice: pre-roll \(seconds) s (stream slow: x\(String(format: "%.2f", rate)))"
    }

    /// `voice: stream ran dry <n> times, <ms> ms`, and this reply's delivery rate when known.
    static func dryLine(_ report: StreamReport) -> String {
        var line = "voice: stream ran dry \(report.dry) times, \(report.dryMilliseconds) ms"
        if let rate = report.deliveryRate { line += String(format: "; delivered at %.2fx real time", rate) }
        return line
    }

    private static func seconds(_ d: Duration, digits: Int = 1) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.\(digits)f", s)
    }
}

/// V6: a voice's stream with its first piece waited for. `first()` says whether a piece came
/// (true), the stream ended without one (false), or what it threw before one; `pieces` then gives
/// every piece, the first included. `cancel()` ends the voice's stream, which stops its
/// generation; dropping `pieces` does the same.
final class StreamRelay: Sendable {
    let pieces: AsyncThrowingStream<PCMChunk, any Error>
    private let task: Task<Void, Never>
    private let state: StreamRelayState

    init(_ source: AsyncThrowingStream<PCMChunk, any Error>) {
        let (pieces, out) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let state = StreamRelayState()
        let task = Task {
            var any = false
            do {
                for try await piece in source {
                    if !any {
                        any = true
                        state.resolve(.success(true))
                    }
                    out.yield(piece)
                }
                state.ended()
                if !any { state.resolve(.success(false)) }
                out.finish()
            } catch {
                state.ended()
                if !any { state.resolve(.failure(error)) }
                out.finish(throwing: error)
            }
        }
        out.onTermination = { _ in task.cancel() }
        self.pieces = pieces
        self.task = task
        self.state = state
    }

    func first() async -> Result<Bool, any Error> {
        await state.wait()
    }

    func cancel() {
        task.cancel()
    }

    /// From the relay's start to the end of the voice's stream (or to now, while it runs).
    var generating: Duration {
        state.generating
    }
}

final class StreamRelayState: Sendable {
    private struct State {
        var result: Result<Bool, any Error>?
        var waiter: CheckedContinuation<Result<Bool, any Error>, Never>?
        var ended: ContinuousClock.Instant?
    }

    private let state = Mutex(State())
    private let start = ContinuousClock.now

    func resolve(_ result: Result<Bool, any Error>) {
        let waiter = state.withLock { state -> CheckedContinuation<Result<Bool, any Error>, Never>? in
            guard state.result == nil else { return nil }
            state.result = result
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func wait() async -> Result<Bool, any Error> {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Result<Bool, any Error>? in
                if let result = state.result { return result }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func ended() {
        state.withLock { $0.ended = ContinuousClock.now }
    }

    var generating: Duration {
        (state.withLock { $0.ended } ?? ContinuousClock.now) - start
    }
}
