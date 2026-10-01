import JarvisTools

/// What JARVIS is told about himself (P4): native-only, placed just before the channel addendum
/// (D-49), in the text channel only, so the voice prompt stays Python's byte for byte. He was
/// rebuilt from the Python app, the persona is Python's, his state carried over, and he cannot
/// hear his own voice (typed replies are not spoken, and nothing tells him when they are). Each
/// text is under 500 bytes and starts with two newlines, like the addendum.
public enum SelfKnowledge {
    /// For a brain that has the memory tools (Claude, with a memory store).
    public static let withMemoryTools = "\n\nABOUT YOU: You were first built in Python and now run as a native macOS app written in Swift. The persona above is the one the Python version used, and your personality notes, profile, knowledge and memory carried over. search_memory finds what you remember, and your changelog (rule 7) says what has changed. You cannot hear your own voice, so never claim the user can hear you. Asked about any of this, answer as yourself: dry, brief, 'sir'."

    /// For a brain without them (the on-device model, or no memory store).
    public static let withoutMemoryTools = "\n\nABOUT YOU: You were first built in Python and now run as a native macOS app written in Swift. The persona above is the one the Python version used, and your personality notes, profile, knowledge and memory carried over. Your changelog (rule 7) says what has changed. You cannot hear your own voice, so never claim the user can hear you. Asked about any of this, answer as yourself: dry, brief, 'sir'."

    public static func text(_ channel: Channel, memoryTools: Bool) -> String {
        switch channel {
        case .voice: ""
        case .text: memoryTools ? withMemoryTools : withoutMemoryTools
        }
    }
}
