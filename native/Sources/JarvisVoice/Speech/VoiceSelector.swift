import Foundation
import Synchronization

/// V6: the voice SpeechQueue speaks with: Qwen (`QwenEngine`) or F5 (`F5Engine`), by the
/// `voiceEngine` setting, read for each reply.
///
/// - With `qwen` chosen and available, Qwen speaks, streamed, and the F5 helper is released
///   first, so the two models are never loaded together.
/// - With `qwen` chosen but its helper, model or reference missing (or Qwen resting after two
///   failures), F5 speaks, and the log says why, once per reason in a row.
/// - When Qwen fails before its first piece (it cannot start, errs or times out), its helper is
///   released and F5 speaks that reply. F5 failing as well leaves the reply to the queue's own
///   fallback, `say`.
/// - With `f5` chosen, Qwen is released and F5 speaks as before V6.
public actor VoiceSelector: SpeechEngine {
    private let qwen: QwenEngine
    private let f5: F5Engine
    private let choice: @Sendable () -> VoiceEngineChoice
    private let log: @Sendable (String) -> Void
    /// The engine of the last reply.
    public private(set) var id: EngineID = .qwen
    private var lastNotice: String?
    private let shared = Mutex<EngineID?>(nil)

    public init(qwen: QwenEngine, f5: F5Engine, choice: @escaping @Sendable () -> VoiceEngineChoice,
                log: @escaping @Sendable (String) -> Void) {
        self.qwen = qwen
        self.f5 = f5
        self.choice = choice
        self.log = log
    }

    /// The engine the next reply goes to, as the settings and the installs are now.
    public nonisolated var current: EngineID {
        choice() == .qwen && qwen.isAvailable ? .qwen : .f5
    }

    /// Whether the voice in use is available: Qwen's or F5's. The app reports `say` otherwise.
    public nonisolated var isAvailable: Bool {
        current == .qwen || f5.isAvailable
    }

    /// The helper's footprint in the last reply, of the engine that spoke it.
    public nonisolated var lastFootprintMB: Int? {
        shared.withLock { $0 } == .f5 ? f5.lastFootprintMB : qwen.lastFootprintMB
    }

    public func streaming() async -> Bool { current == .qwen }

    public func expectedSeconds(for text: String) async -> Double? {
        current == .qwen ? await qwen.expectedSeconds(for: text) : nil
    }

    public func synthesize(_ sentence: String, context: SynthesisContext) -> AsyncThrowingStream<PCMChunk, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: PCMChunk.self)
        let task = Task {
            await self.run(sentence, context: context, into: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func warm() async {
        if current == .qwen {
            await f5.release()
            await qwen.warm()
        } else {
            await qwen.release()
            await f5.warm()
        }
    }

    public func release() async {
        await qwen.release()
        await f5.release()
    }

    private func use(_ engine: EngineID) {
        id = engine
        shared.withLock { $0 = engine }
    }

    private func run(_ text: String, context: SynthesisContext,
                     into out: AsyncThrowingStream<PCMChunk, any Error>.Continuation) async {
        if current == .qwen {
            lastNotice = nil
            await f5.release()
            use(.qwen)
            var pieces = 0
            do {
                for try await chunk in await qwen.synthesize(text, context: context) {
                    pieces += 1
                    out.yield(chunk)
                }
                try Task.checkCancellation()
                return out.finish()
            } catch {
                if pieces > 0 || Task.isCancelled || error is CancellationError {
                    return out.finish(throwing: error)
                }
                log("voice: Qwen failed (\(error)); F5 speaks this reply")
                await qwen.release()
            }
        } else {
            if choice() == .qwen {
                let notice = "voice: Qwen is not available (its helper, model or reference is missing, or it is resting); F5 speaks"
                if notice != lastNotice { log(notice) }
                lastNotice = notice
            }
            await qwen.release()
        }
        use(.f5)
        do {
            for try await chunk in await f5.synthesize(text, context: context) {
                out.yield(chunk)
            }
            out.finish()
        } catch {
            out.finish(throwing: error)
        }
    }
}
