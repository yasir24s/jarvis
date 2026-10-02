import Foundation

/// One row of the chat transcript (plan: M02-M04 §3.12).
public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable, Equatable {
        case user
        case assistant
        /// The app's own notes in the transcript, such as the card's "Cancelled.": never sent
        /// to the brain and never spoken.
        case system
    }

    /// An assistant row is `streaming` while its turn runs and shows plain text; once the turn
    /// ends it is `finished` and renders through `MarkdownText`. User and system rows are always
    /// finished.
    public enum Phase: Sendable, Equatable {
        case streaming
        case finished
    }

    public let id: UUID
    public let role: Role
    public internal(set) var text: String
    public internal(set) var phase: Phase
    /// An assistant row fed by a message the model retracted after a refusal (R6): it is shown
    /// struck through, as plain text.
    public internal(set) var retracted: Bool
    /// UI1 part 4: the user stopped this reply; it keeps what was shown, marked "stopped".
    public internal(set) var stopped: Bool
    /// UI1 part 5: the turn the row came from; nil for rows made without one (the app's notes, a
    /// refusal made here, rows a live update restored). Only a user row with one can be edited.
    public internal(set) var turnID: UUID?
    /// UI1 part 5: on a user message that has been edited, the group its versions share.
    public internal(set) var versionGroup: UUID?

    public init(id: UUID = UUID(), role: Role, text: String, phase: Phase, retracted: Bool = false,
                stopped: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.phase = phase
        self.retracted = retracted
        self.stopped = stopped
    }

    /// Only finished assistant rows are markdown. User text, streaming text and retracted rows
    /// stay plain.
    public var rendersMarkdown: Bool {
        role == .assistant && phase == .finished && !retracted
    }
}
