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

    public init(id: UUID = UUID(), role: Role, text: String, phase: Phase) {
        self.id = id
        self.role = role
        self.text = text
        self.phase = phase
    }

    /// Only finished assistant rows are markdown. User text and streaming text stay plain.
    public var rendersMarkdown: Bool {
        role == .assistant && phase == .finished
    }
}
