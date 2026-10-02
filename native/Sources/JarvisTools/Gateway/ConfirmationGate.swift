import Foundation
import JarvisCore

public struct InputPort: Sendable {
    public let channel: Channel
    public let authenticator: (any ConfirmAuthenticator)?
    /// M9a part 6: what a spoken affirmation must pass on this port; nil on the unchecked voice
    /// port.
    public let voiceConfirmation: VoiceConfirmation?

    internal init(channel: Channel, authenticator: (any ConfirmAuthenticator)? = nil,
                  voiceConfirmation: VoiceConfirmation? = nil) {
        self.channel = channel
        self.authenticator = authenticator
        self.voiceConfirmation = voiceConfirmation
    }

    /// The unchecked voice port, for tests of the tools behind a confirmation. Every spoken turn
    /// goes through TurnCoordinator, whose voice port carries a `VoiceConfirmation`.
    public static var voice: InputPort { InputPort(channel: .voice) }

    /// The voice port a spoken turn confirms through (M9a part 6).
    public static func voice(confirming check: VoiceConfirmation) -> InputPort {
        InputPort(channel: .voice, voiceConfirmation: check)
    }

    public static func text(authenticator: any ConfirmAuthenticator) -> InputPort {
        InputPort(channel: .text, authenticator: authenticator)
    }
}

/// How a spoken affirmation proves it is the owner's (M9a part 6, D-41: native security wins over
/// Python's voiceprint-only gate, which passes anyone while no voiceprint is enrolled). This is
/// the one seam, and M10 leaves it unused on purpose: a spoken "yes" passes the owner check a
/// typed one passes, even with a voiceprint enrolled. A voice match is too weak to authorise an
/// action (in M10's tests a synthetic voice of another speaker scored 0.65 against the 0.60
/// bar), so there is no voiceprint route here.
public enum VoiceConfirmation: Sendable {
    /// Touch ID or the login password, the same check as a typed confirmation.
    case ownerCheck(any ConfirmAuthenticator)

    /// The reply when the check says no: nothing ran, and the card stays until its deadline.
    public static let notConfirmed = "Not confirmed, sir."

    /// True when the owner of the Mac approved `desc`.
    func approves(_ desc: String) async -> Bool {
        switch self {
        case .ownerCheck(let authenticator):
            await authenticator.authenticate(reason: desc)
        }
    }
}

public protocol ConfirmAuthenticator: Sendable {
    func authenticate(reason: String) async -> Bool
}

public struct PendingConfirmation: Sendable, Equatable {
    public let desc: String
    public let deadline: ContinuousClock.Instant
}

public enum ConsumeResult: Sendable, Equatable {
    case notHandled
    case handled(String)
}

public actor ConfirmationGate {
    public static let shared = ConfirmationGate()
    public static let timeout: Duration = .seconds(25)

    private struct PendingAction: Sendable {
        let publicValue: PendingConfirmation
        let action: @Sendable () async throws -> String
    }

    private var pendingAction: PendingAction?
    private let continuation: AsyncStream<PendingConfirmation?>.Continuation
    public nonisolated let updates: AsyncStream<PendingConfirmation?>

    public init() {
        let pair = AsyncStream<PendingConfirmation?>.makeStream()
        self.updates = pair.stream
        self.continuation = pair.continuation
    }

    public var pending: PendingConfirmation? { pendingAction?.publicValue }

    public func stash(desc: String, action: @escaping @Sendable () async throws -> String, turn: TurnContext) {
        let value = PendingConfirmation(desc: desc, deadline: ContinuousClock().now.advanced(by: Self.timeout))
        pendingAction = PendingAction(publicValue: value, action: action)
        continuation.yield(value)
    }

    public func consume(_ input: String, via port: InputPort, runIn turn: TurnContext) async -> ConsumeResult {
        guard let current = pendingAction else { return .notHandled }
        pendingAction = nil
        continuation.yield(nil)

        if ContinuousClock().now > current.publicValue.deadline {
            return .notHandled
        }
        guard Affirmation.matches(input) else {
            return .notHandled
        }
        if port.channel == .text {
            guard let authenticator = port.authenticator,
                  await authenticator.authenticate(reason: current.publicValue.desc) else {
                return .handled("Confirmation cancelled, sir.")
            }
        } else if let check = port.voiceConfirmation {
            guard await check.approves(current.publicValue.desc) else {
                // M9a part 6: not confirmed, and the card comes back until its deadline, unless
                // another confirmation took the slot while the check was up.
                if pendingAction == nil, ContinuousClock().now <= current.publicValue.deadline {
                    pendingAction = current
                    continuation.yield(current.publicValue)
                }
                return .handled(VoiceConfirmation.notConfirmed)
            }
        }
        do {
            return .handled(try await current.action())
        } catch {
            return .handled(GuardStrings.confirmFailed(String(describing: error)))
        }
    }
}
