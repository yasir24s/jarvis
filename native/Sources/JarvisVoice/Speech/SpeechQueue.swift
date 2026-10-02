import Foundation
import JarvisCore

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
public actor SpeechQueue {
    /// The app's defaults suite, where the voice settings are read from.
    public static let defaultsSuite = "com.jarvis.assistant"

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
    private let helperFootprintMB: @Sendable () -> Int?
    private let log: @Sendable (String) -> Void
    private var current: Task<Void, Never>?
    /// The acknowledgement playing, if any; a reply waits for it before its own audio.
    private var acknowledging: Task<Void, Never>?
    /// An acknowledgement was played for the message the next reply answers.
    private var acknowledged = false

    /// - engine: the voice (F5Engine); `fallback` speaks a reply it fails (SayEngine).
    /// - speed: `voiceSpeed`, read for each reply: when it changed since the last reply the
    ///   engine is released first, so it starts again at the new speed.
    /// - reference: the reference the voice speaks with (`voiceReference`), read and acted on
    ///   in the same way.
    /// - tooLong: given the cleaned reply, why the voice cannot generate it in one go (F5Engine's
    ///   `tooLong`), or nil. Such a reply goes to `fallback` without asking the voice.
    /// - helperFootprintMB: the helper's footprint in its last reply, for the log line.
    public init(engine: any SpeechEngine, fallback: any SpeechEngine, player: any SpeechPlayer,
                speed: (@Sendable () -> Double)? = nil,
                reference: (@Sendable () -> String)? = nil,
                tooLong: @escaping @Sendable (String) -> String? = { _ in nil },
                helperFootprintMB: @escaping @Sendable () -> Int? = { nil },
                log: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.fallback = fallback
        self.player = player
        self.speed = speed
        self.reference = reference
        self.tooLong = tooLong
        self.helperFootprintMB = helperFootprintMB
        self.log = log
    }

    /// Plays an acknowledgement clip at once, after stopping whatever is queued or playing (the
    /// last reply, or an acknowledgement before this one). Logs how long after `sentAt`, when
    /// the message was sent, its audio was handed to the player.
    public func acknowledge(_ clip: PCMChunk, line: String, sentAt: ContinuousClock.Instant) {
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
    /// playing finishes first.
    public func say(_ text: String, turn: UUID) {
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
        let overflow = tooLong(clean)
        current = Task {
            await previous?.value   // the reply before has stopped its audio
            guard !Task.isCancelled else { return }
            if restart { await self.engine.release() }   // the next request starts it with the new setting
            await self.speak(clean, turn: turn, started: started, overflow: overflow, after: acknowledgement)
        }
    }

    /// Stops everything: the acknowledgement, and the reply being generated or played.
    public func cancelAll() async {
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

    private func speak(_ text: String, turn: UUID, started: ContinuousClock.Instant, overflow: String?,
                       after acknowledgement: Task<Void, Never>?) async {
        let characters = text.unicodeScalars.count
        if let overflow {
            log("voice: \(characters) chars do not fit the voice (\(overflow)); say speaks the reply")
        }
        let pending = generate(text, SynthesisContext(turnID: turn), withVoice: overflow == nil)
        let reply = await withTaskCancellationHandler {
            await pending.value
        } onCancel: {
            pending.cancel()
        }
        var firstAudio: Duration?
        var stopped = Task.isCancelled
        if !stopped {
            if let reason = reply.fallbackReason {
                log("voice: F5 failed (\(reason)); say speaks instead")
            }
            if let chunk = reply.chunk, !chunk.samples.isEmpty {
                await acknowledgement?.value   // generated while it played; heard after it
                if Task.isCancelled {
                    stopped = true
                } else {
                    firstAudio = ContinuousClock.now - started
                    do {
                        try await player.play(chunk)
                    } catch {
                        log("voice: cannot play (\(error))")
                    }
                    stopped = Task.isCancelled
                }
            }
        }
        let byFallback = reply.engine == .say
        log(Self.summary(characters: characters, firstAudio: firstAudio, generating: reply.elapsed,
                         helperMB: byFallback ? nil : helperFootprintMB(), sayParts: byFallback ? 1 : 0,
                         stopped: stopped))
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
    /// The "1 part(s)" stays from when replies were split, so the line reads as it always has.
    static func summary(characters: Int, firstAudio: Duration?, generating: Duration,
                        helperMB: Int?, sayParts: Int, stopped: Bool) -> String {
        var line = "voice: \(characters) chars in 1 part(s); "
        line += firstAudio.map { "first audio after \(seconds($0)) s" } ?? "no audio"
        line += "; generated in \(seconds(generating)) s; helper "
        line += helperMB.map { "\($0) MB" } ?? "n/a"
        if sayParts > 0 { line += "; say spoke \(sayParts) part(s)" }
        if stopped { line += "; stopped" }
        return line
    }

    private static func seconds(_ d: Duration, digits: Int = 1) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.\(digits)f", s)
    }
}
