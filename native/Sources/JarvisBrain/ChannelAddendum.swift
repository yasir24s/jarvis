import JarvisTools

/// What BrainRouter appends to the system prompt for a channel: plan §3.9, step 10, after the
/// system prompt and before the history preamble. Python has only a voice channel, so the
/// voice addendum is empty and the voice prompt stays byte-identical to Python's.
public enum ChannelAddendum {
    /// The text channel's addendum, copied from plan §3.9 byte for byte (it starts with two
    /// newlines).
    public static let textChat = "\n\nCHANNEL: TEXT CHAT. The user typed this message and will READ your reply on screen; it is not spoken aloud. The spoken-reply rules above about brevity and no markdown do not apply here: you may answer in a few short paragraphs, and you may use light Markdown (bold, italics, inline code, short bullet lists) when it genuinely helps. Still no emoji, still address the user as 'sir', still keep the JARVIS voice."

    public static func text(_ channel: Channel) -> String {
        switch channel {
        case .voice: ""
        case .text: textChat
        }
    }
}
