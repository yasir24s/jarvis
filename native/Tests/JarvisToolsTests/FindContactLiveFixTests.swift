import Foundation
import JarvisCore
@testable import JarvisTools
import Testing

/// A fake address book with the user's own card's relations.
struct FakeRelatedContacts: ContactsReading {
    let list: [ContactCard]
    let relations: [ContactRelation]?
    func cards() async -> [ContactCard]? { list }
    func myRelations() async -> [ContactRelation]? { relations }
}

/// Live fix 3: "Find Mum" reached the on-device brain, which answered "Your query is vague"
/// with no tool call. The fast path now sends "find/call <person>" and "<person>'s number" to
/// find_contact (DEV-LIVE-03), which reads relationship words through the user's own card and
/// matches nicknames.
@Suite("find_contact for people and relations (live fix 3)")
struct FindContactLiveFixTests {
    static let book = [
        ContactCard(name: "Kareena's Mum", phones: ["+44 7700 900111"], emails: []),
        ContactCard(name: "Jane Doe", phones: ["+44 7700 900333"], emails: ["jane@example.com"]),
        ContactCard(name: "Robert Smith", phones: ["020 7946 0000"], emails: [], nickname: "Bobby"),
    ]
    static let relations = [
        ContactRelation(label: "_$!<Mother>!$_", name: "Jane Doe"),
        ContactRelation(label: "Bro", name: "Robert Smith"),
        ContactRelation(label: "_$!<Father>!$_", name: "Alan Doe"),       // no card of his own
    ]

    static func lookup(relations: [ContactRelation]? = relations) -> ContactLookup {
        ContactLookup(contacts: FakeRelatedContacts(list: book, relations: relations),
                      scripts: AppleScriptRunner(runner: ScriptedRunner([])))
    }

    @Test func relationWordsGoThroughTheUsersOwnCard() async {
        let lookup = Self.lookup()
        for word in ["mum", "Mom", "mother", "my mum"] {
            #expect(await lookup.describe(word) == "Jane Doe, phone +44 7700 900333, email jane@example.com", "\(word)")
        }
        #expect(await lookup.describe("brother") == "Robert Smith, phone 020 7946 0000")   // a label the user typed
        #expect(await lookup.describe("dad") == "Alan Doe")
        #expect(await lookup.describe("sister") == nil)
    }

    @Test func aRelationIsNotMistakenForANameThatContainsIt() async {
        // Python's contains-match would take "Kareena's Mum" for "mum"; the user's card wins.
        #expect(await Self.lookup().describe("mum")?.hasPrefix("Jane Doe") == true)
        // With no "me" card the old order stands.
        #expect(await Self.lookup(relations: nil).describe("mum")?.hasPrefix("Kareena's Mum") == true)
    }

    @Test func nicknamesMatch() async {
        #expect(await Self.lookup().describe("bobby") == "Robert Smith, phone 020 7946 0000")
        #expect(await Self.lookup().describe("Jane Doe")?.hasPrefix("Jane Doe") == true)   // names as before
    }

    @Test func relationLabels() {
        #expect(PersonWords.relation(label: "_$!<Mother>!$_") == "mother")
        #expect(PersonWords.relation(label: "Mum") == "mother")
        #expect(PersonWords.relation(label: "_$!<Partner>!$_") == "spouse")
        #expect(PersonWords.relation(label: "Colleague") == nil)
    }

    @Test(arguments: [
        ("Find Mum", "mum"), ("find mom", "mom"), ("Find my mum", "mum"), ("call dad", "dad"),
        ("Call Sarah Jones", "Sarah Jones"), ("ring my brother", "brother"),
        ("what's mum's number", "mum"), ("what is Jane's phone number?", "jane"),
        ("give me my sister's number", "sister"), ("the number for my dad", "dad"),
        ("find mum's number", "mum"), ("look up Jane Doe", "Jane Doe"),
    ])
    func phrasesReachFindContact(_ text: String, _ name: String) {
        let match = FastPathRouter().route(text)
        #expect(match.branch == "contact.find")
        #expect(match.command == .findContact(name))
    }

    @Test(arguments: [
        "find flights to rome", "call it a day", "Find My iPhone", "find my files", "what's your number",
        "find the file report.pdf", "what's the capital of france", "find a song that goes la la la",
        "where is mum",
    ])
    func otherPhrasesDoNot(_ text: String) {
        #expect(FastPathRouter().route(text).branch != "contact.find")
    }

    @Test func findMumIsAnsweredByTheFastPath() async throws {
        let rig = try await QuickDispatchTests.Rig(contacts: FakeRelatedContacts(list: Self.book, relations: Self.relations))
        defer { rig.sandbox.remove() }
        #expect(await rig.say("Find Mum") == "Jane Doe, phone +44 7700 900333, email jane@example.com")
        #expect(await rig.say("find flights to rome") == nil)          // still the brain's
    }

    @Test func personMentions() {
        #expect(PersonWords.mentionsPerson("Find Mum"))
        #expect(PersonWords.mentionsPerson("what's Sarah's number"))
        #expect(PersonWords.mentionsPerson("can you call my brother"))
        #expect(!PersonWords.mentionsPerson("what's the weather in London"))
        #expect(!PersonWords.mentionsPerson("play some music"))
    }
}
