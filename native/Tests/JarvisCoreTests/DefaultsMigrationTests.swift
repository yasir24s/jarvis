import Foundation
import JarvisCore
import Testing

/// The settings' copy from the old bundle ID's defaults domain to the new one, against two fake
/// suites with random names: the real domains are never read or written.
@Suite("DefaultsMigration")
struct DefaultsMigrationTests {
    struct Domains {
        let legacy = "jarvis.test.migration.\(UUID().uuidString).old"
        let current = "jarvis.test.migration.\(UUID().uuidString).new"
        let defaults = UserDefaults.standard

        func clear() {
            defaults.removePersistentDomain(forName: legacy)
            defaults.removePersistentDomain(forName: current)
        }
    }

    @Test func copiesEveryKeyOnceAndSetsTheMarker() throws {
        let d = Domains(); defer { d.clear() }
        d.defaults.setPersistentDomain(["speakEarly": true, "hudEnabled": false, "voiceSpeed": 1.1,
                                        "brain": "chatgpt"], forName: d.legacy)
        let copied = DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults)
        #expect(copied == 4)
        let new = try #require(UserDefaults(suiteName: d.current))
        #expect(new.bool(forKey: "speakEarly") == true)
        #expect(new.object(forKey: "hudEnabled") as? Bool == false)
        #expect(new.double(forKey: "voiceSpeed") == 1.1)
        #expect(new.string(forKey: "brain") == "chatgpt")
        #expect(new.bool(forKey: DefaultsMigration.markerKey))
    }

    @Test func neverChangesOrRemovesTheOldDomain() {
        let d = Domains(); defer { d.clear() }
        let old: [String: Any] = ["speakEarly": true, "brain": "claude"]
        d.defaults.setPersistentDomain(old, forName: d.legacy)
        DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults)
        let after = d.defaults.persistentDomain(forName: d.legacy) ?? [:]
        #expect(after.count == 2)
        #expect(after["speakEarly"] as? Bool == true)
        #expect(after["brain"] as? String == "claude")
        #expect(after[DefaultsMigration.markerKey] == nil)
    }

    @Test func runsOnlyOnceTheMarkerIsSet() throws {
        let d = Domains(); defer { d.clear() }
        d.defaults.setPersistentDomain(["brain": "claude"], forName: d.legacy)
        #expect(DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults) == 1)
        // The user changes the setting under the new ID, and the old domain changes too (the
        // rollback build ran): a second launch copies nothing over the user's choice.
        let new = try #require(UserDefaults(suiteName: d.current))
        new.set("chatgpt", forKey: "brain")
        d.defaults.setPersistentDomain(["brain": "claude", "speakEarly": true], forName: d.legacy)
        #expect(DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults) == nil)
        #expect(new.string(forKey: "brain") == "chatgpt")
        #expect(new.object(forKey: "speakEarly") == nil)
    }

    @Test func keepsAKeyTheNewDomainAlreadyHolds() throws {
        let d = Domains(); defer { d.clear() }
        d.defaults.setPersistentDomain(["brain": "claude", "speakEarly": true], forName: d.legacy)
        d.defaults.setPersistentDomain(["brain": "chatgpt"], forName: d.current)
        #expect(DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults) == 1)
        let new = try #require(UserDefaults(suiteName: d.current))
        #expect(new.string(forKey: "brain") == "chatgpt")
        #expect(new.bool(forKey: "speakEarly") == true)
    }

    @Test func anEmptyOldDomainStillSetsTheMarker() throws {
        let d = Domains(); defer { d.clear() }
        #expect(DefaultsMigration.run(from: d.legacy, to: d.current, defaults: d.defaults) == 0)
        let new = try #require(UserDefaults(suiteName: d.current))
        #expect(new.bool(forKey: DefaultsMigration.markerKey))
    }

    @Test func launchCallDoesNothingOutsideTheAppBundle() {
        // Under `swift test` the main bundle is the test runner, never com.jarv1s.assistant.
        #expect(Bundle.main.bundleIdentifier != AppIdentity.bundleID)
        #expect(DefaultsMigration.runAtLaunch() == nil)
    }
}
