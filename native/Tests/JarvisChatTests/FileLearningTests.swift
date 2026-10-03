import Foundation
@testable import JarvisChat
import Testing

/// P6 part 5 (DEV-P6-06, proposed): the consent to learning from files. Off on a new install,
/// on where the file index already exists, kept in the app's defaults, mirrored for the
/// scanner, and the one-time first-run offer. Each test uses its own defaults suite.
@Suite("P6 learning from files needs consent")
@MainActor
struct FileLearningTests {
    static func defaults() throws -> (UserDefaults, String) {
        let name = "jarvis-tests-file-learning-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: name)), name)
    }

    @Test func aNewInstallStartsWithItOff() throws {
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = FileLearningConsent(defaults: defaults)
        #expect(!consent.isDecided)
        consent.resolve(filesIndexExists: false)
        #expect(consent.isDecided && !consent.isOn && !consent.shared.isOn)
        #expect(defaults.object(forKey: FileLearningConsent.defaultsKey) as? Bool == false)
    }

    /// An install whose scanner has run has consented: its scan carries on.
    @Test func anExistingFileIndexCountsAsConsent() throws {
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = FileLearningConsent(defaults: defaults)
        consent.resolve(filesIndexExists: true)
        #expect(consent.isOn && consent.shared.isOn)
        #expect(defaults.bool(forKey: FileLearningConsent.defaultsKey))
        // A relaunch reads it back.
        #expect(FileLearningConsent(defaults: defaults).isOn)
    }

    /// The user's own choice is never overridden, and switching writes it at once.
    @Test func theUsersChoiceStands() throws {
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = FileLearningConsent(defaults: defaults)
        consent.resolve(filesIndexExists: true)
        consent.isOn = false
        #expect(!consent.shared.isOn && defaults.object(forKey: FileLearningConsent.defaultsKey) as? Bool == false)
        let relaunched = FileLearningConsent(defaults: defaults)
        relaunched.resolve(filesIndexExists: true)
        #expect(!relaunched.isOn)
        relaunched.isOn = true
        #expect(relaunched.shared.isOn && defaults.bool(forKey: FileLearningConsent.defaultsKey))
    }

    /// Offered once, on a first launch (no memory folder), while it is off.
    @Test func theFirstRunOfferIsMadeOnce() throws {
        let (defaults, name) = try Self.defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = FileLearningConsent(defaults: defaults)
        consent.resolve(filesIndexExists: false)
        #expect(!consent.takeFirstRunOffer(memoryFolderExists: true))
        #expect(consent.takeFirstRunOffer(memoryFolderExists: false))
        #expect(!consent.takeFirstRunOffer(memoryFolderExists: false))
        let (other, otherName) = try Self.defaults()
        defer { other.removePersistentDomain(forName: otherName) }
        let on = FileLearningConsent(defaults: other)
        on.isOn = true
        #expect(!on.takeFirstRunOffer(memoryFolderExists: false))
    }

    @Test func theOfferIsOneAssistantRowNamingTheMenuItem() {
        #expect(FileLearningConsent.firstRunOffer.contains("Learn About Me From My Files"))
        #expect(FileLearningConsent.firstRunOffer.hasPrefix("Good day, sir."))
        #expect(FileLearningConsent.defaultsSuite == "com.jarv1s.assistant")
        #expect(FileLearningConsent.defaultsKey == "fileLearningEnabled")
        let chat = ChatViewModel()
        chat.post(FileLearningConsent.firstRunOffer)
        chat.post(FileLearningConsent.firstRunOffer)
        #expect(chat.messages.count == 1)
        #expect(chat.messages.first?.role == .assistant && chat.messages.first?.phase == .finished)
        #expect(chat.messages.first?.text == FileLearningConsent.firstRunOffer)
    }
}
