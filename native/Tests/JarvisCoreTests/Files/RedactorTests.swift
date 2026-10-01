import Foundation
import JarvisCore
import Testing

// D-51 P3, piece 3: what the Redactor masks before a model sees file text or, for the Claude
// stage, P2's transcript. Every key-shaped vector is assembled at run time, so no literal key
// shape sits in the source (the pre-commit hook would rightly refuse it).

private let mask = Redactor.mask

/// `count` characters cycling through letters and digits: the body of a fake key.
private func body(_ count: Int, _ alphabet: String = "aB3dE5gH7jK9mN2pQ4sT6vW8yZ") -> String {
    let chars = Array(alphabet)
    return String((0..<count).map { chars[$0 % chars.count] })
}

@Suite("Redactor (D-51 P3)")
struct RedactorTests {
    @Test func privateKeyBlocksGoWholeEvenWhenCut() {
        let armour = "-----" + "BEGIN"
        for kind in ["RSA PRIVATE KEY", "OPENSSH PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY",
                     "PGP PRIVATE KEY BLOCK"] {
            let block = "\(armour) \(kind)-----\n\(body(64))\n\(body(64))\n-----END \(kind)-----"
            let got = Redactor.redact("Server notes:\n\(block)\nRotate it yearly.", registry: SecretRegistry())
            #expect(got.text == "Server notes:\n\(mask)\nRotate it yearly.", "\(kind)")
            #expect(got.count == 1)
        }
        let cut = "Key below\n\(armour) RSA PRIVATE KEY-----\n\(body(64))\nshort tail"
        #expect(Redactor.redact(cut, registry: SecretRegistry()).text == "Key below\n\(mask)")
    }

    @Test func apiKeyAndTokenShapesAreMasked() {
        let shapes = [
            "sk-" + "ant-" + "api03-" + body(40), "sk-" + "proj-" + body(40), "sk-" + body(48),
            "gh" + "p_" + body(36), "gh" + "o_" + body(36), "github" + "_pat_" + body(60),
            "glpat-" + body(20), "xox" + "b-" + body(30), "AI" + "za" + body(35), "ya29." + body(40),
            "sk" + "_live_" + body(24), "rk" + "_test_" + body(24), "hf_" + body(34), "npm_" + body(36),
            "eyJ" + body(20) + ".eyJ" + body(30) + "." + body(43),
        ]
        for shape in shapes {
            let got = Redactor.redact("use \(shape) here", registry: SecretRegistry())
            #expect(got.text == "use \(mask) here", "\(shape.prefix(8))")
            #expect(got.count >= 1)
        }
        let bearer = Redactor.redact("curl -H 'Authorization: Bearer \(body(32))'", registry: SecretRegistry())
        #expect(!bearer.text.contains(body(32)))
    }

    @Test func awsStyleKeysAreMasked() {
        let keyID = "AK" + "IA" + "IOSFODNN7EXAMPLE"
        let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCY" + "EXAMPLEKEY"
        let got = Redactor.redact("id \(keyID)\nkey \(secret)\n", registry: SecretRegistry())
        #expect(got.text == "id \(mask)\nkey \(mask)\n")
        let pair = Redactor.redact("aws_secret_access_key = \(secret)", registry: SecretRegistry())
        #expect(pair.text == "aws_secret_access_key = \(mask)")
    }

    @Test(arguments: [
        ("password=hunter2", "password=\(mask)"),
        ("Password: correct horse battery staple", "Password: \(mask)"),
        ("secret: tell nobody", "secret: \(mask)"),
        ("DB_PASSWORD=pa55word!", "DB_PASSWORD=\(mask)"),
        (#"{"api_key": "abc123", "user": "sam"}"#, #"{"api_key": \#(mask), "user": "sam"}"#),
        ("client_secret='s3cr3t'", "client_secret=\(mask)"),
        ("https://example.com/cb?token=abc&next=1", "https://example.com/cb?token=\(mask)"),
        ("PIN: 4321", "PIN: \(mask)"),
        ("Wifi password:\n  tomato-soup-77\nRouter in the hall", "Wifi password:\n  \(mask)\nRouter in the hall"),
        ("My password is hunter2 for the bank", "My password is \(mask)"),
        ("The door pin was 1984.", "The door pin was \(mask)"),
        ("https://sam:hunter2@example.com/feed", "https://\(mask)@example.com/feed"),
    ])
    func passwordAndSecretPairsLoseTheirValue(_ input: String, _ expected: String) {
        #expect(Redactor.redact(input, registry: SecretRegistry()).text == expected)
    }

    @Test func longRandomStringsAreMasked() {
        let hex = String(repeating: "9f8e7d6c5b4a3928", count: 4)                        // a SHA-256 digest
        let uuid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        let base64 = "dGhlIHVzZXIgbG92ZXMgYmVlcw" + "9QmFzZTY0K2tleQ=="
        for value in [hex, uuid, base64, body(24)] {
            #expect(Redactor.redact("x \(value) y", registry: SecretRegistry()).text == "x \(mask) y",
                    "\(value.prefix(6))")
        }
    }

    @Test(arguments: [
        "Card 4111 1111 1111 1111 expires soon", "Card 4111-1111-1111-1111 expires soon",
        "Card 378282246310005 expires soon", "Card 123456789012 expires soon",
        "Card 12-34-56 12345678 expires soon",
    ])
    func cardLikeNumbersAndLongDigitRunsAreMasked(_ input: String) {
        #expect(Redactor.redact(input, registry: SecretRegistry()).text == "Card \(mask) expires soon")
    }

    @Test func ordinaryProseIsLeftAlone() {
        let prose = """
        The user grows tomatoes in Leeds and runs 5 km on Sundays.
        Born 1990-04-12; phone 07700 900123; flat 4B; internationalization notes.
        Kirin3DS is a 3DS emulator. Meeting at 10:30 on 2026-09-28.
        """
        let got = Redactor.redact(prose, registry: SecretRegistry())
        #expect(got.text == prose)
        #expect(got.count == 0)
    }

    @Test func registeredSecretsAreMaskedToo() {
        let registry = SecretRegistry()
        registry.register("plum-orchard-stairs")
        let got = Redactor.redact("the phrase plum-orchard-stairs opens it", registry: registry)
        #expect(got.text == "the phrase \(mask) opens it")
        #expect(got.count == 1)
    }

    @Test func factsHoldingTheMaskAreDroppedAsSecrets() {
        #expect(FactExtraction.dropReason("The user banks with \(mask).") == .secret)
        #expect(FactExtraction.dropReason("The user banks with a building society.") == nil)
    }
}
