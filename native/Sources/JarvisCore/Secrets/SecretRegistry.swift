import Foundation
import Synchronization

/// Values that must never reach a log, a child environment or argv (plan: M02-M04 §3.11):
/// the ElevenLabs key once read, and any other secret. `JarvisLog.log` replaces every
/// registered value with `‹redacted›`; `ChildEnvironment` drops any variable holding one.
/// Thread-safe. Values are matched literally (UTF-16 code units, no canonical equivalence).
public final class SecretRegistry: Sendable {
    /// The process-wide registry `JarvisLog` redacts with.
    public static let shared = SecretRegistry()
    public static let mask = "‹redacted›"

    /// Longest first, so a value that contains another is replaced whole.
    private let values = Mutex<[String]>([])

    public init() {}

    /// Adds `secret`. The empty string is ignored: it would match everywhere.
    public func register(_ secret: String) {
        guard !secret.isEmpty else { return }
        values.withLock { v in
            guard !v.contains(where: { Py.eq($0, secret) }) else { return }
            v.append(secret)
            v.sort { $0.utf16.count > $1.utf16.count }
        }
    }

    /// True when `text` holds any registered value, whole or as a substring.
    public func contains(_ text: String) -> Bool {
        let v = values.withLock { $0 }
        return v.contains { text.range(of: $0, options: .literal) != nil }
    }

    /// `text` with every occurrence of every registered value replaced by `mask`.
    public func redact(_ text: String) -> String {
        let v = values.withLock { $0 }
        var out = text
        for secret in v where out.range(of: secret, options: .literal) != nil {
            out = out.replacingOccurrences(of: secret, with: Self.mask, options: .literal)
        }
        return out
    }
}
