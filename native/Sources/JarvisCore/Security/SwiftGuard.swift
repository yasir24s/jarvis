import Foundation

/// Public M2 façade for callers that do not need to know the individual policy types.
public enum SwiftGuard {
    public static func shellRisk(_ command: String?) -> RiskTier {
        PyShellRisk.classify(command)
    }

    public static func shellVerdict(_ command: String, sudo: SudoAllowlist = .python) -> ShellVerdict {
        // M2's public/default contract is Python parity. Native hardening is retained in
        // ShellPolicy.strictVerdict for the later gated milestone.
        ShellPolicy.verdict(command, sudo: sudo)
    }

    public static func dangerousAppleScript(_ script: String?) -> Bool {
        AppleScriptPolicy.isDangerous(script)
    }

    public static func escapeAppleScript(_ value: String?) -> String {
        AppleScriptPolicy.escape(value)
    }

    public static func isSystemPath(_ path: String, home: String, cwd: String) -> Bool {
        PathPolicy.isSystemPath(path, home: home, cwd: cwd)
    }

    public static func inHome(_ path: String, home: String, cwd: String) -> Bool {
        PathPolicy.inHome(path, home: home, cwd: cwd)
    }
}
