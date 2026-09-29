import Foundation

public enum RiskTier: String, Comparable, Sendable {
    case ok
    case confirm
    case block

    private var rank: Int {
        switch self {
        case .ok: 0
        case .confirm: 1
        case .block: 2
        }
    }

    public static func < (lhs: RiskTier, rhs: RiskTier) -> Bool {
        lhs.rank < rhs.rank
    }
}
