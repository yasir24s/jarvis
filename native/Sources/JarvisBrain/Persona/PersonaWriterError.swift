import Foundation
import JarvisCore

/// Why a persona writer produced no text. CoreState logs the description, so it names the
/// cause only: never a prompt, a reply, or anything from the personality file.
public enum PersonaWriterError: Error, Equatable, CustomStringConvertible {
    /// The on-device model cannot run: its availability reason.
    case localUnavailable(String)
    /// The on-device generation failed or ran past its timeout.
    case localFailed(String)
    /// `JARVIS_USE_CLAUDE=0`.
    case claudeOff
    /// Offline, so Claude is not tried (as a turn does not try it).
    case offline
    /// The Claude call failed. A short reason with no model output in it.
    case claudeFailed(String)
    /// Neither writer produced text.
    case bothFailed(local: String, claude: String)

    public var description: String {
        switch self {
        case .localUnavailable(let reason): "on-device model unavailable (\(reason))"
        case .localFailed(let reason): "on-device model failed (\(reason))"
        case .claudeOff: "Claude is off"
        case .offline: "offline"
        case .claudeFailed(let reason): "Claude failed (\(reason))"
        case let .bothFailed(local, claude): "no writer: \(local); \(claude)"
        }
    }

    /// What a writer's failure is logged as: a PersonaWriterError's description, otherwise the
    /// error's type and, for an enum, its case name. Never a payload, which for a model error
    /// can quote the prompt.
    static func reason(_ error: any Error) -> String {
        if let error = error as? PersonaWriterError { return error.description }
        if error is CancellationError { return "cancelled" }
        let mirror = Mirror(reflecting: error)
        let type = String(describing: Swift.type(of: error))
        guard mirror.displayStyle == .enum, let label = mirror.children.first?.label else { return type }
        return "\(type).\(label)"
    }
}
