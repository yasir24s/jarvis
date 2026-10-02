import Foundation
import JarvisBrain
import Observation

/// B2 part 6: JARVIS's own ChatGPT sign-in, for the menus' item next to "Brain". The sign-in is
/// in JARVIS's Codex home (`CodexHome`), not the user's `~/.codex`, and the user makes it
/// themselves in the browser: "Sign in to ChatGPT…" runs `codex login`, which opens the OAuth
/// flow, and JARVIS only learns whether it worked (`ChatGPTSignInRunning`).
///
/// The item shows, by state:
/// - signed in: "Signed in to ChatGPT", a disabled line;
/// - signing in: "Cancel ChatGPT Sign-in" while the browser flow runs;
/// - signed out: "Sign in to ChatGPT…", which says so in its title when the last try failed;
/// - no `codex`: "Sign in to ChatGPT… (needs the ChatGPT app)", disabled.
/// Signed out, a ChatGPT turn fails with "not signed in" and the on-device model answers.
@MainActor
@Observable
public final class ChatGPTAccount {
    public enum State: Equatable, Sendable {
        /// Before the first status check.
        case checking
        case signedOut
        case signingIn
        case signedIn
        /// The last sign-in did not finish; the reason is in the item's help.
        case failed(String)
        /// No `codex`, or its status could not be read.
        case unavailable(String)
    }

    nonisolated public static let signInTitle = "Sign in to ChatGPT…"
    nonisolated public static let retryTitle = "Sign in to ChatGPT… (the last try didn't finish)"
    nonisolated public static let signedInTitle = "Signed in to ChatGPT"
    nonisolated public static let cancelTitle = "Cancel ChatGPT Sign-in"
    nonisolated public static let checkingTitle = "Checking the ChatGPT sign-in…"
    nonisolated public static let unavailableTitle = "Sign in to ChatGPT… (needs the ChatGPT app)"
    nonisolated public static let signInHelp = "Opens ChatGPT's sign-in in your browser, for JARVIS's own Codex "
        + "sign-in, kept apart from yours. Until then a ChatGPT pick answers on-device."
    nonisolated public static let signingInHelp = "Finish signing in in your browser, or cancel here."
    nonisolated public static let signedInHelp = "JARVIS's own Codex sign-in, kept apart from yours."

    public private(set) var state: State = .checking

    @ObservationIgnored private let runner: any ChatGPTSignInRunning
    @ObservationIgnored private var signInTask: Task<Void, Never>?

    public init(runner: any ChatGPTSignInRunning) {
        self.runner = runner
    }

    /// What the item says.
    public var title: String {
        switch state {
        case .checking: Self.checkingTitle
        case .signedOut: Self.signInTitle
        case .signingIn: Self.cancelTitle
        case .signedIn: Self.signedInTitle
        case .failed: Self.retryTitle
        case .unavailable: Self.unavailableTitle
        }
    }

    /// Whether the item is a button (sign in, or cancel) rather than a disabled line.
    public var actionable: Bool {
        switch state {
        case .signedOut, .signingIn, .failed: true
        case .checking, .signedIn, .unavailable: false
        }
    }

    public var help: String {
        switch state {
        case .checking: Self.signInHelp
        case .signedOut: Self.signInHelp
        case .signingIn: Self.signingInHelp
        case .signedIn: Self.signedInHelp
        case .failed(let why): "The last sign-in didn't finish: \(why). " + Self.signInHelp
        case .unavailable(let why): "\(why). " + Self.signInHelp
        }
    }

    /// Reads the status again, unless a sign-in is running.
    public func refresh() async {
        let status = await runner.status()
        guard state != .signingIn else { return }
        switch status {
        case .signedIn: state = .signedIn
        case .signedOut: if case .failed = state {} else { state = .signedOut }
        case .unavailable(let why): state = .unavailable(why)
        }
    }

    /// The item's action: starts a sign-in, or cancels the one running.
    public func act() {
        if state == .signingIn {
            cancelSignIn()
        } else if actionable {
            signIn()
        }
    }

    public func signIn() {
        guard state != .signingIn else { return }
        state = .signingIn
        let runner = runner
        signInTask = Task { [weak self] in
            let result = await runner.signIn()
            guard let self else { return }
            switch result {
            case .signedIn: self.state = .signedIn
            case .failed(let why): self.state = .failed(why)
            case .cancelled: self.state = .signedOut
            }
            self.signInTask = nil
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    /// Waits for a running sign-in to end (tests).
    public func waitForSignIn() async {
        await signInTask?.value
    }
}
