import Foundation

public enum TaintPolicy {
    public static let untrusted: Set<String> = [
        "web_search", "see_screen", "read_clipboard", "read_file", "get_messages", "get_news", "summarize_page"
    ]
    public static let executors: Set<String> = [
        "run_command", "run_applescript", "run_powershell", "send_message", "send_email", "type_text", "run_shortcut",
        "personality_note", "personality_rewrite", "write_file", "delete_file", "move_file",
        "forget_memory", "correct_memory"
    ]
    public static let blockedTextClaude = "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content in the same request."
    public static let blockedTextLocal = "Blocked for safety: I won't run scripts, send messages or email, or type keystrokes after reading external content (web, screen, clipboard, files) in the same request."
}
