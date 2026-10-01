/// When the chat window opens (D-43): JARVIS is a regular app whose main window is the chat.
/// It opens at launch unless the app was started with `--background`, which the future login
/// item passes. Closing it leaves JARVIS running; the Dock icon and Open Chat bring it back.
public enum ChatLaunch {
    /// The launch argument that keeps the chat window closed.
    public static let backgroundFlag = "--background"

    /// Whether the chat window opens at launch. `arguments` is the whole command line; the
    /// first item is the executable and is not an option.
    public static func opensWindow(arguments: [String]) -> Bool {
        !arguments.dropFirst().contains(backgroundFlag)
    }
}

extension ChatLaunch {
    /// After a live update (U1) the window is as it was before the swap: open only if it was.
    public static func opensWindow(arguments: [String], resume: ResumeState?) -> Bool {
        if let resume { return resume.window.open }
        return opensWindow(arguments: arguments)
    }
}
