import JarvisBrain
import JarvisCore
import JarvisTools

/// What the composer holds: its text, and whether any of it arrived by paste or
/// drag-and-drop (X-8). Pasted text is external content, so the input it becomes starts its
/// turn tainted (D-8, plan §3.5).
public struct ComposerDraft: Sendable, Equatable {
    public var text: String
    /// Set by a paste or a drop; it stays set until the draft is sent.
    public private(set) var pasted: Bool

    public init(text: String = "", pasted: Bool = false) {
        self.text = text
        self.pasted = pasted
    }

    /// The composer saw a paste or a drop: the next input is `pasted: true`.
    public mutating func notePaste() {
        pasted = true
    }

    /// The text-channel input this draft sends, or nil when nothing is left after Python's
    /// `strip()`, the same trim `TurnCoordinator.submit` applies.
    public var input: UserInput? {
        guard !Py.strip(text).isEmpty else { return nil }
        return UserInput(text: text, channel: .text, pasted: pasted)
    }
}

/// What Return does in the composer (plan §3.12): Return sends, Shift+Return adds a newline.
public enum ComposerReturn: Sendable, Equatable {
    case send
    case newline

    public static func action(shift: Bool) -> ComposerReturn {
        shift ? .newline : .send
    }
}
