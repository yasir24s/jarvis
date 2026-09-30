import JarvisCore
import JarvisTools

/// What a typed confirmation must pass (plan: M02-M04 §3.4): the app's `LAConfirmAuthenticator`
/// (Touch ID, or the login password), a fake in tests.
public protocol TextConfirmAuthenticator: ConfirmAuthenticator {
    /// LocalAuthentication's `canEvaluatePolicy(.deviceOwnerAuthentication)`. False when this
    /// Mac has no login password: then typed confirmation is refused (`TextConfirmation.cannotVerify`).
    func canAuthenticate() -> Bool
}

/// Typed confirmation (plan §3.4): the card's strings, the owner check's settings, and the
/// additive research counters.
public enum TextConfirmation {
    /// Bumped once per owner check that passes (plan §3.4, §3.12; additive, native only).
    public static let approvedCounter = "text_confirm_approved"
    /// Bumped once per owner check that fails, is cancelled or times out.
    public static let deniedCounter = "text_confirm_denied"

    /// The reply when the owner check cannot run on this Mac (no login password).
    public static let cannotVerify = "I can't verify it's you at the keyboard, sir — say 'confirm' instead."
    /// The local row the card's Cancel button leaves.
    public static let cancelled = "Cancelled."
    /// What the card's Confirm button sends, as if it were typed. It is an `Affirmation`.
    public static let confirmInput = "confirm"
    /// What the card's Cancel button hands the gate. It is not an `Affirmation`, so the gate
    /// only clears its slot: no owner check, and the action does not run.
    public static let cancelInput = "cancel"

    /// The system sheet's fallback button.
    public static let fallbackTitle = "Use Password"
    /// A system sheet still up after this long is invalidated, and counts as a no.
    public static let promptTimeout: Duration = .seconds(60)

    /// The reason the system sheet shows for the confirmation described by `desc`.
    public static func localizedReason(_ desc: String) -> String {
        "confirm: \(desc)"
    }

    /// The card's countdown: whole seconds left until `deadline`, rounded up, and 0 once it has
    /// passed. A fresh confirmation shows 25.
    public static func secondsLeft(until deadline: ContinuousClock.Instant, now: ContinuousClock.Instant) -> Int {
        let left = now.duration(to: deadline)
        guard left > .zero else { return 0 }
        let (seconds, attoseconds) = left.components
        return Int(seconds) + (attoseconds > 0 ? 1 : 0)
    }

    /// The gate's staleness rule (`now > deadline`), as the card applies it.
    public static func isStale(_ pending: PendingConfirmation, now: ContinuousClock.Instant) -> Bool {
        now > pending.deadline
    }
}

/// Counts each owner check the gate asks for: `text_confirm_approved` when it passes,
/// `text_confirm_denied` when it does not (plan §3.4). The gate asks only for a typed
/// affirmation that meets a live confirmation, so a stale one, the card's Cancel button and
/// the "can't verify" refusal count nothing.
public struct CountingTextAuthenticator: TextConfirmAuthenticator {
    private let inner: any TextConfirmAuthenticator
    private let research: any ResearchCounting

    public init(_ inner: any TextConfirmAuthenticator, research: any ResearchCounting) {
        self.inner = inner
        self.research = research
    }

    public func canAuthenticate() -> Bool {
        inner.canAuthenticate()
    }

    public func authenticate(reason: String) async -> Bool {
        let approved = await inner.authenticate(reason: reason)
        research.bump(approved ? TextConfirmation.approvedCounter : TextConfirmation.deniedCounter, by: 1)
        return approved
    }
}
