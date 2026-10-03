import Foundation
import Testing

/// The Developer ID move: scripts/sign-app.sh signs the staged bundle. It runs here only on a
/// fake bundle in a temp folder, with stand-ins for codesign and security that record their
/// arguments: no keychain is read, unlocked or searched, and nothing is really signed.
@Suite("sign-app.sh", .timeLimit(.minutes(2)))
struct SignAppScriptTests {
    static let script = AppShellTests.native.appending(path: "scripts/sign-app.sh")
    static let team = "ABCDE12345"
    static let hash = String(repeating: "C", count: 40)
    static let identityName = "Developer ID Application: Test Signer (\(team))"
    static let goodDR = "designated => identifier \"com.jarv1s.assistant\" and anchor apple generic and "
        + "certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and "
        + "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \(team)"

    /// A staged bundle, a signing folder and the two stand-ins, in one throwaway folder.
    struct Fake {
        let root: URL
        var stage: URL { root.appending(path: "JARVIS.app", directoryHint: .isDirectory) }
        var signing: URL { root.appending(path: "signing", directoryHint: .isDirectory) }
        var calls: URL { root.appending(path: "calls") }

        init(bundleID: String = "com.jarv1s.assistant") throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "jarvis-tests-sign-\(UUID().uuidString)", directoryHint: .isDirectory)
            let fm = FileManager.default
            for dir in ["JARVIS.app/Contents/Frameworks", "JARVIS.app/Contents/Helpers/a.bundle",
                        "JARVIS.app/Contents/Helpers/qwen/b.bundle", "JARVIS.app/Contents/MacOS", "signing"] {
                try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
            }
            for file in ["Frameworks/libx.dylib", "Helpers/jarvis-voice", "Helpers/qwen/jarvis-voice-qwen",
                         "Helpers/jarvis-update", "MacOS/JARVIS"] {
                try Data().write(to: stage.appending(path: "Contents/\(file)"))
            }
            try plist(["CFBundleIdentifier": bundleID], to: stage.appending(path: "Contents/Info.plist"))
            try write("signing/config", "DEVELOPER_ID_TEAM=\(SignAppScriptTests.team)\nKEYCHAIN=/nonexistent/test.keychain-db\n"
                      + "KEYCHAIN_PASSWORD=not-a-password\nIDENTITY=legacy-test-identity\n")
            try profile()
            try write("identities", """
                  1) \(String(repeating: "A", count: 40)) "Apple Development: Test Signer (\(SignAppScriptTests.team))"
                  2) \(String(repeating: "B", count: 40)) "Developer ID Application: Someone Else (QQQQQQQQQQ)"
                  3) \(SignAppScriptTests.hash) "\(SignAppScriptTests.identityName)"
                     3 valid identities found

                """)
            try write("dr", SignAppScriptTests.goodDR + "\n")
            let r = root.path(percentEncoded: false)
            try executable("codesign", """
                #!/bin/bash
                echo "codesign $*" >> "\(r)calls"
                prev=""
                for a in "$@"; do
                    if [[ "$prev" == --entitlements ]]; then cp "$a" "\(r)entitlements.plist"; fi
                    prev="$a"
                done
                echo "signing as \(SignAppScriptTests.identityName)" >&2
                if [[ "$1" == -d ]]; then echo "Executable=x" >&2; cat "\(r)dr"; fi
                exit 0

                """)
            try executable("security", """
                #!/bin/bash
                echo "security $1" >> "\(r)calls"
                case "$1" in
                    find-identity) cat "\(r)identities" ;;
                    cms) cat "$4" ;;
                esac
                exit 0

                """)
        }

        /// The profile, as a plain plist (the stand-in's `cms -D` prints it as it is).
        func profile(appID: String = "\(SignAppScriptTests.team).com.jarv1s.assistant", timeSensitive: Bool = true) throws {
            var entitlements: [String: Any] = ["com.apple.application-identifier": appID,
                                               "com.apple.developer.team-identifier": SignAppScriptTests.team,
                                               "com.apple.developer.weatherkit": true]
            if timeSensitive { entitlements["com.apple.developer.usernotifications.time-sensitive"] = true }
            try plist(["Name": "JARVIS Developer ID", "TeamIdentifier": [SignAppScriptTests.team], "Entitlements": entitlements],
                      to: signing.appending(path: "JARVIS_Developer_ID.provisionprofile"))
        }

        func write(_ relative: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appending(path: relative))
        }

        func plist(_ object: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0).write(to: url)
        }

        func executable(_ name: String, _ text: String) throws {
            try write(name, text)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: root.appending(path: name).path(percentEncoded: false))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func run(_ flags: [String] = []) throws -> (status: Int32, output: String) {
            let environment = ["SIGN_APP_CODESIGN": root.appending(path: "codesign").path(percentEncoded: false),
                               "SIGN_APP_SECURITY": root.appending(path: "security").path(percentEncoded: false)]
            return try SwitchImplScriptTests.run(flags + [stage.path(percentEncoded: false), signing.path(percentEncoded: false)],
                                                 environment: environment, in: root, script: SignAppScriptTests.script)
        }

        var recorded: [String] {
            ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }

        func dictionary(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        }

        var info: [String: Any] { dictionary(stage.appending(path: "Contents/Info.plist")) ?? [:] }
        var embedded: URL { stage.appending(path: "Contents/embedded.provisionprofile") }
        var appSigned: Bool { recorded.contains { $0.contains("--entitlements") } }
    }

    @Test func theDeveloperIDPathEmbedsTheProfileSetsTheFlagAndSignsInsideOut() throws {
        let fake = try Fake()
        defer { fake.remove() }
        let result = try fake.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("DR names com.jarv1s.assistant and the team's Developer ID: yes"))
        // The profile is embedded, and the flag that turns identify_song on is set.
        #expect(FileManager.default.contentsEqual(atPath: fake.embedded.path(percentEncoded: false),
            andPath: fake.signing.appending(path: "JARVIS_Developer_ID.provisionprofile").path(percentEncoded: false)))
        #expect(fake.info["JARVISShazamKit"] as? Bool == true)
        // The entitlements: the three of JARVIS.entitlements, and the three from the team ID.
        let entitlements = try #require(fake.dictionary(fake.root.appending(path: "entitlements.plist")))
        #expect(entitlements["com.apple.application-identifier"] as? String == "\(Self.team).com.jarv1s.assistant")
        #expect(entitlements["com.apple.developer.team-identifier"] as? String == Self.team)
        #expect(entitlements["com.apple.developer.usernotifications.time-sensitive"] as? Bool == true)
        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == false)
        #expect(entitlements["com.apple.security.device.audio-input"] as? Bool == true)
        #expect(entitlements["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(entitlements.count == 6)
        // The login keychain's identity, by hash: no custom keychain, no unlock, no runtime.
        let signs = fake.recorded.filter { $0.hasPrefix("codesign --force") }
        #expect(signs.count == 7)
        #expect(signs.allSatisfy { $0.hasPrefix("codesign --force --sign \(Self.hash) ") })
        #expect(!fake.recorded.contains { $0.contains("--keychain") || $0.contains("--options") || $0.contains("--deep") })
        #expect(!fake.recorded.contains("security unlock-keychain"))
        // Inner first: frameworks, helpers, the update helper, then the app last.
        let order = signs.map { String($0.split(separator: "/").last ?? "") }
        #expect(order == ["libx.dylib", "a.bundle", "jarvis-voice", "b.bundle", "jarvis-voice-qwen", "jarvis-update",
                          "JARVIS.app"])
        // Neither the identity's name nor its hash reaches the terminal.
        #expect(!result.output.contains(Self.identityName) && !result.output.contains(Self.hash))
        #expect(!result.output.contains("designated =>"))
    }

    @Test func anIdentityInConfigIsUsedWithoutSearching() throws {
        let fake = try Fake()
        defer { fake.remove() }
        try fake.write("signing/config", "DEVELOPER_ID_TEAM=\(Self.team)\nDEVELOPER_ID_IDENTITY=\"\(Self.identityName)\"\n")
        let result = try fake.run()
        #expect(result.status == 0, "\(result.output)")
        #expect(!fake.recorded.contains("security find-identity"))
        #expect(fake.recorded.filter { $0.hasPrefix("codesign --force") }
            .allSatisfy { $0.hasPrefix("codesign --force --sign \(Self.identityName) ") })
    }

    @Test func noProfileMeansNoBuildAndNoFlag() throws {
        let fake = try Fake()
        defer { fake.remove() }
        try FileManager.default.removeItem(at: fake.signing.appending(path: "JARVIS_Developer_ID.provisionprofile"))
        let result = try fake.run()
        #expect(result.status != 0)
        #expect(result.output.contains("JARVIS_Developer_ID.provisionprofile missing"))
        #expect(fake.info["JARVISShazamKit"] == nil)
        #expect(!FileManager.default.fileExists(atPath: fake.embedded.path(percentEncoded: false)))
        #expect(!fake.recorded.contains { $0.hasPrefix("codesign") })
    }

    @Test func aProfileForAnotherAppOrWithoutTimeSensitiveIsRefused() throws {
        for (appID, timeSensitive, message) in [("\(Self.team).com.jarvis.assistant", true, "is not for com.jarv1s.assistant"),
                                                ("\(Self.team).com.jarv1s.assistant", false, "time-sensitive")] {
            let fake = try Fake()
            defer { fake.remove() }
            try fake.profile(appID: appID, timeSensitive: timeSensitive)
            let result = try fake.run()
            #expect(result.status != 0)
            #expect(result.output.contains(message), "\(result.output)")
            #expect(fake.info["JARVISShazamKit"] == nil)
            #expect(!fake.recorded.contains { $0.hasPrefix("codesign") })
        }
    }

    @Test func aMissingTeamOrNoMatchingIdentityIsRefused() throws {
        let noTeam = try Fake()
        defer { noTeam.remove() }
        try noTeam.write("signing/config", "IDENTITY=legacy-test-identity\n")
        let first = try noTeam.run()
        #expect(first.status != 0 && first.output.contains("DEVELOPER_ID_TEAM"))

        let noIdentity = try Fake()
        defer { noIdentity.remove() }
        try noIdentity.write("identities", "     0 valid identities found\n")
        let second = try noIdentity.run()
        #expect(second.status != 0 && second.output.contains("found 0"))
        #expect(!noIdentity.recorded.contains { $0.hasPrefix("codesign") })
    }

    @Test func aStagedBundleUnderAnotherIDIsRefused() throws {
        let fake = try Fake(bundleID: "com.jarvis.assistant")
        defer { fake.remove() }
        let result = try fake.run()
        #expect(result.status != 0 && result.output.contains("is not com.jarv1s.assistant"))
        #expect(fake.recorded.isEmpty)
    }

    @Test func aDesignatedRequirementThatIsNotTheTeamsDeveloperIDFails() throws {
        let otherTeam = Self.goodDR.replacingOccurrences(of: "subject.OU] = \(Self.team)", with: "subject.OU] = QQQQQQQQQQ")
        let notDeveloperID = Self.goodDR.replacingOccurrences(of: "certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and ", with: "")
        let otherApp = Self.goodDR.replacingOccurrences(of: "com.jarv1s.assistant", with: "com.jarvis.assistant")
        for dr in [otherTeam, notDeveloperID, otherApp] {
            let fake = try Fake()
            defer { fake.remove() }
            try fake.write("dr", dr + "\n")
            let result = try fake.run()
            #expect(result.status != 0)
            #expect(result.output.contains(": no"))
        }
    }

    @Test func theLegacyIdentityPathUnlocksItsKeychainAndAddsNoProfile() throws {
        let fake = try Fake()
        defer { fake.remove() }
        try fake.write("dr", "designated => identifier \"com.jarv1s.assistant\" and certificate leaf = H\"0123\"\n")
        let result = try fake.run(["--legacy-identity"])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("DR names com.jarv1s.assistant: yes (legacy"))
        #expect(fake.recorded.contains("security unlock-keychain"))
        #expect(!fake.recorded.contains("security find-identity"))
        #expect(fake.recorded.filter { $0.hasPrefix("codesign --force") }
            .allSatisfy { $0.hasPrefix("codesign --force --sign legacy-test-identity --keychain /nonexistent/test.keychain-db ") })
        #expect(fake.info["JARVISShazamKit"] == nil)
        #expect(!FileManager.default.fileExists(atPath: fake.embedded.path(percentEncoded: false)))
        let entitlements = try #require(fake.dictionary(fake.root.appending(path: "entitlements.plist")))
        #expect(entitlements["com.apple.application-identifier"] == nil)
        #expect(!result.output.contains("not-a-password"))
    }
}
