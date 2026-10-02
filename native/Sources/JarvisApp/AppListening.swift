import Foundation
import JarvisChat
import JarvisCore
import JarvisVoice

/// M9a: push-to-talk's microphone and transcriber, for the chat's `PushToTalkModel`. The
/// microphone opens in `begin` and closes in `finish` or `cancel`; between sessions nothing holds
/// it. The transcriber is told the vocabulary (`WHISPER_PROMPT`'s words, the profile name and the
/// last 12 corrections), drops results under `STT_MIN_CONF` (bumping `stt_segments_dropped` in
/// the app's research store), and passes the rest through CoreState's corrections.
actor AppListening: VoiceListening {
    private let mic: MicCapture
    private let transcriber: Transcriber
    private let core: CoreState
    private let log: @Sendable (String) -> Void
    private var session: Task<TranscriptOutcome, Never>?

    init(core: CoreState, research: any ResearchCounting,
         log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .voice) }) {
        self.core = core
        self.log = log
        mic = MicCapture(log: log)
        transcriber = Transcriber(
            recognizer: AppleSpeechRecognizer(), research: research,
            corrections: { text in
                do {
                    return try await core.applyCorrections(text)
                } catch {
                    log("speech: corrections not applied (\(error))")
                    return text
                }
            },
            log: log)
    }

    func access() async -> ListeningAccess {
        .granted
    }

    func begin(level: @escaping @Sendable (Double) -> Void,
               preview: @escaping @Sendable (String) -> Void) async throws {
        let inputs = await core.whisperVocabularyInputs()
        let vocabulary = Vocabulary.contextualStrings(base: Vocabulary.basePrompt(), name: inputs.name,
                                                      meant: inputs.meant)
        // Both subscribe before the microphone opens, so neither misses the first frame.
        let frames = await mic.frames()
        let meter = await mic.frames()
        try await mic.start()
        Task.detached(priority: .userInitiated) {
            for await frame in meter { level(frame.level) }
        }
        let transcriber = self.transcriber
        session = Task(priority: .userInitiated) {
            await transcriber.transcribe(frames, vocabulary: vocabulary, preview: preview)
        }
    }

    func finish() async -> HeardOutcome {
        await mic.stop()
        let outcome = await session?.value
        session = nil
        switch outcome {
        case .text(let text, _): return .text(text)
        case .nothing(let dropped): return .nothing(dropped: dropped)
        case .unavailable: return .unavailable
        case .cancelled, nil: return .cancelled
        }
    }

    func cancel() async {
        session?.cancel()
        await mic.stop()
        _ = await session?.value
        session = nil
    }
}
