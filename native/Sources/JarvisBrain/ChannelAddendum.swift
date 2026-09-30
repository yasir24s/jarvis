import JarvisTools

/// What BrainRouter appends to the system prompt for a channel: plan §3.9, step 10, after the
/// system prompt and before the history preamble. Python has only a voice channel, so the
/// voice addendum is empty and the voice prompt stays byte-identical to Python's.
public enum ChannelAddendum {
    /// The text channel's addendum, copied from plan §3.9 byte for byte (it starts with two
    /// newlines).
    public static let textChat = "\n\nCHANNEL: TEXT CHAT. The user typed this message and will READ your reply on screen; it is not spoken aloud. You are still exactly the JARVIS described above: the same dry wit, the same brevity, 'sir', no emoji. Default to one or two crisp sentences, as if speaking. Go longer only when the user asks for detail or the answer genuinely needs it (steps, code, a comparison), and use light Markdown (bold, inline code, short lists) only then, never as decoration."

    public static func text(_ channel: Channel) -> String {
        switch channel {
        case .voice: ""
        case .text: textChat
        }
    }
}
