import Foundation
import JarvisCore

/// The only way anything speaks (M8). `say(_:turn:)` takes a finished reply: TextClean, then
/// chunking, then the clone, with `say` for any part the clone fails, then the player.
///
/// A reply of at most `voiceChunkChars` characters (default 160) is generated whole: F5 makes
/// audio about 3.6 times slower than it plays, so sentence by sentence would leave a pause
/// between sentences (D-54). A longer reply is split at sentence ends into groups of at most
/// that many characters, and the next group is generated while the one before it plays.
/// A new reply cancels whatever is queued or playing; `cancelAll()` stops everything.
public actor SpeechQueue {
    /// Where `voiceChunkChars` is read from.
    public static let defaultsSuite = "com.jarvis.assistant"
    public static let chunkCharsKey = "voiceChunkChars"
    public static let defaultChunkChars = 160

    private let engine: any SpeechEngine
    private let fallback: any SpeechEngine
    private let player: any SpeechPlayer
    private let chunkChars: @Sendable () -> Int
    private let helperFootprintMB: @Sendable () -> Int?
    private let log: @Sendable (String) -> Void
    private var current: Task<Void, Never>?

    /// - engine: the voice (F5Engine); `fallback` speaks a part it fails (SayEngine).
    /// - helperFootprintMB: the helper's footprint in its last reply, for the log line.
    public init(engine: any SpeechEngine, fallback: any SpeechEngine, player: any SpeechPlayer,
                chunkChars: @escaping @Sendable () -> Int = SpeechQueue.chunkCharsFromDefaults,
                helperFootprintMB: @escaping @Sendable () -> Int? = { nil },
                log: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.fallback = fallback
        self.player = player
        self.chunkChars = chunkChars
        self.helperFootprintMB = helperFootprintMB
        self.log = log
    }

    /// Speaks a finished reply, after cancelling whatever is queued or playing.
    public func say(_ text: String, turn: UUID) {
        let started = ContinuousClock.now
        let previous = current
        previous?.cancel()
        guard let clean = TextClean.clean(text) else {
            current = nil
            return
        }
        let parts = Self.chunks(clean, limit: chunkChars())
        current = Task {
            await previous?.value   // the reply before has stopped its audio
            guard !Task.isCancelled else { return }
            await self.speak(parts, characters: clean.unicodeScalars.count, turn: turn, started: started)
        }
    }

    /// Stops everything: the reply being generated or played and anything after it.
    public func cancelAll() async {
        let running = current
        current = nil
        running?.cancel()
        await running?.value
        await player.stop()
    }

    /// Waits for the reply in hand to finish (tests, and quit after `cancelAll`).
    public func idle() async {
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

    private func speak(_ parts: [String], characters: Int, turn: UUID, started: ContinuousClock.Instant) async {
        let context = SynthesisContext(turnID: turn)
        var firstAudio: Duration?
        var generating = Duration.zero
        var sayParts = 0
        var stopped = false
        var reportedFallback = false
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
        next?.cancel()
        log(Self.summary(characters: characters, parts: parts.count, firstAudio: firstAudio,
                         generating: generating, helperMB: sayParts < parts.count ? helperFootprintMB() : nil,
                         sayParts: sayParts, stopped: stopped))
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
    static func summary(characters: Int, parts: Int, firstAudio: Duration?, generating: Duration,
                        helperMB: Int?, sayParts: Int, stopped: Bool) -> String {
        var line = "voice: \(characters) chars in \(parts) part(s); "
        line += firstAudio.map { "first audio after \(seconds($0)) s" } ?? "no audio"
        line += "; generated in \(seconds(generating)) s; helper "
        line += helperMB.map { "\($0) MB" } ?? "n/a"
        if sayParts > 0 { line += "; say spoke \(sayParts) part(s)" }
        if stopped { line += "; stopped" }
        return line
    }

    private static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return String(format: "%.1f", s)
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

    /// The parts of a cleaned reply, in Unicode scalars (Python `len()`). At most `limit` is one
    /// part. Longer text is split after each sentence end (a run of . ! ? followed by a space),
    /// a sentence longer than `limit` is cut at its last space within the limit (pop_sentences'
    /// rule) or at the limit itself, and the pieces are packed in order into parts of at most
    /// `limit`, joined by one space.
    public static func chunks(_ text: String, limit: Int) -> [String] {
        let limit = max(1, limit)
        let u = Array(text.unicodeScalars)
        if u.count <= limit { return u.isEmpty ? [] : [text] }
        var pieces: [ArraySlice<Unicode.Scalar>] = []
        for sentence in sentences(u) {
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
        var parts: [String] = []
        var group: [Unicode.Scalar] = []
        for piece in pieces {
            if group.isEmpty {
                group = Array(piece)
            } else if group.count + 1 + piece.count <= limit {
                group.append(" ")
                group += piece
            } else {
                parts.append(string(group))
                group = Array(piece)
            }
        }
        if !group.isEmpty { parts.append(string(group)) }
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
