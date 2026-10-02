import Foundation
import JarvisCore

/// The only way anything speaks (M8). `say(_:turn:)` takes a finished reply: TextClean, then
/// chunking, then the clone, with `say` for any part the clone fails, then the player.
///
/// A reply is split at sentence ends only where the split leaves no silence: a part ends at a
/// boundary when its audio, by `timing`, lasts at least as long as the next part takes to
/// generate, since the next part generates while it plays. With no such boundary the reply is
/// spoken whole, or, past `voiceChunkChars` (default 160), in parts of at most that many
/// characters (P5; D-54 generated a reply of up to 160 characters whole). The log line gives
/// each gap's predicted and actual length. A new reply cancels whatever is queued or playing;
/// `cancelAll()` stops everything.
///
/// V1 part 1: `acknowledge` plays a rendered acknowledgement the moment a message is sent. The
/// reply after it generates while it plays and starts once it has finished, and does not say a
/// short acknowledgement of its own first (`Acknowledgement.spokenText`).
public actor SpeechQueue {
    /// Where `voiceChunkChars` is read from.
    public static let defaultsSuite = "com.jarvis.assistant"
    public static let chunkCharsKey = "voiceChunkChars"
    public static let defaultChunkChars = 160

    /// How long a part takes to generate and how long its audio lasts, by characters.
    public struct Timing: Sendable, Equatable {
        public var generationSeconds: Double
        public var generationSecondsPerChar: Double
        public var audioSecondsPerChar: Double

        public init(generationSeconds: Double, generationSecondsPerChar: Double, audioSecondsPerChar: Double) {
            self.generationSeconds = generationSeconds
            self.generationSecondsPerChar = generationSecondsPerChar
            self.audioSecondsPerChar = audioSecondsPerChar
        }

        public func generation(_ chars: Int) -> Double { generationSeconds + generationSecondsPerChar * Double(chars) }
        public func audio(_ chars: Int) -> Double { audioSecondsPerChar * Double(chars) }
        /// The silence before a part of `next` characters, which generates while a part of
        /// `current` characters plays.
        public func gap(after current: Int, before next: Int) -> Double { max(0, generation(next) - audio(current)) }

        /// The same voice at F5 speed `speed`: a character gets 1/speed of the frames, so its
        /// audio and its share of the generation shrink by that much; the reference's share stays.
        public func at(speed: Double) -> Timing {
            Timing(generationSeconds: generationSeconds, generationSecondsPerChar: generationSecondsPerChar / speed,
                   audioSecondsPerChar: audioSecondsPerChar / speed)
        }
    }

    /// F5 at 4 steps and speed 1 with the short reference, fitted to the live run of 2026-10-01
    /// with the machine under load (1-minute load average about 5): parts of 18, 79 and 97 characters took
    /// 3.8 to 3.9, 7.2 and 8.5 s to generate (within 0.15 s of the fit) and gave 1.21, 5.16 and
    /// 6.41 s of audio. F5 makes a part's audio the reference's length per character of its text.
    public static let f5Timing = Timing(generationSeconds: 2.83, generationSecondsPerChar: 0.0568,
                                        audioSecondsPerChar: 0.0659)

    private let engine: any SpeechEngine
    private let fallback: any SpeechEngine
    private let player: any SpeechPlayer
    private let chunkChars: @Sendable () -> Int
    private let timing: Timing
    /// The voice's speed, read for each reply (U1 part 5); nil keeps `timing` as given.
    private let speed: (@Sendable () -> Double)?
    /// The speed the last reply was spoken at.
    private var lastSpeed: Double?
    private let helperFootprintMB: @Sendable () -> Int?
    private let log: @Sendable (String) -> Void
    private var current: Task<Void, Never>?
    /// The acknowledgement playing, if any; a reply waits for it before its own audio.
    private var acknowledging: Task<Void, Never>?
    /// An acknowledgement was played for the message the next reply answers.
    private var acknowledged = false

    /// - engine: the voice (F5Engine); `fallback` speaks a part it fails (SayEngine).
    /// - helperFootprintMB: the helper's footprint in its last reply, for the log line.
    /// - timing: what the split rule predicts with (`chunks`), at speed 1 when `speed` is given.
    /// - speed: `voiceSpeed`, read for each reply: the reply is timed at it, and when it changed
    ///   since the last reply the engine is released first, so it starts again at the new speed.
    public init(engine: any SpeechEngine, fallback: any SpeechEngine, player: any SpeechPlayer,
                chunkChars: @escaping @Sendable () -> Int = SpeechQueue.chunkCharsFromDefaults,
                timing: Timing = SpeechQueue.f5Timing,
                speed: (@Sendable () -> Double)? = nil,
                helperFootprintMB: @escaping @Sendable () -> Int? = { nil },
                log: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.fallback = fallback
        self.player = player
        self.chunkChars = chunkChars
        self.timing = timing
        self.speed = speed
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
        let timing = speed.map { self.timing.at(speed: $0) } ?? self.timing
        let parts = Self.chunks(clean, limit: chunkChars(), timing: timing)
        let restart = speed != nil && lastSpeed != nil && speed != lastSpeed
        if let speed { lastSpeed = speed }
        current = Task {
            await previous?.value   // the reply before has stopped its audio
            guard !Task.isCancelled else { return }
            if restart { await self.engine.release() }   // the next part starts it at the new speed
            await self.speak(parts, characters: clean.unicodeScalars.count, turn: turn, started: started,
                             timing: timing, after: acknowledgement)
        }
    }

    /// Stops everything: the acknowledgement, the reply being generated or played and anything
    /// after it.
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

    private struct Part: Sendable {
        var chunk: PCMChunk?
        var engine: EngineID?
        var elapsed: Duration
        /// Why the voice gave this part to the fallback.
        var fallbackReason: String?
    }

    private func speak(_ parts: [String], characters: Int, turn: UUID, started: ContinuousClock.Instant,
                       timing: Timing, after acknowledgement: Task<Void, Never>?) async {
        let context = SynthesisContext(turnID: turn)
        var firstAudio: Duration?
        var generating = Duration.zero
        var sayParts = 0
        var stopped = false
        var reportedFallback = false
        let lengths = parts.map(\.unicodeScalars.count)
        let predicted = zip(lengths, lengths.dropFirst()).map { timing.gap(after: $0, before: $1) }
        var actual: [Double] = []
        var lastEnd: ContinuousClock.Instant?
        var next: Task<Part, Never>? = parts.first.map { generate($0, context) }
        for index in parts.indices {
            guard let pending = next else { break }
            let part = await withTaskCancellationHandler {
                await pending.value
            } onCancel: {
                pending.cancel()
            }
            // One group ahead: the next part generates while this one plays.
            next = index + 1 < parts.count ? generate(parts[index + 1], context) : nil
            if Task.isCancelled {
                stopped = true
                break
            }
            generating += part.elapsed
            if let reason = part.fallbackReason, !reportedFallback {
                log("voice: F5 failed (\(reason)); say speaks instead")
                reportedFallback = true
            }
            if part.engine == .say { sayParts += 1 }
            guard let chunk = part.chunk, !chunk.samples.isEmpty else { continue }
            if firstAudio == nil {
                await acknowledgement?.value   // generated while it played; heard after it
                if Task.isCancelled {
                    stopped = true
                    break
                }
            }
            let now = ContinuousClock.now
            if firstAudio == nil { firstAudio = now - started }
            if let lastEnd { actual.append((now - lastEnd) / .seconds(1)) }
            do {
                try await player.play(chunk)
            } catch {
                log("voice: cannot play (\(error))")
            }
            lastEnd = ContinuousClock.now
            if Task.isCancelled {
                stopped = true
                break
            }
        }
        next?.cancel()
        log(Self.summary(characters: characters, parts: parts.count, firstAudio: firstAudio,
                         generating: generating, helperMB: sayParts < parts.count ? helperFootprintMB() : nil,
                         sayParts: sayParts, stopped: stopped, predictedGaps: predicted, actualGaps: actual))
    }

    /// Generates one part with the voice, or with the fallback when the voice throws.
    private func generate(_ text: String, _ context: SynthesisContext) -> Task<Part, Never> {
        let engine = self.engine
        let fallback = self.fallback
        let log = self.log
        return Task {
            let start = ContinuousClock.now
            var reason: String?
            do {
                let chunk = try await Self.collect(engine.synthesize(text, context: context))
                return Part(chunk: chunk, engine: await engine.id, elapsed: ContinuousClock.now - start)
            } catch {
                if Task.isCancelled || error is CancellationError {
                    return Part(chunk: nil, engine: nil, elapsed: ContinuousClock.now - start)
                }
                reason = "\(error)"
            }
            do {
                let chunk = try await Self.collect(fallback.synthesize(text, context: context))
                return Part(chunk: chunk, engine: await fallback.id, elapsed: ContinuousClock.now - start,
                            fallbackReason: reason)
            } catch {
                if !(Task.isCancelled || error is CancellationError) { log("voice: say failed (\(error))") }
                return Part(chunk: nil, engine: nil, elapsed: ContinuousClock.now - start, fallbackReason: reason)
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

    /// `voice: <n> chars in <k> part(s); first audio after <s> s; generated in <g> s; helper <MB> MB`
    /// With two or more parts, `; gaps predicted <p>/<p> s, actual <a>/<a> s` follows the first
    /// audio: the silence before each later part, by `timing` and as played.
    static func summary(characters: Int, parts: Int, firstAudio: Duration?, generating: Duration,
                        helperMB: Int?, sayParts: Int, stopped: Bool,
                        predictedGaps: [Double] = [], actualGaps: [Double] = []) -> String {
        var line = "voice: \(characters) chars in \(parts) part(s); "
        line += firstAudio.map { "first audio after \(seconds($0)) s" } ?? "no audio"
        if !predictedGaps.isEmpty {
            func list(_ gaps: [Double]) -> String {
                gaps.isEmpty ? "n/a" : gaps.map { String(format: "%.1f", $0) }.joined(separator: "/") + " s"
            }
            line += "; gaps predicted \(list(predictedGaps)), actual \(list(actualGaps))"
        }
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

    // MARK: - Chunking

    /// `voiceChunkChars` from the app's defaults, or 160 when it is unset or not positive.
    public static let chunkCharsFromDefaults: @Sendable () -> Int = {
        chunkChars(in: UserDefaults(suiteName: defaultsSuite))
    }

    public static func chunkChars(in defaults: UserDefaults?) -> Int {
        let value = defaults?.integer(forKey: chunkCharsKey) ?? 0
        return value > 0 ? value : defaultChunkChars
    }

    /// The parts of a cleaned reply, in Unicode scalars (Python `len()`). One sentence of at most
    /// `limit` is one part. Otherwise the text is split after each sentence end (a run of . ! ?
    /// followed by a space), and a sentence longer than `limit` is cut at its last space within the
    /// limit (pop_sentences' rule) or at the limit itself. Parts are runs of these pieces joined by
    /// one space, at most `limit` long. A part ends at the first piece boundary where its audio
    /// covers the generation of the part after it (`Timing.gap` is 0), judged from the last part
    /// back; with no such boundary it takes as many pieces as fit, so a reply that fits is whole.
    public static func chunks(_ text: String, limit: Int, timing: Timing = f5Timing) -> [String] {
        let limit = max(1, limit)
        let u = Array(text.unicodeScalars)
        guard !u.isEmpty else { return [] }
        let found = sentences(u)
        if found.count == 1, u.count <= limit { return [text] }
        var pieces: [ArraySlice<Unicode.Scalar>] = []
        for sentence in found {
            var rest = sentence
            while rest.count > limit {
                let window = rest.prefix(limit)
                var cut = window.lastIndex(of: " ") ?? rest.startIndex
                if cut == rest.startIndex { cut = rest.startIndex + limit }
                pieces.append(rest[rest.startIndex..<cut])
                rest = rest[cut...].drop(while: Py.isSpace)
            }
            if !rest.isEmpty { pieces.append(rest) }
        }
        // ends[j]: where the part that starts at piece j ends, decided from the last piece back so
        // that the part after it is known.
        let m = pieces.count
        func length(_ j: Int, _ k: Int) -> Int { pieces[j..<k].reduce(k - j - 1) { $0 + $1.count } }
        var ends = [Int](repeating: m, count: m + 1)
        for j in stride(from: m - 1, through: 0, by: -1) {
            var widest = j + 1
            var covered: Int?
            for k in (j + 1)...m {
                let chars = length(j, k)
                if k > j + 1, chars > limit { break }
                widest = k
                if k < m, timing.gap(after: chars, before: length(k, ends[k])) == 0 {
                    covered = k
                    break
                }
            }
            ends[j] = covered ?? widest
        }
        var parts: [String] = []
        var j = 0
        while j < m {
            var part: [Unicode.Scalar] = []
            for piece in pieces[j..<ends[j]] {
                if !part.isEmpty { part.append(" ") }
                part += piece
            }
            parts.append(string(part))
            j = ends[j]
        }
        return parts
    }

    /// Sentences end after a run of . ! ? that a space follows; the spaces between are dropped.
    private static func sentences(_ u: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
        var out: [ArraySlice<Unicode.Scalar>] = []
        var start = 0
        var i = 0
        while i < u.count {
            guard isSentenceEnd(u[i]) else {
                i += 1
                continue
            }
            var j = i
            while j < u.count, isSentenceEnd(u[j]) { j += 1 }
            if j < u.count, Py.isSpace(u[j]) {
                out.append(u[start..<j])
                while j < u.count, Py.isSpace(u[j]) { j += 1 }
                start = j
            }
            i = j
        }
        if start < u.count { out.append(u[start...]) }
        return out
    }

    private static func isSentenceEnd(_ u: Unicode.Scalar) -> Bool {
        u == "." || u == "!" || u == "?"
    }

    private static func string(_ u: [Unicode.Scalar]) -> String {
        String(String.UnicodeScalarView(u))
    }
}
