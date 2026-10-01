import Foundation

/// Removes what looks like a secret from text before a model sees it (D-51 P3): every file's
/// text before either model, and P2's conversation transcript before the Claude stage. Each
/// match becomes `SecretRegistry.mask`. Over-redaction is the safe direction: a masked number
/// costs a fact at most, a leaked key costs the key. Text is never logged; callers log counts.
public enum Redactor {
    public static let mask = SecretRegistry.mask

    private struct Rule: Sendable {
        let regex: NSRegularExpression
        let template: String
    }

    /// Applied in order: a private key block first, since its body would otherwise be
    /// masked line by line and its armour left behind.
    private static let rules: [Rule] = [
        // PEM, OpenSSH and PGP private keys, to the END line or, when the text was cut, the end
        rule(#"-----BEGIN[ A-Z0-9]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END[ A-Z0-9]*PRIVATE KEY(?: BLOCK)?-----|\z)"#),
        // user:password@ in a URL
        rule(#"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"#),
        // API key and token shapes
        rule(#"\bsk-ant-[A-Za-z0-9_-]{8,}|\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}"#
             + #"|\bgh[pousr]_[A-Za-z0-9]{20,}|\bgithub_pat_[A-Za-z0-9_]{20,}|\bglpat-[A-Za-z0-9_-]{20,}"#
             + #"|\bxox[abprs]-[A-Za-z0-9-]{10,}|\bAIza[0-9A-Za-z_-]{30,}|\bya29\.[0-9A-Za-z_-]{20,}"#
             + #"|\b[rsp]k_(?:live|test)_[0-9A-Za-z]{16,}|\bhf_[A-Za-z0-9]{30,}|\bnpm_[A-Za-z0-9]{30,}"#
             + #"|\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
        rule(#"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}"#, template: "$1 " + mask),
        // AWS access key IDs (the secret key is caught as a long random string, or as a pair)
        rule(#"\b(?:AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AIPA|ANPA|ANVA|APKA|AROA)[0-9A-Z]{16}\b"#),
        // password=…, secret: …, "api_key": "…" — the name stays, the value (quoted, or to the
        // end of the line, or on the next line) goes
        rule(#"(?i)(\b[A-Za-z0-9_.-]*(?:password|passwd|passphrase|passcode|secret|token|api[_-]?key"#
             + #"|access[_-]?key|private[_-]?key|credentials?|authorization)[A-Za-z0-9_.-]*\b"#
             + #"|\b(?:pwd|pin|otp|pass)\b)(["']?[ \t]*[:=][ \t]*(?:\r?\n[ \t]*)?)"#
             + #"("[^"\n]*"|'[^'\n]*'|[^\s"'][^\n]*)"#, template: "$1$2" + mask),
        rule(#"(?i)\b(password|passcode|passphrase|pin|secret)(\s+(?:is|was)\s+)\S[^\n]*"#,
             template: "$1$2" + mask),
        // 20+ key-like characters holding a letter and a digit (as P2's validator), so hex and
        // base64 keys, AWS secret keys, UUIDs and hashes
        rule(#"(?<![A-Za-z0-9_+/=-])(?=[A-Za-z0-9_+/=-]*[A-Za-z])(?=[A-Za-z0-9_+/=-]*[0-9])[A-Za-z0-9_+/=-]{20,}"#),
        // card-like numbers and long digit runs: 12 or more digits, single spaces or dashes allowed
        rule(#"(?<![0-9])(?:[0-9][ -]?){11,}[0-9](?![0-9])"#),
    ]

    /// `text` with every secret shape masked, and how many matches were masked. Values held
    /// in `registry` (keys JARVIS has read) are masked first.
    public static func redact(_ text: String, registry: SecretRegistry = .shared) -> (text: String, count: Int) {
        var out = registry.redact(text)
        var count = out == text ? 0 : 1
        for rule in rules {
            let range = NSRange(out.startIndex..., in: out)
            let found = rule.regex.numberOfMatches(in: out, range: range)
            guard found > 0 else { continue }
            count += found
            out = rule.regex.stringByReplacingMatches(in: out, range: range, withTemplate: rule.template)
        }
        return (out, count)
    }

    /// Just the redacted text: the Claude stage's input hook for P2's transcript.
    @Sendable public static func redacted(_ text: String) -> String {
        redact(text).text
    }

    private static func rule(_ pattern: String, template: String = mask) -> Rule {
        Rule(regex: try! NSRegularExpression(pattern: pattern), template: template)
    }
}
