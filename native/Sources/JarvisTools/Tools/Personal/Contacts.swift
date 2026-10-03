@preconcurrency import Contacts
import Foundation
import JarvisCore

/// One person as Contacts shows them: the full name and every phone and email, in card order.
struct ContactCard: Sendable, Equatable {
    let name: String
    let phones: [String]
    let emails: [String]
    /// Live fix 3: the card's nickname, "" when none.
    var nickname: String = ""
}

/// Live fix 3: one relation on the user's own card ("mother: Jane Doe"): its label as Contacts
/// keeps it (`_$!<Mother>!$_`, or text the user typed) and the person's name.
struct ContactRelation: Sendable, Equatable {
    let label: String
    let name: String
}

/// The address book. `cards()` is nil when JARVIS has no Contacts access (denied, restricted or
/// unavailable), so the tools fall back to Python's Contacts AppleScript.
protocol ContactsReading: Sendable {
    func cards() async -> [ContactCard]?
    /// Live fix 3: the relations on the user's own ("me") card; nil when there is no access or
    /// no such card.
    func myRelations() async -> [ContactRelation]?
}

extension ContactsReading {
    func myRelations() async -> [ContactRelation]? { nil }
}

/// What a platform has before the app gives it the real address book: no access.
struct NoContacts: ContactsReading {
    func cards() async -> [ContactCard]? { nil }
}

/// `CNContactStore`, which reads the address book without launching Contacts.app or needing
/// Automation. The first use asks for access (NSContactsUsageDescription).
struct LiveContacts: ContactsReading {
    private static func store() async -> CNContactStore? {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return store
        case .notDetermined:
            return (try? await store.requestAccess(for: .contacts)) == true ? store : nil
        default: return nil
        }
    }

    func myRelations() async -> [ContactRelation]? {
        guard let store = await Self.store(),
              let me = try? store.unifiedMeContactWithKeys(toFetch: [CNContactRelationsKey as CNKeyDescriptor])
        else { return nil }
        return me.contactRelations.map { ContactRelation(label: $0.label ?? "", name: $0.value.name) }
    }

    func cards() async -> [ContactCard]? {
        guard let store = await Self.store() else { return nil }
        let keys: [any CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                           CNContactPhoneNumbersKey as CNKeyDescriptor,
                                           CNContactEmailAddressesKey as CNKeyDescriptor,
                                           CNContactNicknameKey as CNKeyDescriptor]
        let request = CNContactFetchRequest(keysToFetch: keys)
        var cards: [ContactCard] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                cards.append(ContactCard(name: CNContactFormatter.string(from: contact, style: .fullName) ?? "",
                                         phones: contact.phoneNumbers.map { $0.value.stringValue },
                                         emails: contact.emailAddresses.map { $0.value as String },
                                         nickname: contact.nickname))
            }
        } catch {
            return nil
        }
        return cards
    }
}

/// Python's Contacts lookups (jarvis.py `_contact_handle` 3155-3184, `_find_contact` 3186-3212):
/// a name equal to, then beginning with, then containing what was asked, ignoring case as
/// AppleScript's `whose name …` does, and the first such person. Natively over `CNContactStore`;
/// with no Contacts access, Python's AppleScript word for word.
struct ContactLookup: Sendable {
    let contacts: any ContactsReading
    let scripts: AppleScriptRunner

    private static let phone = try! PyRegex(#"[+\d][\d\s().-]{6,}"#)
    private static let phonePunctuation = try! PyRegex(#"[\s().-]"#)

    /// The first card whose name is `name`, else begins with it, else contains it.
    static func match(_ name: String, in cards: [ContactCard]) -> ContactCard? {
        // Native: an empty name matches nobody. AppleScript's `begins with ""` is true of every
        // person, so Python resolved an empty recipient to the first card in the book.
        guard !name.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive]
        return cards.first { $0.name.compare(name, options: options) == .orderedSame }
            ?? cards.first { $0.name.range(of: name, options: options.union(.anchored)) != nil }
            ?? cards.first { $0.name.range(of: name, options: options) != nil }
    }

    /// Live fix 3: `find_contact`'s person. A card named exactly `name` first, as Python; then
    /// one whose nickname is it; then, for a relationship word ("mum", "my brother"), the person
    /// the user's own card names for that relation; then Python's begins-with and contains.
    /// A relation whose person has no card of their own is that name alone.
    static func resolve(_ name: String, in cards: [ContactCard], relations: [ContactRelation]) -> ContactCard? {
        guard !name.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive]
        if let card = cards.first(where: { $0.name.compare(name, options: options) == .orderedSame }) { return card }
        var bare = Py.strip(name)
        if bare.lowercased().hasPrefix("my ") { bare = Py.strip(String(bare.dropFirst(3))) }
        if let card = cards.first(where: { !$0.nickname.isEmpty && $0.nickname.compare(bare, options: options) == .orderedSame }) {
            return card
        }
        if let relation = PersonWords.relation(name),
           let person = relations.first(where: { PersonWords.relation(label: $0.label) == relation }),
           !person.name.isEmpty {
            return cards.first { $0.name.compare(person.name, options: options) == .orderedSame }
                ?? match(person.name, in: cards)
                ?? ContactCard(name: person.name, phones: [], emails: [])
        }
        return match(name, in: cards)
    }

