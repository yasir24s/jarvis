#if DEBUG
import JarvisTools

/// A harmless confirmation for checking the card and the system sheet at the screen, in DEBUG
/// builds only (release builds do not contain it). A-13 as planned needs `delete_file`, whose
/// body arrives in M5. This one's action only returns a fixed line: it touches no file, runs no
/// command and has no other effect.
public enum TestConfirmation {
    /// The DEBUG menu item.
    public static let menuTitle = "Test confirmation"
    /// What the card and the system sheet describe.
    public static let desc = "the debug test confirmation, which changes nothing"
    /// All that approving it does: this line is the reply.
    public static let approved = "Test confirmation approved, sir."

    /// Stashes it on `gate`, where a confirm-tier tool would stash its action.
    public static func stash(on gate: ConfirmationGate) async {
        await gate.stash(desc: desc, action: { approved }, turn: TurnContext(channel: .text))
    }
}
#endif
