import Foundation
import JarvisCore

/// Text from the collaborative writer, and which writer it came from.
public struct AttributedText: Sendable, Equatable {
    public enum Author: Sendable, Equatable {
        case local                         // the on-device draft stands
        case claude                        // Claude alone: there was no draft
        case improved(draft: String)       // Claude's improvement of `draft`, which passed the check
    }

    public let text: String
    public let author: Author

    public init(text: String, author: Author) {
        self.text = text
        self.author = author
    }
}

/// A writer that says who wrote its text: the memory compile records it as each fact's `by`.
public protocol AttributedWriting: Sendable {
    func write(system: String, user: String, timeout: Duration) async throws -> AttributedText
}

/// The persona writer CoreState is given (the user's choice: both models collaborate, and
/// everything is saved on the Mac). Python asked Ollama alone. P2's memory compile uses the
/// same two writers with its own validator.
///
/// - The on-device model drafts first.
/// - Claude then gets the same system prompt, the same user text with the draft appended,
///   and the request to improve the draft in exactly the same output format. Its version is
///   taken only if it passes the validator; otherwise the draft stands. The default validator
///   is the check CoreState will apply (chosen by comparing `system` with the two
///   `PersonaDistill` prompts).
/// - With no draft (the on-device model unavailable or failing), Claude alone gets the
///   original text.
/// - `claudeInput` rewrites what Claude is given (the text and the draft); the on-device model
///   always gets the text unchanged. P2's fact compile redacts with it (D-51 P3).
/// - Both failing throws, and CoreState then writes nothing, as Python did when Ollama failed.
///
/// One log line, headed by `name`, says which writer produced the text. No prompt or reply
/// text is logged.
public struct CollaborativePersonaLLM: PersonaLLM, AttributedWriting {
    /// Whether Claude's `reply` to `system` may replace the draft.
    public typealias Validator = @Sendable (_ reply: String, _ system: String) -> Bool

    private let local: any PersonaLLM
    private let claude: any PersonaLLM
    private let validator: Validator
    private let name: String
    private let claudeInput: @Sendable (String) -> String
    private let log: @Sendable (String) -> Void

    public init(local: any PersonaLLM, claude: any PersonaLLM,
                validator: @escaping Validator = CollaborativePersonaLLM.passesCoreStateCheck,
                name: String = "Personality writer",
                claudeInput: @escaping @Sendable (String) -> String = { $0 },
                log: @escaping @Sendable (String) -> Void = { JarvisLog.log($0, category: .state) }) {
        self.local = local
        self.claude = claude
        self.validator = validator
        self.name = name
        self.claudeInput = claudeInput
        self.log = log
    }

    public func complete(system: String, user: String, timeout: Duration) async throws -> String {
        try await write(system: system, user: user, timeout: timeout).text
    }

    public func write(system: String, user: String, timeout: Duration) async throws -> AttributedText {
        let draft: String
        do {
            draft = try await local.complete(system: system, user: user, timeout: timeout)
        } catch {
            try Task.checkCancellation()
            let localReason = PersonaWriterError.reason(error)
            do {
                let text = try await claude.complete(system: system, user: claudeInput(user), timeout: timeout)
                log("\(name): Claude alone (\(localReason)).")
                return AttributedText(text: text, author: .claude)
            } catch {
                let claudeReason = PersonaWriterError.reason(error)
                log("\(name): none (\(localReason); \(claudeReason)).")
                throw PersonaWriterError.bothFailed(local: localReason, claude: claudeReason)
            }
        }
        let improved: String
        do {
            improved = try await claude.complete(system: system,
                                                 user: Self.improveRequest(user: claudeInput(user),
                                                                           draft: claudeInput(draft)),
                                                 timeout: timeout)
        } catch {
            try Task.checkCancellation()
            log("\(name): on-device draft (\(PersonaWriterError.reason(error))).")
            return AttributedText(text: draft, author: .local)
        }
        guard validator(improved, system) else {
            log("\(name): on-device draft (Claude's version failed the check).")
            return AttributedText(text: draft, author: .local)
        }
        log("\(name): Claude, improving the on-device draft.")
        return AttributedText(text: improved, author: .improved(draft: draft))
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
    public static func passesCoreStateCheck(_ reply: String, system: String) -> Bool {
        if Py.eq(system, PersonaDistill.consolidateSystem) {
            return PersonaDistill.consolidationLines(fromReply: reply) != nil
        }
        if Py.eq(system, PersonaDistill.distillSystem) {
            return PersonaDistill.distillNote(fromReply: reply) != nil
        }
        return false
    }
}
