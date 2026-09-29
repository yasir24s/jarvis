import Foundation

public struct ShellVerdict: Sendable {
    public let tier: RiskTier
    public let pythonTier: RiskTier
    public let reasons: [String]
    public let isSudo: Bool

    public init(tier: RiskTier, pythonTier: RiskTier, reasons: [String], isSudo: Bool) {
        self.tier = tier
        self.pythonTier = pythonTier
        self.reasons = reasons
        self.isSudo = isSudo
    }
}

public enum ShellPolicy {
    private static let sudo = try! PyRegex(#"\bsudo\b"#, ignoreCase: false)
    private static let keychain = try! PyRegex(#"\bsecurity\s+(find-generic-password|find-internet-password|dump-keychain|export)\b"#, ignoreCase: true)

    public static func verdict(_ cmd: String, sudo allowlist: SudoAllowlist = .python) -> ShellVerdict {
        let pythonTier = PyShellRisk.classify(cmd)
        var tier = pythonTier
        var reasons: [String] = pythonTier == .ok ? [] : ["python:\(pythonTier.rawValue)"]
        let isSudo = PyShellRisk.containsSudo(cmd)

        switch ShellSegmenter.segments(cmd) {
        case .failure(let error):
            tier = max(tier, .block)
            reasons.append("parse:\(String(describing: error))")
        case .success(let segments):
            for segment in segments {
                let segmentTier = PyShellRisk.classify(segment.text)
                if segmentTier > tier { tier = segmentTier }
                if segmentTier != .ok { reasons.append("segment:\(segmentTier.rawValue)") }
                if sudo.search(segment.text) != nil && !allowlist.allows(segment.text) {
                    tier = .block
                    reasons.append("sudo-not-allowlisted")
                }
                if keychain.search(segment.text) != nil {
                    tier = .block
                    reasons.append("keychain-secret")
                }
            }
        }
        return ShellVerdict(tier: tier, pythonTier: pythonTier, reasons: reasons, isSudo: isSudo)
    }
}
