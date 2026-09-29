import Foundation
import JarvisCore
import JarvisTestSupport
import Testing

/// Plan M02-M04 §3.11: `JarvisLog.log` replaces every value registered in
/// `SecretRegistry.shared` with ‹redacted› before a line is written. The sink is process-global;
/// no other test in this target writes to JarvisLog (drop-path loggers are injected), and the
/// sink is detached again before the sandbox goes, as in JarvisLogTests.
@Suite("M3 JarvisLog redaction", .serialized)
struct JarvisLogRedactionTests {
    @Test func registeredSecretsAreRedacted() throws {
        let s = try Sandbox()
        defer { s.remove() }
        let secret = "secret-\(UUID().uuidString)"
        SecretRegistry.shared.register(secret)
        JarvisLog.configure(file: s.paths.logFile, mirrorToStdout: false)
        defer { JarvisLog.configure(file: nil, mirrorToStdout: false) }
        JarvisLog.log("key=\(secret); again \(secret).", category: .security)
        JarvisLog.log("nothing to hide")
        let text = try s.read("logs/jarvis.log")
        #expect(text == "[JARVIS] key=‹redacted›; again ‹redacted›.\n[JARVIS] nothing to hide\n")
        #expect(!text.contains(secret))
    }
}
