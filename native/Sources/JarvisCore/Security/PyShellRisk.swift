import Foundation

public enum PyShellRisk {
    public static let blockPatterns: [String] = [
        #"\brm\b.*\s(/|~)(\s|$)"#, #"\brm\b.*\s/(System|Library|usr|bin|sbin|etc|var|private)\b"#,
        #":\s*\(\s*\)\s*\{"#, #"\bmkfs\b"#, #"\bnewfs\b"#, #"diskutil\s+(erase|partition|reformat)"#,
        #"\bdd\b.*of=/dev/"#, #">\s*/dev/(r?disk|sd)"#, #"(curl|wget|fetch)\b.*\|\s*(ba|z)?sh"#,
        #"\$\(\s*(curl|wget)"#, #"base64\b.*\|\s*(ba|z)?sh"#, #"\bnc\b\s+-"#, #"\bncat\b"#,
        #"/dev/(tcp|udp)/"#, #"\b(csrutil|spctl|tccutil|softwareupdate\s+-i)\b"#, #"\blaunchctl\b"#,
        #"\b(dscl|sysadminctl)\b"#, #"\bvisudo\b"#, #"/etc/sudoers"#, #">\s*/(etc|System|usr|bin|sbin)/"#,
        #"\bsudo\s+(bash|sh|zsh|-i|su|-s)\b"#, #"chmod\s+-R\b.*\s(/|/System|/Library|/usr)"#,
        #"chown\s+-R\b.*\s(/|/System|/Library|/usr)"#, #"\bformat\s+[a-z]:"#, #"\bdel\s+/[sfq]"#,
        #"\b(rd|rmdir)\s+/s"#, #"\bvssadmin\b"#, #"\bbcdedit\b"#, #"\bdiskpart\b"#,
        #"\bcipher\s+/w"#, #"remove-item\b.*-recurse.*c:\\"#
    ]

    public static let confirmPatterns: [String] = [
        #"\brm\b"#, #"\brmdir\b"#, #"\bunlink\b"#, #"\bshred\b"#, #"\bsrm\b"#,
        #"\bkillall\b"#, #"\bpkill\b"#, #"\bkill\s+-9\b"#, #"\bshutdown\b"#, #"\breboot\b"#,
        #"\bhalt\b"#, #"\bdefaults\s+delete\b"#, #"\bchmod\b"#, #"\bchown\b"#,
        #"\bdel\b"#, #"\btaskkill\b"#, #"remove-item\b"#
    ]

    public static let sudoAllowPatterns: [String] = [
        #"^sudo\s+purge\b"#, #"^sudo\s+softwareupdate\s+(-l|--list)\b"#, #"^sudo\s+powermetrics\b"#,
        #"^sudo\s+diskutil\s+(list|info|verifyVolume)\b"#, #"^sudo\s+fdesetup\s+status\b"#,
        #"^sudo\s+log\s+show\b"#, #"^sudo\s+periodic\s+(daily|weekly|monthly)\b"#,
        #"^sudo\s+dscacheutil\s+-flushcache\b"#, #"^sudo\s+killall\s+-HUP\s+mDNSResponder\s*$"#,
        #"^sudo\s+mdutil\b"#, #"^sudo\s+pmset\b"#,
        #"^sudo\s+shutdown\s+-r\s+now\s*$"#, #"^sudo\s+shutdown\s+-h\s+now\s*$"#
    ]

    private static let block = try! PyRegex(blockPatterns.joined(separator: "|"), ignoreCase: true)
    private static let confirm = try! PyRegex(confirmPatterns.joined(separator: "|"), ignoreCase: true)
    private static let sudo = try! PyRegex(#"\bsudo\b"#, ignoreCase: false)
    private static let sudoAllow = try! PyRegex(sudoAllowPatterns.joined(separator: "|"), ignoreCase: true)

    public static func classify(_ cmd: String?) -> RiskTier {
        let command = (cmd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if block.search(command) != nil { return .block }
        if sudo.search(command) != nil { return sudoAllow.search(command) != nil ? .confirm : .block }
        if confirm.search(command) != nil { return .confirm }
        return .ok
    }

    public static func containsSudo(_ command: String) -> Bool {
        sudo.search(command) != nil
    }
}
