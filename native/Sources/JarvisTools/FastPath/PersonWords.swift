import Foundation
import JarvisCore

/// Live fix 3: the words for a person that are not a name. "Find mum" reached the on-device
/// brain, which called no tool. These let the fast path, find_contact and the on-device tool
/// ranker see that a message is about someone in the user's contacts.
public enum PersonWords {
    /// Each relationship word, and the relation it means. A contact card's relation label (Apple's
    /// "mother", or one the user typed, such as "Mum") is read through the same table.
    static let relations: [String: String] = [
        "mum": "mother", "mom": "mother", "mother": "mother", "mummy": "mother", "mommy": "mother",
        "mam": "mother", "ma": "mother",
        "dad": "father", "father": "father", "daddy": "father", "papa": "father", "pa": "father",
        "brother": "brother", "bro": "brother",
        "sister": "sister", "sis": "sister",
        "wife": "spouse", "husband": "spouse", "spouse": "spouse", "partner": "spouse",
        "girlfriend": "spouse", "boyfriend": "spouse",
        "son": "son", "daughter": "daughter", "child": "child",
        "parent": "parent",
        "grandma": "grandmother", "grandmother": "grandmother", "gran": "grandmother", "granny": "grandmother",
        "nan": "grandmother", "nana": "grandmother", "nanna": "grandmother",
        "grandpa": "grandfather", "grandfather": "grandfather", "grandad": "grandfather", "granddad": "grandfather",
        "aunt": "aunt", "auntie": "aunt", "aunty": "aunt",
        "uncle": "uncle", "cousin": "cousin",
        "friend": "friend", "assistant": "assistant", "manager": "manager", "boss": "manager",
    ]

    /// The relation `phrase` names ("mum", "my mum", "Mother"), or nil when it is not one.
    public static func relation(_ phrase: String) -> String? {
        var s = Py.strip(phrase.lowercased())
        if s.hasPrefix("my ") { s = Py.strip(String(s.dropFirst(3))) }
        return relations[s]
    }

    /// The relation a contact relation label means: Apple's `_$!<Mother>!$_` or the label's
    /// localized text ("mother"), or a label the user typed ("Mum"). Nil when none.
    public static func relation(label: String) -> String? {
        var s = label
        if s.hasPrefix("_$!<"), s.hasSuffix(">!$_") { s = String(s.dropFirst(4).dropLast(4)) }
        return relation(s)
    }

    private static let contactVerb = try! PyRegex(#"\b(?:call|ring|phone|contact|number|email address|mobile)\b"#)

    /// The message names a relation ("text my sister") or asks for someone's number or to call
    /// them: the on-device ranker then offers find_contact.
    public static func mentionsPerson(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        if words.contains(where: { relations[$0] != nil && !ambiguous.contains($0) }) { return true }
        return contactVerb.search(lower) != nil
    }

    /// Relation words that are also everyday words: alone they do not make a message about a
    /// person ("a friend of the show", "my manager app").
    static let ambiguous: Set<String> = ["ma", "pa", "bro", "sis", "child", "friend", "assistant", "manager",
                                         "boss", "partner", "parent"]
}