    private static func people(_ n: String) -> String {
        "tell application \"Contacts\"\n"
            + "  set ppl to (every person whose name = \"\(n)\")\n"
            + "  if (count of ppl) = 0 then set ppl to (every person whose name begins with \"\(n)\")\n"
            + "  if (count of ppl) = 0 then set ppl to (every person whose name contains \"\(n)\")\n"
            + "  if (count of ppl) = 0 then return \"\"\n"
            + "  set p to item 1 of ppl\n"
    }

    /// `_contact_handle`'s script, with `first` and `second` "phones"/"emails".
    static func handleScript(_ n: String, first: String, second: String) -> String {
        people(n)
            + "  if (count of \(first) of p) > 0 then return value of item 1 of \(first) of p\n"
            + "  if (count of \(second) of p) > 0 then return value of item 1 of \(second) of p\n"
            + "  return \"\"\n"
            + "end tell"
    }

    /// `_find_contact`'s script.
    static func findScript(_ n: String) -> String {
        people(n)
            + "  set out to (name of p)\n"
            + "  repeat with ph in (phones of p)\n"
            + "    set out to out & \", phone \" & (value of ph)\n"
            + "  end repeat\n"
            + "  repeat with em in (emails of p)\n"
            + "    set out to out & \", email \" & (value of em)\n"
            + "  end repeat\n"
            + "  return out\n"
            + "end tell"
    }

    private static func notFound(_ out: String) -> Bool {
        out.isEmpty || Py.eq(out, "Done.") || Py.startsWith(out, "AppleScript error")
    }

    /// `_contact_handle(name, prefer)`: an address passes through, a phone number loses its
    /// punctuation, anything else is looked up. "" when nobody matches.
    func handle(_ name: String, preferEmail: Bool) async -> String {
        let s = Py.strip(name)
        if Py.contains(s, "@") { return s }
        if let m = Self.phone.match(s), m.span.count == s.unicodeScalars.count {
            return Self.phonePunctuation.sub(s, literal: "")
        }
        var out: String
        if let cards = await contacts.cards() {
            guard let card = Self.match(s, in: cards) else { return "" }
            let (first, second) = preferEmail ? (card.emails, card.phones) : (card.phones, card.emails)
            out = first.first ?? second.first ?? ""
            if out.isEmpty { return "" }
        } else {
            guard !s.isEmpty else { return "" }
            out = await scripts.run(Self.handleScript(AppleScriptText.escape(s), first: preferEmail ? "emails" : "phones",
                                                      second: preferEmail ? "phones" : "emails"))
            if Self.notFound(out) { return "" }
        }
        out = Py.strip(out)
        if !Py.contains(out, "@") { out = Self.phonePunctuation.sub(out, literal: "") }
        return out
    }

    /// `_find_contact`'s answer for a stripped, non-empty `s`: "Name, phone …, email …", or nil.
    func describe(_ s: String) async -> String? {
        if let cards = await contacts.cards() {
            let relations = await contacts.myRelations() ?? []
            guard let card = Self.resolve(s, in: cards, relations: relations) else { return nil }
            return ([card.name] + card.phones.map { "phone \($0)" } + card.emails.map { "email \($0)" })
                .joined(separator: ", ")
        }
        let out = await scripts.run(Self.findScript(AppleScriptText.escape(s)))
        return Self.notFound(out) ? nil : out
    }
}

/// `find_contact`, Python's `_find_contact`.
struct FindContact: ToolImpl {
    static let name = "find_contact"
    static let schema = BuiltInTools.catalogSchema(named: name)
    let lookup: ContactLookup

    func run(_ args: JSONObject, _ ctx: ToolRunContext) async throws -> ToolOutcome {
        let s = Py.strip(try PyArgs.stringOrEmpty(args, "name", method: "strip"))
        if s.isEmpty { return .text("Who am I looking for, sir?") }
        return .text(await lookup.describe(s) ?? "I couldn't find \(s) in your contacts, sir.")
    }
}
