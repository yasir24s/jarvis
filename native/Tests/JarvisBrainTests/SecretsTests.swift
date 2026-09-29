import Foundation
import JarvisBrain
import JarvisCore
import Testing

/// SecretRegistry (plan M02-M04 §3.11) on private instances, and SecretStore's not-found path
/// only: a random service name, so the real com.jarvis.assistant item is never read, and
/// nothing ever writes the keychain.
@Suite("M3 secrets: registry and keychain store")
struct SecretsTests {
    @Test func registryContainsAndRedacts() {
        let r = SecretRegistry()
        #expect(!r.contains("anything") && r.redact("anything") == "anything")
        r.register("")
        #expect(!r.contains("anything"), "the empty string is never registered")
        r.register("abc123")
        r.register("abc123")
        #expect(r.contains("abc123") && r.contains("x-abc123-y"))
        #expect(!r.contains("abc12") && !r.contains("ABC123"))
        #expect(r.redact("abc123 and abc123.") == "\(SecretRegistry.mask) and \(SecretRegistry.mask).")
    }

    @Test func longerSecretsAreRedactedWhole() {
        let r = SecretRegistry()
        r.register("key")
        r.register("key-with-suffix")
        #expect(r.redact("[key-with-suffix] [key]") == "[\(SecretRegistry.mask)] [\(SecretRegistry.mask)]")
    }

    @Test func matchingIsLiteral() {
        let r = SecretRegistry()
        r.register("caf\u{E9}")                           // precomposed é
        #expect(!r.contains("cafe\u{301}"))               // decomposed: canonically equal, not literally
        #expect(r.redact("cafe\u{301}") == "cafe\u{301}")
        #expect(r.contains("un caf\u{E9}"))
    }

    @Test func concurrentRegistration() async {
        let r = SecretRegistry()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<64 {
                group.addTask { r.register("secret-\(i)-\(UUID().uuidString)") }
                group.addTask { _ = r.redact("no secret here \(i)") }
            }
        }
        r.register("final-secret")
        #expect(r.contains("x final-secret y"))
        #expect(r.redact("final-secret") == SecretRegistry.mask)
    }

    @Test func storeReturnsNilForAMissingItem() {
        #expect(SecretStore.service == "com.jarvis.assistant")
        #expect(SecretStore.read(service: "jarvis-test-\(UUID().uuidString)", account: "elevenlabs") == nil)
    }
}
