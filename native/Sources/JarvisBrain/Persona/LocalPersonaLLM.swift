import Foundation
import FoundationModels
import JarvisCore

/// The on-device persona writer: Python sent these prompts to Ollama with `temperature 0`.
/// One session per call, holding the system prompt and no tools, sampled greedily. The
/// session is a local, so it is released when the call returns. An unavailable model, a
/// failed generation and the timeout all throw.
public struct LocalPersonaLLM: PersonaLLM {
    /// Greedy sampling, FoundationModels' form of `temperature 0`.
    public static let options = GenerationOptions(samplingMode: .greedy)

    private let model: any LocalLanguageModel
    private let timeoutWait: @Sendable (Duration) async throws -> Void

    /// - Parameters:
    ///   - model: nil means `SystemLocalModel()`. Tests pass a fake.
    ///   - timeoutWait: waits out the timeout, which fires when it returns. Tests pass their own.
    public init(model: (any LocalLanguageModel)? = nil,
                timeoutWait: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.model = model ?? SystemLocalModel()
        self.timeoutWait = timeoutWait
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        if let reason = await model.unavailableReason() {
            throw PersonaWriterError.localUnavailable(reason)
        }
        let session = await model.session(instructions: system, tools: [])
        let wait = timeoutWait
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    var reply = ""
                    for try await snapshot in session.streamResponse(to: user, options: Self.options) {
                        reply = snapshot    // cumulative: the last snapshot is the whole reply
                    }
                    try Task.checkCancellation()    // a stream cut short is not a reply
                    return reply
                }
                group.addTask {
                    try await wait(timeout)
                    throw PersonaWriterError.localFailed("timed out after \(timeout)")
                }
                defer { group.cancelAll() }
                guard let reply = try await group.next() else { throw CancellationError() }
                return reply
            }
        } catch let error as PersonaWriterError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PersonaWriterError.localFailed(PersonaWriterError.reason(error))
        }
    }
}
