import Foundation
import JarvisCore

/// The persona writer CoreState is given (the user's choice: both models collaborate, and
/// everything is saved on the Mac). Python asked Ollama alone.
///
/// - The on-device model drafts first.
/// - Claude then gets the same system prompt, the same user text with the draft appended,
///   and the request to improve the draft in exactly the same output format. Its version is
///   taken only if it passes the check CoreState will apply (chosen by comparing `system`
///   with the two `PersonaDistill` prompts); otherwise the draft stands.
/// - With no draft (the on-device model unavailable or failing), Claude alone gets the
///   original text.
/// - Both failing throws, and CoreState then writes nothing, as Python did when Ollama failed.
///
/// One log line says which writer produced the text. No prompt or reply text is logged.
public struct CollaborativePersonaLLM: PersonaLLM {
    private let local: any PersonaLLM
    private let claude: any PersonaLLM
    private let log: @Sendable (String) -> Void

    public init(local: any PersonaLLM, claude: any PersonaLLM,
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.local = local
        self.claude = claude
        self.log = log
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        let draft: String
        do {
            draft = try await local.complete(system: system, user: user, timeout: timeout)
        } catch {
            try Task.checkCancellation()
            let localReason = PersonaWriterError.reason(error)
            do {
                let text = try await claude.complete(system: system, user: user, timeout: timeout)
                log("Personality writer: Claude alone (\(localReason)).")
                return text
            } catch {
                let claudeReason = PersonaWriterError.reason(error)
                log("Personality writer: none (\(localReason); \(claudeReason)).")
                throw PersonaWriterError.bothFailed(local: localReason, claude: claudeReason)
            }
        }
        let improved: String
        do {
            improved = try await claude.complete(system: system, user: Self.improveRequest(user: user, draft: draft),
                                                 timeout: timeout)
        } catch {
            try Task.checkCancellation()
            log("Personality writer: on-device draft (\(PersonaWriterError.reason(error))).")
            return draft
        }
        guard Self.passesCoreStateCheck(improved, system: system) else {
            log("Personality writer: on-device draft (Claude's version failed the check).")
            return draft
        }
        log("Personality writer: Claude, improving the on-device draft.")
        return improved
    }

    /// Claude's user text: the text the on-device model was given, its draft, and the request
    /// to improve the draft in the same output format.
    static func improveRequest(user: String, draft: String) -> String {
        user + "\n\n---\nAn on-device model drafted this reply to the text above:\n" + draft
            + "\n---\nImprove the draft. Follow the instructions exactly and reply in exactly the"
            + " output format they ask for, with nothing else."
    }

    /// The check CoreState applies to a reply to `system`: consolidation's 1 to 8 lines
    /// (`consolidationLines`), distillation's "The user ..." note (`distillNote`). Any other
    /// prompt has no check here, so Claude's version is not taken for it.
    static func passesCoreStateCheck(_ reply: String, system: String) -> Bool {
        if Py.eq(system, PersonaDistill.consolidateSystem) {
            return PersonaDistill.consolidationLines(fromReply: reply) != nil
        }
        if Py.eq(system, PersonaDistill.distillSystem) {
            return PersonaDistill.distillNote(fromReply: reply) != nil
        }
        return false
    }
}
