import Foundation

public enum TaintPolicy {
    public static let untrusted: Set<String> = [
        "web_search", "see_screen", "read_clipboard", "read_file", "get_messages", "get_news", "summarize_page",
        "search_memory"   // native (P6b): it quotes past conversations word for word
    ]
    public static let executors: Set<String> = [
        "run_command", "run_applescript", "run_powershell", "send_message", "send_email", "type_text", "run_shortcut",
        "personality_note", "personality_rewrite", "write_file", "delete_file", "move_file",
        "forget_memory", "correct_memory", "restore_memory"
    ]
    /// Native (W1 part 7a, taint by source): the three executors that change memory. They still
    /// run on a turn whose only untrusted read was its own memory search, so "search, then forget
    /// by id" works in one request. Every other executor is refused after any read.
    public static let memoryExecutors: Set<String> = ["forget_memory", "correct_memory", "restore_memory"]

    /// Whether a tainted turn refuses `tool`, given what tainted it: the turn's `taintedBy`, in
    /// order ("paste" when it began with pasted text). Only executors are refused. A memory tool
    /// is allowed when every source is `search_memory`; any other source (a file, the screen, the
    /// clipboard, the web, a paste) still blocks it. An empty list fails closed.
    public static func blocks(_ tool: String, taintedBy sources: [String]) -> Bool {
        guard executors.contains(tool) else { return false }
        let onlyMemorySearch = !sources.isEmpty && sources.allSatisfy { $0 == "search_memory" }
        return !(memoryExecutors.contains(tool) && onlyMemorySearch)
    }

    public static let blockedTextClaude = "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content in the same request."
    public static let blockedTextLocal = "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content (web, screen, clipboard, files) in the same request."
}
