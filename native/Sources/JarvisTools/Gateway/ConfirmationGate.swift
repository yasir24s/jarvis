import Foundation
import JarvisCore

public struct InputPort: Sendable {
    public let channel: Channel
    public let authenticator: (any ConfirmAuthenticator)?

    internal init(channel: Channel, authenticator: (any ConfirmAuthenticator)? = nil) {
        self.channel = channel
        self.authenticator = authenticator
    }

    /// Test and voice-loop construction point. Text UI code should use the coordinator's
    /// authenticated port instead of manufacturing one from model input.
    public static var voice: InputPort { InputPort(channel: .voice) }

    public static func text(authenticator: any ConfirmAuthenticator) -> InputPort {
        InputPort(channel: .text, authenticator: authenticator)
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
        }
        do {
            return .handled(try await current.action())
        } catch {
            return .handled(GuardStrings.confirmFailed(String(describing: error)))
        }
    }
}
